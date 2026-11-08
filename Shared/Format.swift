import Foundation

enum Format {
    static func date(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "—" }
        if trimmed.count >= 10, !trimmed.contains(":") {
            let day = String(trimmed.prefix(10))
            calendarParser.dateFormat = "yyyy-MM-dd"
            calendarParser.timeZone = TimeZone(identifier: "Europe/Prague")
            if let date = calendarParser.date(from: day) {
                return output.string(from: date)
            }
        }
        timestampParser.dateFormat = "yyyy-MM-dd HH:mm:ss.S zzz"
        timestampParser.timeZone = TimeZone(identifier: "UTC")
        if let date = timestampParser.date(from: trimmed) {
            return output.string(from: date)
        }
        return String(trimmed.prefix(10))
    }

    static func money(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return raw }
        return currency.string(from: NSNumber(value: value)) ?? raw
    }

    static func packageDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        packageParser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = packageParser.date(from: trimmed) {
            packageOutput.dateFormat = "d. M. yyyy HH:mm"
            return packageOutput.string(from: date)
        }
        return trimmed
    }

    private static let output: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.timeZone = TimeZone(identifier: "Europe/Prague")
        formatter.dateFormat = "d. M. yyyy"
        return formatter
    }()

    private static let calendarParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let timestampParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let packageParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static let packageOutput: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.timeZone = .current
        return formatter
    }()

    private static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CZK"
        formatter.locale = Locale(identifier: "cs_CZ")
        return formatter
    }()
}
