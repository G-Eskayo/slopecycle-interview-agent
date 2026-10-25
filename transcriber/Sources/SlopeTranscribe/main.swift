import AVFoundation
import FluidAudio
import Foundation
import TranscriptMerge

let fluidAudioVersion = "0.17.5"  // keep in step with Package.swift
let usage = "usage: slope-transcribe <audio-file> [--out FILE] [--models-dir DIR] [--asr-dir DIR] [--no-diarize]"

struct Failure: Error { let reason: String }

func log(_ message: String) {
    FileHandle.standardError.write(Data("slope-transcribe: \(message)\n".utf8))
}

func fail(_ reason: String, code: Int32 = 1) -> Never {
    // One line only: collapse any newlines in underlying error text.
    let line = reason.split(whereSeparator: \.isNewline).joined(separator: " ")
    FileHandle.standardError.write(Data("slope-transcribe: \(line)\n".utf8))
    exit(code)
}

struct Options {
    var input: URL
    var out: URL?
    var modelsDir: URL
    var asrDir: URL?
    var diarize = true
}

func expandPath(_ p: String) -> URL {
    URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
}

func parseOptions(_ args: [String]) -> Options {
    var input: String?
    var out: String?
    var modelsDir: String?
    var asrDir: String?
    var diarize = true
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count, !args[i].isEmpty else { fail("\(flag) needs a value. \(usage)", code: 2) }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--out": out = value(a)
        case "--models-dir": modelsDir = value(a)
        case "--asr-dir": asrDir = value(a)
        case "--no-diarize": diarize = false
        default:
            if a.hasPrefix("-") && a != "-" { fail("unknown option \(a). \(usage)", code: 2) }
            if input != nil { fail("only one audio file is accepted. \(usage)", code: 2) }
            input = a
        }
        i += 1
    }
    guard let input else { fail("no audio file given. \(usage)", code: 2) }
    let defaultModels = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("slope-transcribe/models", isDirectory: true)
    return Options(
        input: expandPath(input), out: out.map(expandPath),
        modelsDir: modelsDir.map(expandPath) ?? defaultModels,
        asrDir: asrDir.map(expandPath), diarize: diarize)
}

/// Opens the file once up front so a missing or undecodable file fails fast, before any model loads.
func audioDuration(_ url: URL) -> Double {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
        fail("audio file not found: \(url.path)")
    }
    do {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { fail("unreadable audio: \(url.path) (no sample rate)") }
        return Double(file.length) / rate
    } catch {
        fail("unreadable audio: \(url.path) (\(error.localizedDescription))")
    }
}

func loadAsr(_ opts: Options) async throws -> AsrManager {
    let models: AsrModels
    do {
        if let dir = opts.asrDir {
            log("loading Parakeet Ultra from \(dir.path)")
            models = try AsrModels.loadLocal(from: dir, version: .ultra)
        } else {
            // FluidAudio resolves the repo folder as a sibling of this path, so it must end in the repo folder name.
            let dir = opts.modelsDir.appendingPathComponent(Repo.parakeetUltra.folderName, isDirectory: true)
            log("loading Parakeet Ultra into \(dir.path) (downloads ~555 MB on first run)")
            models = try await AsrModels.downloadAndLoad(to: dir, version: .ultra)
        }
        let manager = AsrManager(config: .default)  // streamingEnabled, 30 s disk-backed threshold
        try await manager.loadModels(models)
        return manager
    } catch {
        throw Failure(reason: "model load failed: \(error.localizedDescription)")
    }
}

func transcribe(_ url: URL, duration: Double, with manager: AsrManager) async throws -> ASRResult {
    var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
    let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
    do {
        if duration * Double(ASRConstants.sampleRate) < Double(minimum) {
            // Too short for the encoder: pad with trailing silence (timings are unaffected).
            var samples = try AudioConverter().resampleAudioFile(url)
            if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
            return try await manager.transcribe(samples, decoderState: &state)
        }
        // File-URL path: above config.streamingThreshold this memory-maps and chunks from disk.
        return try await manager.transcribe(url, decoderState: &state)
    } catch {
        throw Failure(reason: "transcription failed: \(error.localizedDescription)")
    }
}

func diarize(_ url: URL, modelsDir: URL) async throws -> [SpeakerSpan] {
    let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
    log("loading diarizer models from \(modelsDir.path)")
    try await manager.prepareModels(directory: modelsDir)
    log("diarizing")
    let result = try await manager.process(url)
    return result.segments.map {
        SpeakerSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
    }
}

func run() async {
    let opts = parseOptions(Array(CommandLine.arguments.dropFirst()))
    let duration = audioDuration(opts.input)
    do {
        try FileManager.default.createDirectory(at: opts.modelsDir, withIntermediateDirectories: true)
    } catch {
        fail("cannot create models dir \(opts.modelsDir.path): \(error.localizedDescription)")
    }

    var started = Date()
    let asr: AsrManager
    let result: ASRResult
    do {
        asr = try await loadAsr(opts)
        log(String(format: "models loaded in %.1f s; transcribing %.1f s of audio", Date().timeIntervalSince(started), duration))
        started = Date()
        result = try await transcribe(opts.input, duration: duration, with: asr)
    } catch let f as Failure {
        fail(f.reason)
    } catch {
        fail(error.localizedDescription)
    }
    log(String(format: "transcribed in %.1f s", Date().timeIntervalSince(started)))
    let tokens = (result.tokenTimings ?? []).map { Token(text: $0.token, start: $0.startTime, end: $0.endTime) }
    let words = TranscriptMerge.words(from: tokens)

    var warnings: [String] = []
    if result.tokenTimings == nil && !result.text.isEmpty {
        warnings.append("ASR returned no token timings; segment times are unavailable")
    }
    var spans: [SpeakerSpan] = []
    var diarized = false
    if !opts.diarize {
        warnings.append("diarization skipped (--no-diarize); all speech labelled S1")
    } else if words.isEmpty {
        warnings.append("no speech recognised; diarization skipped")
    } else {
        let dStart = Date()
        do {
            spans = try await diarize(opts.input, modelsDir: opts.modelsDir)
            if spans.isEmpty {
                warnings.append("diarizer found no speaker segments; all speech labelled S1")
            } else {
                diarized = true
            }
            log(String(format: "diarized in %.1f s (%d segments)", Date().timeIntervalSince(dStart), spans.count))
        } catch {
            warnings.append("diarization failed (\(error.localizedDescription)); all speech labelled S1")
            log("warning: diarization failed: \(error.localizedDescription)")
        }
    }

    var segments = TranscriptMerge.segments(words: words, spans: spans)
    if segments.isEmpty, result.tokenTimings == nil, !result.text.isEmpty {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        segments = [Segment(speaker: "S1", start: 0, end: duration, text: text)]
    }
    let transcript = Transcript(
        durationSeconds: result.duration > 0 ? result.duration : duration, engine: "parakeet-ultra",
        fluidaudio: fluidAudioVersion, diarized: diarized, warnings: warnings, segments: segments)

    do {
        var data = try transcript.jsonData()
        data.append(0x0A)
        if let out = opts.out {
            try data.write(to: out, options: .atomic)
            log("wrote \(out.path)")
        } else {
            FileHandle.standardOutput.write(data)
        }
    } catch {
        fail("cannot write output: \(error.localizedDescription)")
    }
    exit(0)
}

// Keep FluidAudio's own console logging to warnings and above (it writes to stderr, never stdout).
AppLogger.minimumLevel = .warning
await run()
