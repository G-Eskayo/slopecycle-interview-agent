@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SlopeSendCore

/// Writes `seconds` of a speech-like signal (tones + noise) as 44.1 kHz stereo PCM in the given container.
func makePCMFile(_ url: URL, seconds: Double = 10, sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2,
                 fileType: AudioFileTypeID = kAudioFileWAVEType) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: fileType == kAudioFileAIFFType,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    var seed: UInt32 = 12345
    for ch in 0..<Int(channels) {
        let data = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            let t = Double(i) / sampleRate
            let envelope = Float(0.5 + 0.5 * sin(2 * .pi * 3 * t))
            data[i] = envelope * (0.3 * Float(sin(2 * .pi * 220 * t)) + 0.2 * Float(sin(2 * .pi * 1250 * t)) + 0.15 * noise)
        }
    }
    try file.write(from: buffer)
}

/// A short H.264 video (solid frames) muxed with an AAC audio track, as a .mov.
func makeVideoWithAudio(_ url: URL, dir: URL) async throws {
    let audio = dir.appendingPathComponent("track.m4a")
    let wav = dir.appendingPathComponent("src.wav")
    try makePCMFile(wav, seconds: 3)
    do { // AVAudioFile finalises the m4a when it is released
        let aac = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                                                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        let src = try AVAudioFile(forReading: wav)
        let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length))!
        try src.read(into: buf)
        try aac.write(from: buf)
    }

    let videoOnly = dir.appendingPathComponent("video.mov")
    let writer = try AVAssetWriter(outputURL: videoOnly, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                      AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 64])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<30 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(frame * 8), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)

    let composition = AVMutableComposition()
    let vAsset = AVURLAsset(url: videoOnly), aAsset = AVURLAsset(url: audio)
    let vTrack = try await vAsset.loadTracks(withMediaType: .video)[0]
    let aTrack = try await aAsset.loadTracks(withMediaType: .audio)[0]
    let duration = try await vAsset.load(.duration)
    try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vTrack, at: .zero)
    try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: aTrack, at: .zero)
    let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
    try await export.export(to: url, as: .mov)
}

struct AudioFacts {
    let sampleRate: Double
    let channels: UInt32
    let formatID: AudioFormatID
    let bitRate: Double
    let videoTracks: Int
    let audioTracks: Int
}

func facts(_ url: URL) async throws -> AudioFacts {
    let file = try AVAudioFile(forReading: url)
    let asbd = file.fileFormat.streamDescription.pointee
    let asset = AVURLAsset(url: url)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let video = try await asset.loadTracks(withMediaType: .video)
    let rate = try await audio[0].load(.estimatedDataRate)
    return AudioFacts(sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, formatID: asbd.mFormatID,
                      bitRate: Double(rate), videoTracks: video.count, audioTracks: audio.count)
}

