import Foundation
import KeoCore

struct CardPresentation: Identifiable {
    var card: AssetCard
    var stav: String
    var oskenovano: Bool
    var navrh: Location?
    var changed: Bool

    var id: String { card.id }
}

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var bundle: InventoryBundle?
    @Published private(set) var changes: [String: CardChange] = [:]
    @Published private(set) var filename = ""
    @Published var alert: String?

    private var index = CodeIndex(cards: [])
    private let directory: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Keo/session", isDirectory: true)
        loadSession()
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
            changed: changes[card.id] != nil
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
        let data = try bundle.exportZip(changes: changes)
        return ("keo4-export-\(stamp).zip", data)
    }

    func reset() {
        bundle = nil
        changes = [:]
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
            bundle = loaded
            filename = loaded.filename
            changes = stored
            index = CodeIndex(cards: loaded.cards)
        } catch {
            alert = error.localizedDescription
        }
    }

    private func saveChanges() {
        let url = directory.appendingPathComponent("changes.json")
        try? JSONEncoder().encode(changes).write(to: url, options: .atomic)
    }

    private func exportStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private struct SessionMeta: Codable {
    var filename: String
}
