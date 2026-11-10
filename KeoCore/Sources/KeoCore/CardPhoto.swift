import Foundation

/// Fotografie z inventury ve formátu Android KEO4 Majetek.
public struct CardPhoto: Equatable, Sendable {
    public var cardID: String
    public var localID: Int
    public var fileName: String
    public var jpegData: Data
    public var thumbJpegData: Data

    public init(cardID: String, localID: Int, fileName: String, jpegData: Data, thumbJpegData: Data) {
        self.cardID = cardID
        self.localID = localID
        self.fileName = fileName
        self.jpegData = jpegData
        self.thumbJpegData = thumbJpegData
    }

    public var zipPath: String { "photos/\(fileName)" }
}

public enum CardPhotoExport {
    public static func makeFileName(localID: Int, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "karta_\(localID)_\(formatter.string(from: date)).jpg"
    }

    public static func makeIndexCSV(photos: [CardPhoto]) -> Data {
        var lines = ["foto_android_id;karta_android_id;zip_path"]
        for photo in photos {
            lines.append("\(photo.localID);\(photo.localID);\(photo.zipPath)")
        }
        return Data(lines.joined(separator: "\n").appending("\n").utf8)
    }

    public static func makeFotkyXML(photos: [CardPhoto]) -> Data {
        var body = "<list>\n"
        for photo in photos {
            let base64 = photo.thumbJpegData.base64EncodedString()
            body += """
              <MblFotkaInventarizovaneKarty>
                <id>0</id>
                <version>0</version>
                <base64Data>\(base64)</base64Data>
                <inventarizovanaKarta>
                  <id>\(escape(photo.cardID))</id>
                  <version>0</version>
                  <hiden>false</hiden>
                  <oskenovano>false</oskenovano>
                  <porizCenaUcetni>0</porizCenaUcetni>
                  <premisteniSchvaleno>false</premisteniSchvaleno>
                  <ucetniOpravky>0</ucetniOpravky>
                  <vyrizeno>false</vyrizeno>
                  <zustatkovaHodnota>0</zustatkovaHodnota>
                </inventarizovanaKarta>
                <nazev>\(escape(photo.fileName))</nazev>
                <zipPath>\(escape(photo.zipPath))</zipPath>
              </MblFotkaInventarizovaneKarty>

            """
        }
        body += "</list>"
        return Data(body.utf8)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
