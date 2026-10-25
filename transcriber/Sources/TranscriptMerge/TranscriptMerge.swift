import Foundation

/// One ASR token with its time span, as the engine reports it. `text` is the raw
/// SentencePiece piece: a leading `▁` (or space) marks the start of a new word.
public struct Token: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A whole word with the span from its first token's start to its last token's end.
public struct Word: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One diarizer segment: who spoke from `start` to `end`. `speaker` is the diarizer's
/// own id (any string); output labels are assigned later.
public struct SpeakerSpan: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// One output turn: consecutive words from one speaker.
public struct Segment: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

/// The JSON document the tool writes.
public struct Transcript: Codable, Equatable, Sendable {
    public var durationSeconds: Double
    public var engine: String
    public var fluidaudio: String
    public var diarized: Bool
    public var warnings: [String]
    public var segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case engine, fluidaudio, diarized, warnings, segments
    }

    public init(
        durationSeconds: Double, engine: String, fluidaudio: String, diarized: Bool,
        warnings: [String], segments: [Segment]
    ) {
        self.durationSeconds = durationSeconds
        self.engine = engine
        self.fluidaudio = fluidaudio
        self.diarized = diarized
        self.warnings = warnings
        self.segments = segments
    }

    /// Pretty JSON with keys in a fixed order and times rounded to milliseconds.
    public func jsonData() throws -> Data {
        var copy = self
        copy.durationSeconds = Self.round3(durationSeconds)
        copy.segments = segments.map {
            Segment(speaker: $0.speaker, start: Self.round3($0.start), end: Self.round3($0.end), text: $0.text)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(copy)
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

public enum TranscriptMerge {
    static let boundaryMarkers: Set<Character> = ["▁", " "]
    static let ignoredTokens: Set<String> = ["", "<blank>", "<pad>", "<unk>"]

    /// Groups sub-word tokens into words. A token starting with `▁` or a space starts a
    /// new word; any other token (including punctuation) is glued onto the current word.
    /// Tokens that are only a boundary marker are dropped but still start a new word.
    public static func words(from tokens: [Token]) -> [Word] {
        var out: [Word] = []
        var current: Word?
        for token in tokens where !ignoredTokens.contains(token.text) {
            let startsNew = token.text.first.map { boundaryMarkers.contains($0) } ?? false
            let piece = String(token.text.drop(while: { boundaryMarkers.contains($0) }))
            if startsNew {
                if let c = current, !c.text.isEmpty { out.append(c) }
                current = piece.isEmpty ? nil : Word(text: piece, start: token.start, end: token.end)
            } else if piece.isEmpty {
                continue
            } else if var c = current {
                c.text += piece
                c.end = max(c.end, token.end)
                current = c
            } else {
                current = Word(text: piece, start: token.start, end: token.end)
            }
        }
        if let c = current, !c.text.isEmpty { out.append(c) }
        return out
    }

    /// The diarizer speaker id a word belongs to: the speaker whose spans overlap the word
    /// for the most total time; if none overlap (a word in a gap, or a zero-length word),
    /// the speaker of the nearest span. Ties go to the span listed first. Returns nil only
    /// when there are no usable spans.
    public static func speaker(for word: Word, in spans: [SpeakerSpan]) -> String? {
        let usable = spans.filter { $0.end >= $0.start && $0.start.isFinite && $0.end.isFinite }
        guard !usable.isEmpty else { return nil }
        let wStart = min(word.start, word.end)
        let wEnd = max(word.start, word.end)

        var overlapBySpeaker: [String: Double] = [:]
        var order: [String] = []
        for span in usable {
            let overlap = min(wEnd, span.end) - max(wStart, span.start)
            guard overlap > 0 else { continue }
            if overlapBySpeaker[span.speaker] == nil { order.append(span.speaker) }
            overlapBySpeaker[span.speaker, default: 0] += overlap
        }
        if let best = order.max(by: { overlapBySpeaker[$0]! < overlapBySpeaker[$1]! }) {
            // `max(by:)` returns the last of equal maxima; prefer the first instead.
            let top = overlapBySpeaker[best]!
            return order.first { overlapBySpeaker[$0]! == top }
        }

        var nearest: (speaker: String, distance: Double)?
        for span in usable {
            let distance = max(0, span.start - wEnd, wStart - span.end)
            if nearest == nil || distance < nearest!.distance {
                nearest = (span.speaker, distance)
            }
        }
        return nearest?.speaker
    }

    /// Assigns each word a speaker, relabels speakers S1, S2, ... in order of first
    /// appearance in the words, and joins consecutive same-speaker words into turns.
    /// With no spans, every word goes to S1.
    public static func segments(words: [Word], spans: [SpeakerSpan]) -> [Segment] {
        var labels: [String: String] = [:]
        var out: [Segment] = []
        for word in words {
            let raw = speaker(for: word, in: spans) ?? "S1"
            let label: String
            if let known = labels[raw] {
                label = known
            } else {
                label = "S\(labels.count + 1)"
                labels[raw] = label
            }
            if var last = out.last, last.speaker == label {
                last.text += " " + word.text
                last.end = max(last.end, word.end)
                out[out.count - 1] = last
            } else {
                out.append(Segment(speaker: label, start: word.start, end: word.end, text: word.text))
            }
        }
        return out
    }
}
