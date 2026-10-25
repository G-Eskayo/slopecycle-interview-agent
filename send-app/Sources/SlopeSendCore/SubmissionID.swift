import Foundation

/// Submission ids: `<UTC send time yyyy-MM-ddTHHmmssZ>-<8 random lowercase hex>` (docs/submission-format.md).
public enum SubmissionID {
    /// A fresh id for `date`, using the system random generator.
    public static func make(at date: Date) -> String {
        var rng = SystemRandomNumberGenerator()
        return make(at: date, using: &rng)
    }

    public static func make<R: RandomNumberGenerator>(at date: Date, using rng: inout R) -> String {
        let value = UInt32.random(in: .min ... .max, using: &rng)
        return make(at: date, randomHex: String(format: "%08x", value))
    }

    /// Builds an id from a timestamp and an explicit 8-hex suffix (tests, deterministic callers).
    public static func make(at date: Date, randomHex: String) -> String {
        precondition(isHex8(randomHex), "random part must be 8 lowercase hex characters")
        return "\(compactTimestamp(date))-\(randomHex)"
    }

    /// `yyyy-MM-ddTHHmmssZ` in UTC.
    public static func compactTimestamp(_ date: Date) -> String {
        utcFormatter("yyyy-MM-dd'T'HHmmss'Z'").string(from: date)
    }

    /// `yyyy-MM-ddTHH:mm:ssZ` in UTC (the `sent_at` field).
    public static func isoTimestamp(_ date: Date) -> String {
        utcFormatter("yyyy-MM-dd'T'HH:mm:ss'Z'").string(from: date)
    }

    public static func isValid(_ id: String) -> Bool {
        id.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{6}Z-[0-9a-f]{8}/) != nil
    }

    static func isHex8(_ s: String) -> Bool {
        s.wholeMatch(of: /[0-9a-f]{8}/) != nil
    }

    static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
}

/// `YYYY-MM-DD` for the interview day, in the user's own time zone.
public enum InterviewDate {
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func isValid(_ s: String) -> Bool {
        guard s.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return false }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let d = f.date(from: s) else { return false }
        return f.string(from: d) == s
    }
}
