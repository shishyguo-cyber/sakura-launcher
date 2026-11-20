import Foundation

public enum Greeting {
    public static let maxNameLength = 20

    public static func normalizedName(_ input: String?) throws -> String? {
        guard let name = input?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard name.count <= maxNameLength,
              name.rangeOfCharacter(from: .newlines) == nil,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ExperienceError.invalid("称呼最多 20 个字符，请填写一行。")
        }
        return name
    }

    public enum Light: String, CaseIterable, Sendable {
        case dawn, daylight, dusk, moonlight

        public init(hour: Int) {
            switch hour {
            case 5..<12: self = .dawn
            case 12..<18: self = .daylight
            case 18..<23: self = .dusk
            default: self = .moonlight
            }
        }

        public var salutation: String {
            switch self {
            case .dawn: return "Good morning"
            case .daylight: return "Good afternoon"
            case .dusk, .moonlight: return "Good evening"
            }
        }
    }

    public enum Style: String, Sendable {
        /// A · light pen, B · light sweep, C · rainbow neon handwriting ("welcome <name>").
        case pen, sweep, script
    }

    /// Style C writes "welcome" plus the nickname in a script hand, lowercase like a signature.
    public static func scriptText(name: String?) -> String {
        guard let name, !name.isEmpty else { return "welcome" }
        return "welcome " + name
    }

    /// Emoji are colour bitmaps with no pen strokes to trace; such names fall back to the light sweep.
    public static func scriptCanWrite(name: String?) -> Bool {
        guard let name else { return true }
        return !name.unicodeScalars.contains { scalar in
            let p = scalar.properties
            return p.isEmojiPresentation || (p.isEmoji && scalar.value > 0x2000) || scalar.value == 0xFE0F
        }
    }

    public enum Treatment: Equatable, Sendable {
        case animated(Style)
        case still

        public init(style: Style, reduceMotion: Bool) {
            self = reduceMotion ? .still : .animated(style)
        }

        public var allowsDocking: Bool { self != .still }
    }

    public static func light(at date: Date, calendar: Calendar = .current) -> Light {
        Light(hour: calendar.component(.hour, from: date))
    }

    public static func text(at date: Date, calendar: Calendar = .current, name: String?) -> String {
        let greeting = light(at: date, calendar: calendar).salutation
        guard let name, !name.isEmpty else { return greeting }
        return greeting + ", " + name
    }
}
