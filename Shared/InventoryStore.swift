import Foundation
import KeoCore

struct CardPresentation: Identifiable {
    var card: AssetCard
    var stav: String
    var oskenovano: Bool
    var navrh: Location?
    var changed: Bool
    var photoCount: Int

    var id: String { card.id }
}

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var bundle: InventoryBundle?
    @Published private(set) var changes: [String: CardChange] = [:]
    @Published private(set) var photos: [SessionPhoto] = []
    @Published private(set) var filename = ""
    @Published var alert: String?

    private var index = CodeIndex(cards: [])
    private var nextPhotoID = 1
    private let directory: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Keo/session", isDirectory: true)
        loadSession()
    }

    private var photosDirectory: URL {
        directory.appendingPathComponent("photos", isDirectory: true)
    }

    var progress: InventoryProgress {
        bundle?.progress(changes: changes) ?? InventoryProgress(total: 0, nalezeno: 0, premisteni: 0, nenalezeno: 0, ostatni: 0)
    }

    var groups: [LocationGroup] {
        bundle?.locationGroups(changes: changes) ?? []
    }

    func presentation(for card: AssetCard) -> CardPresentation {
        let state = effectiveState(card: card, change: changes[card.id])
        return CardPresentation(
            card: card,
            stav: state.stav,
            oskenovano: state.oskenovano,
            navrh: navrhLocation(id: state.navrhID),
            changed: changes[card.id] != nil,
            photoCount: photos.filter { $0.cardID == card.id }.count
        )
    }

    func presentations(locationID: String?) -> [CardPresentation] {
        guard let bundle else { return [] }
        return bundle.cards
            .filter { card in
                guard let locationID else { return true }
                return (card.umisteni?.id ?? "") == locationID
            }
            .map(presentation(for:))
            .sorted { $0.card.cislo.localizedStandardCompare($1.card.cislo) == .orderedAscending }
    }

    func match(_ raw: String) -> [CardPresentation] {
        index.match(raw).map(presentation(for:))
    }

    func matchLocations(_ raw: String) -> [Location] {
        LocationIndex(locations: bundle?.locations ?? []).match(raw)
    }

    func photos(forCardID id: String) -> [SessionPhoto] {
        photos.filter { $0.cardID == id }
    }

    func photoData(for photo: SessionPhoto) -> Data? {
        try? Data(contentsOf: photosDirectory.appendingPathComponent(photo.fileName))
    }

    func addPhoto(cardID: String, imageData: Data) {
        guard bundle?.cards.contains(where: { $0.id == cardID }) == true,
              let prepared = PhotoCodec.prepareInventoryJPEG(imageData) else {
            alert = "Fotografii se nepodařilo uložit."
            return
        }
        do {
            try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
            let localID = nextPhotoID
            nextPhotoID += 1
            let fileName = CardPhotoExport.makeFileName(localID: localID)
            try prepared.full.write(to: photosDirectory.appendingPathComponent(fileName), options: .atomic)
            try prepared.thumb.write(to: photosDirectory.appendingPathComponent(thumbName(fileName)), options: .atomic)
            photos.append(SessionPhoto(cardID: cardID, localID: localID, fileName: fileName))
            savePhotosMeta()
            objectWillChange.send()
        } catch {
            alert = error.localizedDescription
        }
    }

    func removePhoto(_ photo: SessionPhoto) {
        photos.removeAll { $0.fileName == photo.fileName }
        try? FileManager.default.removeItem(at: photosDirectory.appendingPathComponent(photo.fileName))
        try? FileManager.default.removeItem(at: photosDirectory.appendingPathComponent(thumbName(photo.fileName)))
        savePhotosMeta()
        objectWillChange.send()
    }

    func markFound(_ id: String) {
        apply(.nalezeno(), to: id)
    }

    func markMissing(_ id: String) {
        apply(.nenalezeno(), to: id)
    }

    func markMoved(_ id: String, location: Location) {
        apply(.premisteni(locationID: location.id), to: id)
    }

    func revert(_ id: String) {
        changes.removeValue(forKey: id)
        saveChanges()
    }

    func importFile(at url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            let loaded = try InventoryBundle.load(data: data, filename: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("inventory.zip"), options: .atomic)
            let meta = SessionMeta(filename: name)
            try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
            changes = [:]
            try JSONEncoder().encode(changes).write(to: directory.appendingPathComponent("changes.json"), options: .atomic)
            try resetPhotosDirectory()
            photos = try importPhotos(from: loaded)
            nextPhotoID = (photos.map(\.localID).max() ?? 0) + 1
            savePhotosMeta()
            bundle = loaded
            filename = name
            index = CodeIndex(cards: loaded.cards)
        } catch {
            alert = error.localizedDescription
        }
    }

    func makeExport() throws -> (name: String, data: Data) {
        guard let bundle else { throw InventoryError.missingCards }
        let stamp = exportStamp(Date())
        let cardPhotos = try exportPhotos()
        let data = try bundle.exportZip(changes: changes, photos: cardPhotos)
        return ("keo4-export-\(stamp).zip", data)
    }

    func reset() {
        bundle = nil
        changes = [:]
        photos = []
        nextPhotoID = 1
        filename = ""
        index = CodeIndex(cards: [])
        try? FileManager.default.removeItem(at: directory)
    }

    private func apply(_ change: CardChange, to id: String) {
        guard let card = bundle?.cards.first(where: { $0.id == id }) else { return }
        if changeMatchesOriginal(change, card: card) {
            changes.removeValue(forKey: id)
        } else {
            changes[id] = change
        }
        saveChanges()
    }

    private func navrhLocation(id: String?) -> Location? {
        guard let id, let bundle else { return nil }
        if let known = bundle.locations.first(where: { $0.id == id }) { return known }
        return bundle.cards.first { $0.umisteni?.id == id }?.umisteni
    }

    private func loadSession() {
        let zipURL = directory.appendingPathComponent("inventory.zip")
        guard FileManager.default.fileExists(atPath: zipURL.path),
              let data = try? Data(contentsOf: zipURL) else { return }
        let metaURL = directory.appendingPathComponent("meta.json")
        let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(SessionMeta.self, from: $0) }
        do {
            let loaded = try InventoryBundle.load(data: data, filename: meta?.filename ?? "Inventura.zip")
            let changeURL = directory.appendingPathComponent("changes.json")
            let stored = (try? Data(contentsOf: changeURL)).flatMap { try? JSONDecoder().decode([String: CardChange].self, from: $0) } ?? [:]
            let photoMeta = loadPhotosMeta()
            bundle = loaded
            filename = loaded.filename
            changes = stored
            photos = photoMeta?.photos ?? []
            nextPhotoID = photoMeta?.nextID ?? ((photos.map(\.localID).max() ?? 0) + 1)
            index = CodeIndex(cards: loaded.cards)
        } catch {
            alert = error.localizedDescription
        }
    }

    private func saveChanges() {
        let url = directory.appendingPathComponent("changes.json")
        try? JSONEncoder().encode(changes).write(to: url, options: .atomic)
    }

    private func savePhotosMeta() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = PhotosMeta(nextID: nextPhotoID, photos: photos)
        try? JSONEncoder().encode(meta).write(to: directory.appendingPathComponent("photos.json"), options: .atomic)
    }

    private func loadPhotosMeta() -> PhotosMeta? {
        let url = directory.appendingPathComponent("photos.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhotosMeta.self, from: data)
    }

    private func resetPhotosDirectory() throws {
        if FileManager.default.fileExists(atPath: photosDirectory.path) {
            try FileManager.default.removeItem(at: photosDirectory)
        }
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        photos = []
        nextPhotoID = 1
    }

    private func importPhotos(from bundle: InventoryBundle) throws -> [SessionPhoto] {
        var imported: [SessionPhoto] = []
        let xmlEntry = bundle.entries.first { ($0.name as NSString).lastPathComponent == "FotkyInventarizovaneKarty.xml" }
        let xml = xmlEntry.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        let pairs = parsePhotoLinks(xml: xml)
        let byPath = Dictionary(uniqueKeysWithValues: pairs.map { ($0.zipPath, $0.cardID) })
        for entry in bundle.entries where entry.name.hasPrefix("photos/") && entry.name.lowercased().hasSuffix(".jpg") {
            let fileName = (entry.name as NSString).lastPathComponent
            guard let cardID = byPath[entry.name] ?? byPath["photos/\(fileName)"] else { continue }
            guard let prepared = PhotoCodec.prepareInventoryJPEG(entry.data) else { continue }
            let localID = nextImportID(from: fileName, fallback: imported.count + 1)
            let storedName = fileName
            try prepared.full.write(to: photosDirectory.appendingPathComponent(storedName), options: .atomic)
            try prepared.thumb.write(to: photosDirectory.appendingPathComponent(thumbName(storedName)), options: .atomic)
            imported.append(SessionPhoto(cardID: cardID, localID: localID, fileName: storedName))
        }
        return imported.sorted { $0.localID < $1.localID }
    }

    private func nextImportID(from fileName: String, fallback: Int) -> Int {
        let parts = fileName.split(separator: "_")
        if parts.count >= 2, let value = Int(parts[1]) { return value }
        return fallback
    }

    private func parsePhotoLinks(xml: String) -> [(zipPath: String, cardID: String)] {
        var result: [(String, String)] = []
        var search = xml.startIndex
        while let open = xml.range(of: "<MblFotkaInventarizovaneKarty>", range: search..<xml.endIndex),
              let close = xml.range(of: "</MblFotkaInventarizovaneKarty>", range: open.lowerBound..<xml.endIndex) {
            let slice = String(xml[open.lowerBound..<close.upperBound])
            let cardID = firstTag("id", in: firstBlock("inventarizovanaKarta", in: slice) ?? "") ?? ""
            let zipPath = firstTag("zipPath", in: slice) ?? ""
            if !cardID.isEmpty, !zipPath.isEmpty {
                result.append((zipPath, cardID))
            }
            search = close.upperBound
        }
        return result
    }

    private func firstBlock(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private func firstTag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private func exportPhotos() throws -> [CardPhoto] {
        try photos.map { photo in
            let jpeg = try Data(contentsOf: photosDirectory.appendingPathComponent(photo.fileName))
            let thumbURL = photosDirectory.appendingPathComponent(thumbName(photo.fileName))
            let thumb: Data
            if let existing = try? Data(contentsOf: thumbURL) {
                thumb = existing
            } else if let prepared = PhotoCodec.prepareInventoryJPEG(jpeg) {
                thumb = prepared.thumb
            } else {
                thumb = jpeg
            }
            return CardPhoto(
                cardID: photo.cardID,
                localID: photo.localID,
                fileName: photo.fileName,
                jpegData: jpeg,
                thumbJpegData: thumb
            )
        }
    }

    private func thumbName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension + ".thumb.jpg"
    }

    private func exportStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

struct SessionPhoto: Codable, Identifiable, Equatable {
    var cardID: String
    var localID: Int
    var fileName: String

    var id: String { fileName }
}

private struct SessionMeta: Codable {
    var filename: String
}

private struct PhotosMeta: Codable {
    var nextID: Int
    var photos: [SessionPhoto]
}
