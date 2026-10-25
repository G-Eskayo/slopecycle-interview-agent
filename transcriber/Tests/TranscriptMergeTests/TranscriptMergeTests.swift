import Foundation
import Testing
@testable import TranscriptMerge

private func w(_ text: String, _ start: Double, _ end: Double) -> Word { Word(text: text, start: start, end: end) }
private func s(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerSpan {
    SpeakerSpan(speaker: speaker, start: start, end: end)
}

@Suite("words(from:)")
struct WordGroupingTests {
    @Test func emptyTokensGiveNoWords() {
        #expect(TranscriptMerge.words(from: []).isEmpty)
    }

    @Test func subwordsAndPunctuationJoinTheCurrentWord() {
        let tokens = [
            Token(text: "▁Hel", start: 0.0, end: 0.2), Token(text: "lo", start: 0.2, end: 0.4),
            Token(text: ",", start: 0.4, end: 0.45), Token(text: "▁world", start: 0.6, end: 1.0),
            Token(text: ".", start: 1.0, end: 1.05),
        ]
        #expect(TranscriptMerge.words(from: tokens) == [w("Hello,", 0.0, 0.45), w("world.", 0.6, 1.05)])
    }

    @Test func leadingSpaceIsAlsoAWordBoundary() {
        let tokens = [Token(text: " so", start: 0, end: 0.1), Token(text: " yes", start: 0.2, end: 0.3)]
        #expect(TranscriptMerge.words(from: tokens).map(\.text) == ["so", "yes"])
    }

    @Test func firstTokenWithoutMarkerStillStartsAWord() {
        let tokens = [Token(text: "ok", start: 1, end: 2), Token(text: "ay", start: 2, end: 2.5)]
        #expect(TranscriptMerge.words(from: tokens) == [w("okay", 1, 2.5)])
    }

    @Test func blanksPadsAndBareMarkersAreDropped() {
        let tokens = [
            Token(text: "<blank>", start: 0, end: 0), Token(text: "▁", start: 0.1, end: 0.1),
            Token(text: "<pad>", start: 0.1, end: 0.1), Token(text: "▁a", start: 0.2, end: 0.3),
            Token(text: "▁", start: 0.3, end: 0.3), Token(text: "", start: 0.3, end: 0.3),
        ]
        #expect(TranscriptMerge.words(from: tokens) == [w("a", 0.2, 0.3)])
    }

    @Test func bareMarkerEndsThePreviousWord() {
        let tokens = [
            Token(text: "▁a", start: 0, end: 0.1), Token(text: "▁", start: 0.1, end: 0.1),
            Token(text: "b", start: 0.2, end: 0.3),
        ]
        #expect(TranscriptMerge.words(from: tokens).map(\.text) == ["a", "b"])
    }
}

@Suite("speaker(for:in:)")
struct SpeakerAssignmentTests {
    @Test func noSpansGivesNil() {
        #expect(TranscriptMerge.speaker(for: w("x", 1, 2), in: []) == nil)
    }

    @Test func picksTheSpeakerWithMostOverlap() {
        let spans = [s("A", 0, 1.3), s("B", 1.3, 5)]
        #expect(TranscriptMerge.speaker(for: w("x", 1.0, 2.0), in: spans) == "B")
        #expect(TranscriptMerge.speaker(for: w("x", 0.5, 1.5), in: spans) == "A")
    }

    @Test func overlappingSegmentsSumPerSpeaker() {
        // B has two short spans that together beat A's single longer overlap.
        let spans = [s("A", 0, 10), s("B", 2.0, 2.4), s("B", 2.5, 2.9)]
        #expect(TranscriptMerge.speaker(for: w("x", 2.0, 3.0), in: spans) == "A")  // A 1.0 vs B 0.8
        let spans2 = [s("A", 0, 2.3), s("B", 2.0, 2.6), s("B", 2.6, 3.0)]
        #expect(TranscriptMerge.speaker(for: w("x", 2.0, 3.0), in: spans2) == "B")  // A 0.3 vs B 1.0
    }

    @Test func exactTieGoesToFirstListedSpan() {
        let spans = [s("B", 0, 10), s("A", 0, 10)]
        #expect(TranscriptMerge.speaker(for: w("x", 1, 2), in: spans) == "B")
    }

    @Test func wordInAGapGoesToNearestSegment() {
        let spans = [s("A", 0, 1), s("B", 5, 6)]
        #expect(TranscriptMerge.speaker(for: w("x", 1.5, 2.0), in: spans) == "A")
        #expect(TranscriptMerge.speaker(for: w("x", 4.0, 4.5), in: spans) == "B")
        #expect(TranscriptMerge.speaker(for: w("x", 100, 101), in: spans) == "B")  // after everything
        #expect(TranscriptMerge.speaker(for: w("x", -3, -2), in: [s("B", 5, 6), s("A", 0, 1)]) == "A")
    }

    @Test func zeroLengthWordInsideASpanBelongsToIt() {
        let spans = [s("A", 0, 1), s("B", 1, 2)]
        #expect(TranscriptMerge.speaker(for: w("x", 1.5, 1.5), in: spans) == "B")
    }

    @Test func invertedWordTimesAreTolerated() {
        let spans = [s("A", 0, 1), s("B", 1, 2)]
        #expect(TranscriptMerge.speaker(for: w("x", 1.9, 1.2), in: spans) == "B")
    }

    @Test func invalidSpansAreIgnored() {
        let spans = [s("BAD", 5, 1), s("NAN", .nan, 3), s("A", 10, 11)]
        #expect(TranscriptMerge.speaker(for: w("x", 2, 3), in: spans) == "A")
        #expect(TranscriptMerge.speaker(for: w("x", 2, 3), in: [s("BAD", 5, 1)]) == nil)
    }
}

@Suite("segments(words:spans:)")
struct SegmentGroupingTests {
    @Test func emptyWordsGiveNoSegments() {
        #expect(TranscriptMerge.segments(words: [], spans: [s("A", 0, 5)]).isEmpty)
        #expect(TranscriptMerge.segments(words: [], spans: []).isEmpty)
    }

    @Test func noSpansMeansOneSpeakerS1() {
        let words = [w("a", 0, 1), w("b", 1, 2), w("c", 30, 31)]
        #expect(TranscriptMerge.segments(words: words, spans: []) == [Segment(speaker: "S1", start: 0, end: 31, text: "a b c")])
    }

    @Test func singleSpeakerIsOneTurn() {
        let words = [w("one", 0, 1), w("two", 1.2, 2), w("three", 2.5, 3)]
        let segs = TranscriptMerge.segments(words: words, spans: [s("spk_7", 0, 10)])
        #expect(segs == [Segment(speaker: "S1", start: 0, end: 3, text: "one two three")])
    }

    @Test func labelsFollowFirstAppearanceInWordsNotDiarizerIds() {
        // Diarizer calls the first talker "2" and lists it second; it must still be S1.
        let spans = [s("1", 5, 10), s("2", 0, 5)]
        let words = [w("hi", 0.5, 1), w("there", 1, 1.5), w("hello", 6, 7), w("back", 8, 9), w("ok", 2, 3)]
        let segs = TranscriptMerge.segments(words: words, spans: spans)
        #expect(segs.map(\.speaker) == ["S1", "S2", "S1"])
        #expect(segs.map(\.text) == ["hi there", "hello back", "ok"])
        #expect(segs[1].start == 6 && segs[1].end == 9)
    }

    @Test func speakersWithNoWordsGetNoLabel() {
        let spans = [s("silent", 0, 1), s("talker", 1, 10)]
        let segs = TranscriptMerge.segments(words: [w("x", 2, 3)], spans: spans)
        #expect(segs == [Segment(speaker: "S1", start: 2, end: 3, text: "x")])
    }

    @Test func alternatingSpeakersMakeSeparateTurns() {
        let spans = [s("A", 0, 1), s("B", 1, 2), s("A", 2, 3), s("B", 3, 4)]
        let words = [w("a", 0.1, 0.9), w("b", 1.1, 1.9), w("c", 2.1, 2.9), w("d", 3.1, 3.9)]
        #expect(TranscriptMerge.segments(words: words, spans: spans).map(\.speaker) == ["S1", "S2", "S1", "S2"])
    }

    @Test func manySpeakersGetSequentialLabels() {
        let spans = (0..<12).map { s("raw\($0)", Double($0), Double($0) + 1) }
        let words = (0..<12).map { w("w\($0)", Double($0) + 0.2, Double($0) + 0.8) }
        let labels = TranscriptMerge.segments(words: words, spans: spans).map(\.speaker)
        #expect(labels == (1...12).map { "S\($0)" })
    }
}

@Suite("Transcript JSON")
struct TranscriptJSONTests {
    @Test func encodesTheAgreedShape() throws {
        let t = Transcript(
            durationSeconds: 21.399813, engine: "parakeet-ultra", fluidaudio: "0.17.5", diarized: true,
            warnings: [], segments: [Segment(speaker: "S1", start: 12.34567, end: 18.9, text: "a \"quoted\" / thing")])
        let obj = try JSONSerialization.jsonObject(with: t.jsonData()) as! [String: Any]
        #expect(Set(obj.keys) == ["duration_seconds", "engine", "fluidaudio", "diarized", "warnings", "segments"])
        #expect(obj["duration_seconds"] as? Double == 21.4)
        #expect(obj["diarized"] as? Bool == true)
        let seg = (obj["segments"] as! [[String: Any]])[0]
        #expect(Set(seg.keys) == ["speaker", "start", "end", "text"])
        #expect(seg["start"] as? Double == 12.346)
        #expect(seg["text"] as? String == "a \"quoted\" / thing")
        let decoded = try JSONDecoder().decode(Transcript.self, from: t.jsonData())
        #expect(decoded.segments[0].text == t.segments[0].text)
    }

    @Test func emptyTranscriptIsStillValidJSON() throws {
        let t = Transcript(durationSeconds: 0, engine: "parakeet-ultra", fluidaudio: "0.17.5", diarized: false,
                           warnings: ["diarization skipped (--no-diarize)"], segments: [])
        let obj = try JSONSerialization.jsonObject(with: t.jsonData()) as! [String: Any]
        #expect((obj["segments"] as! [Any]).isEmpty)
        #expect((obj["warnings"] as! [String]) == ["diarization skipped (--no-diarize)"])
    }
}