/// afinfo is the independent check the brief asks for (not our own decoder).
func afinfo(_ url: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    p.arguments = [url.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@Suite(.serialized) struct CompressorTests {
    func assertSpeechFormat(_ out: URL, seconds: Double) async throws {
        let f = try await facts(out)
        #expect(f.sampleRate == 16_000)
        #expect(f.channels == 1)
        #expect(f.formatID == kAudioFormatMPEG4AAC)
        #expect(f.videoTracks == 0 && f.audioTracks == 1)
        #expect(abs(f.bitRate - 24_000) <= 24_000 * 0.2, "estimated data rate \(f.bitRate)")
        // Whole-file rate, container included.
        let bytes = Double(try Draft.fileSize(out))
        let fileRate = bytes * 8 / seconds
        #expect(abs(fileRate - 24_000) <= 24_000 * 0.2, "file rate \(fileRate)")
        let info = try afinfo(out)
        #expect(info.contains("File type ID:   m4af"))
        #expect(info.contains("1 ch,  16000 Hz, aac") || info.contains("1 ch, 16000 Hz, aac"), "\(info)")
    }

    @Test func wavBecomes16kMonoAAC() async throws {
        let dir = tempDir()
        let wav = dir.appendingPathComponent("in.wav"), out = dir.appendingPathComponent("recording.m4a")
        try makePCMFile(wav, seconds: 20)
        let before = try SHA256Hex.ofFile(wav)
        try await AACSpeechCompressor().compress(wav, to: out)
        try await assertSpeechFormat(out, seconds: 20)
        #expect(try SHA256Hex.ofFile(wav) == before) // original untouched
    }

    @Test func aiffBecomes16kMonoAAC() async throws {
        let dir = tempDir()
        let aiff = dir.appendingPathComponent("in.aiff"), out = dir.appendingPathComponent("recording.m4a")
        try makePCMFile(aiff, seconds: 20, sampleRate: 48_000, channels: 1, fileType: kAudioFileAIFFType)
        try await AACSpeechCompressor().compress(aiff, to: out)
        try await assertSpeechFormat(out, seconds: 20)
    }

    @Test func videoYieldsAudioOnlyM4A() async throws {
        let dir = tempDir()
        let mov = dir.appendingPathComponent("clip.mov"), out = dir.appendingPathComponent("recording.m4a")
        try await makeVideoWithAudio(mov, dir: dir)
        let input = AVURLAsset(url: mov)
        #expect(try await input.loadTracks(withMediaType: .video).count == 1)
        try await AACSpeechCompressor().compress(mov, to: out)
        let f = try await facts(out)
        #expect(f.videoTracks == 0 && f.audioTracks == 1)
        #expect(f.sampleRate == 16_000 && f.channels == 1 && f.formatID == kAudioFormatMPEG4AAC)
    }

    @Test func corruptInputFallsBackToOriginal() async throws {
        let dir = tempDir()
        let bad = dir.appendingPathComponent("broken.wav")
        var junk = Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEjunk".utf8)
        junk.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try junk.write(to: bad)
        await #expect(throws: (any Error).self) {
            try await AACSpeechCompressor().compress(bad, to: dir.appendingPathComponent("recording.m4a"))
        }
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        let saved = try await box.save(
            Draft(respondentLabel: "P-07", interviewType: .parent, interviewDate: "2026-11-02", notes: "", recordingURL: bad),
            interviewer: "A", appVersion: "1", now: Date())
        #expect(saved.recording == .sentOriginal)
        #expect(saved.stored.meta.recordingFile == "recording.wav")
        #expect(try Data(contentsOf: saved.stored.url(of: "recording.wav")) == junk)
        #expect(try Data(contentsOf: bad) == junk)
    }

    @Test func videoWithoutAudioFallsBack() async throws {
        // No audio track to compress: the original is sent as-is rather than an empty file.
        let dir = tempDir()
        let mov = dir.appendingPathComponent("clip.mov")
        try await makeVideoWithAudio(mov, dir: dir)
        let videoOnly = dir.appendingPathComponent("video.mov") // left behind by the helper
        await #expect(throws: CompressionError.noAudioTrack) {
            try await AACSpeechCompressor().compress(videoOnly, to: dir.appendingPathComponent("out.m4a"))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("out.m4a").path))
    }

    @Test func nonAudioFileRefused() async throws {
        let dir = tempDir()
        let pdf = dir.appendingPathComponent("slides.pdf")
        try Data("%PDF-1.4 SYNTHETIC".utf8).write(to: pdf)
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        await #expect(throws: DraftProblem.notAudioOrVideo) {
            _ = try await box.save(Draft(respondentLabel: "P-07", interviewType: .parent, interviewDate: "2026-11-02",
                                         notes: "SYNTHETIC TEST DATA", recordingURL: pdf),
                                   interviewer: "A", appVersion: "1", now: Date())
        }
        #expect(box.pending().isEmpty)
    }

    @Test func realOutboxSaveUsesCompressedBytesForHash() async throws {
        let dir = tempDir()
        let wav = dir.appendingPathComponent("Interview.WAV")
        try makePCMFile(wav, seconds: 5)
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        let saved = try await box.save(
            Draft(respondentLabel: "P-07", interviewType: .expert, interviewDate: "2026-11-02", notes: "", recordingURL: wav),
            interviewer: "A", appVersion: "1", now: Date())
        guard case .compressed(let bytes) = saved.recording else { Issue.record("\(saved.recording)"); return }
        let out = saved.stored.url(of: "recording.m4a")
        #expect(saved.stored.meta.recordingFile == "recording.m4a")
        #expect(saved.stored.meta.recordingSHA256 == (try SHA256Hex.ofFile(out)))
        #expect(bytes < (try Draft.fileSize(wav)) / 10)
    }
}
