import Foundation

/// Compares version strings the way people read them: 1.10 > 1.9, 2.0 > 2.0b3 > 2.0b2, 2.0.1 > 2.0.
public enum VersionComparator {
    enum Token: Equatable {
        case number(Int)
        case text(String)
    }

    static func tokens(_ version: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsDigit = false
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(currentIsDigit ? .number(Int(current.prefix(18)) ?? 0) : .text(current.lowercased()))
            current = ""
        }
        for character in version {
            if character.isNumber {
                if !currentIsDigit { flush() }
                currentIsDigit = true
                current.append(character)
            } else if character.isLetter {
                if currentIsDigit { flush() }
                currentIsDigit = false
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = tokens(lhs)
        let right = tokens(rhs)
        for index in 0..<max(left.count, right.count) {
            switch (index < left.count ? left[index] : nil, index < right.count ? right[index] : nil) {
            case let (.number(a)?, .number(b)?):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            case let (.text(a)?, .text(b)?):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            case (.number?, .text?):
                return .orderedDescending          // 2.0.1 > 2.0b1
            case (.text?, .number?):
                return .orderedAscending
            case (.number?, nil):
                return .orderedDescending          // 2.0.1 > 2.0
            case (.text?, nil):
                return .orderedAscending           // 2.0b1 < 2.0
            case (nil, .number?):
                return .orderedAscending
            case (nil, .text?):
                return .orderedDescending
            case (nil, nil):
                return .orderedSame
            }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}
