import Foundation

public enum RespondentLabel {
    public static let nameWarning = "Use a label like P-07, not a name"

    /// True when the label looks like a full name: two or more capitalised words ("Jane Doe", "José Núñez").
    /// Labels such as "P-07", "Parent 7" or "PTA" do not match. Only a warning; never blocks sending.
    public static func looksLikeFullName(_ label: String) -> Bool {
        let words = label.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2 else { return false }
        return words.allSatisfy(isCapitalisedWord)
    }

    static func isCapitalisedWord<S: StringProtocol>(_ word: S) -> Bool {
        guard let first = word.first, first.isLetter, first.isUppercase else { return false }
        let rest = word.dropFirst()
        guard !rest.isEmpty else { return false }
        var sawLowercase = false
        for c in rest {
            if c.isLetter {
                if c.isLowercase { sawLowercase = true }
            } else if c != "'" && c != "’" && c != "-" {
                return false
            }
        }
        return sawLowercase
    }
}
