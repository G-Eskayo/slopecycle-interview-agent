@preconcurrency import AVFoundation
import Foundation

/// Turns an attached recording into the file that is sent. The source is only read, never modified or moved.
public protocol RecordingCompressor: Sendable {
    /// Writes a compressed `.m4a` to `destination` (which must not exist) or throws.
    func compress(_ source: URL, to destination: URL) async throws
}

public enum CompressionError: Error, Equatable, Sendable {
    case noAudioTrack
    case readFailed(String)
    case writeFailed(String)
    case emptyOutput
}

/// AAC-LC, 16 kHz, mono, 24 kbps, .m4a — via AVAssetReader → AVAssetWriter. Video inputs keep only their first
/// audio track. Speech transcribes the same at this rate (~11 MB per hour).
public struct AACSpeechCompressor: RecordingCompressor {
    public static let sampleRate: Double = 16_000
    public static let channels = 1
    public static let bitRate = 24_000

    public init() {}

    public func compress(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw CompressionError.readFailed(error.localizedDescription)
        }
        guard let track = tracks.first else { throw CompressionError.noAudioTrack }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        } catch {
            throw CompressionError.readFailed(error.localizedDescription)
        }

        // Decode to 16 kHz mono 16-bit PCM; the reader does the resampling and down-mix.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CompressionError.readFailed("cannot decode audio track") }
        reader.add(output)

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVEncoderBitRateKey: Self.bitRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CompressionError.writeFailed("cannot add AAC encoder") }
        writer.add(input)

        guard reader.startReading() else {
            throw CompressionError.readFailed(reader.error?.localizedDescription ?? "cannot start reading")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw CompressionError.writeFailed(writer.error?.localizedDescription ?? "cannot start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(reader: reader, output: output, writer: writer, input: input)
        let appendedAny = await pump.run()

        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CompressionError.readFailed(reader.error?.localizedDescription ?? "read failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw CompressionError.writeFailed(writer.error?.localizedDescription ?? "write failed")
        }
        guard appendedAny else {
            try? FileManager.default.removeItem(at: destination)
            throw CompressionError.emptyOutput
        }
    }
}

/// Moves decoded buffers from the reader to the encoder on a private queue. AVFoundation objects are not
/// Sendable; they are only touched on `queue` while `run` is pending, then handed back.
private final class Pump: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let queue = DispatchQueue(label: "com.slopecycle.send.compress")
    var finished = false
    var appendedAny = false

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }

    /// Returns whether at least one buffer was appended.
    func run() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let buffer = output.copyNextSampleBuffer() else {
                        finish(continuation)
                        return
                    }
                    guard input.append(buffer) else {
                        finish(continuation)
                        return
                    }
                    appendedAny = true
                }
            }
        }
    }

    private func finish(_ continuation: CheckedContinuation<Bool, Never>) {
        finished = true
        input.markAsFinished()
        continuation.resume(returning: appendedAny)
    }
}
