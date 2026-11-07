import Foundation

enum Screenshot: String {
    case home
    case places
    case room
    case detail
    case scan

    static var current: Screenshot? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screenshot"),
              arguments.indices.contains(index + 1) else { return nil }
        return Screenshot(rawValue: arguments[index + 1])
    }
}

struct ScreenshotDetail: Hashable {
    var cardID: String
}
