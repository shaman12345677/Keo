import Foundation

public struct InventoryBundle: Equatable, Sendable {
    public var filename: String
    public var entries: [ZipEntry]
    public var package: PackageInfo
    public var cards: [AssetCard]
    public var locations: [Location]
    public var findings: [FindingCode]

    public init(filename: String, entries: [ZipEntry], package: PackageInfo, cards: [AssetCard], locations: [Location], findings: [FindingCode]) {
        self.filename = filename
        self.entries = entries
        self.package = package
        self.cards = cards
        self.locations = locations
        self.findings = findings
    }

    public static func load(data: Data, filename: String) throws -> InventoryBundle {
        let entries = try ZipArchive.read(data: data)
        guard let cardsEntry = entries.first(where: { ($0.name as NSString).lastPathComponent == "InventarizovaneKarty.xml" }) else {
            throw InventoryError.missingCards
        }
        let cards = try InventoryXML.parseCards(cardsEntry.data)
        guard !cards.isEmpty else { throw InventoryError.missingCards }
        let locations = try entries
            .first { ($0.name as NSString).lastPathComponent == "UtvaryMistnosti.xml" }
            .map { try InventoryXML.parseLocations($0.data) } ?? []
        let findings = try entries
            .first { ($0.name as NSString).lastPathComponent == "KodyZjisteni.xml" }
            .map { try InventoryXML.parseFindings($0.data) } ?? []
        let package: PackageInfo
        if let info = entries.first(where: { ($0.name as NSString).lastPathComponent == "package-info.xml" }) {
            package = try InventoryXML.parsePackage(info.data)
        } else {
            package = PackageInfo(
                description: cards.first?.inventuraNazev ?? "Inventura",
                date: "",
                databaseVersion: "",
                schema: ""
            )
        }
        return InventoryBundle(
            filename: filename,
            entries: entries,
            package: package,
            cards: cards,
            locations: locations,
            findings: findings
        )
    }

    public func exportZip(changes: [String: CardChange], photos: [CardPhoto] = []) throws -> Data {
        let locationsByID = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var patched = entries
        guard let index = patched.firstIndex(where: { ($0.name as NSString).lastPathComponent == "InventarizovaneKarty.xml" }) else {
            throw InventoryError.missingCards
        }
        guard var xml = String(data: patched[index].data, encoding: .utf8) else {
            throw InventoryError.badXML("InventarizovaneKarty.xml")
        }
        xml = try CardPatcher.apply(xml: xml, changes: changes, locations: locationsByID)
        patched[index].data = Data(xml.utf8)
        if !photos.isEmpty {
            patched.removeAll {
                let name = ($0.name as NSString).lastPathComponent
                return name == "FotkyInventarizovaneKarty.xml"
                    || $0.name == "photos/index.csv"
                    || $0.name.hasPrefix("photos/")
            }
            patched.append(ZipEntry(name: "FotkyInventarizovaneKarty.xml", data: CardPhotoExport.makeFotkyXML(photos: photos)))
            patched.append(ZipEntry(name: "photos/index.csv", data: CardPhotoExport.makeIndexCSV(photos: photos)))
            for photo in photos {
                patched.append(ZipEntry(name: photo.zipPath, data: photo.jpegData))
            }
        }
        return try ZipArchive.write(entries: patched)
    }

    public func progress(changes: [String: CardChange]) -> InventoryProgress {
        var result = InventoryProgress(total: cards.count, nalezeno: 0, premisteni: 0, nenalezeno: 0, ostatni: 0)
        for card in cards {
            switch effectiveState(card: card, change: changes[card.id]).stav {
            case "NALEZENO": result.nalezeno += 1
            case "PREMISTENI": result.premisteni += 1
            case "NENALEZENO": result.nenalezeno += 1
            default: result.ostatni += 1
            }
        }
        return result
    }

    public func locationGroups(changes: [String: CardChange]) -> [LocationGroup] {
        var buckets: [String: LocationGroup] = [:]
        for card in cards {
            let state = effectiveState(card: card, change: changes[card.id])
            let key = card.umisteni?.id ?? ""
            var group = buckets[key] ?? LocationGroup(
                id: key,
                title: card.umisteni?.label ?? "Bez umístění",
                sortKey: card.umisteni?.kodUtvaru ?? "zzzz",
                total: 0,
                done: 0
            )
            group.total += 1
            if state.stav == "NALEZENO" || state.stav == "PREMISTENI" {
                group.done += 1
            }
            buckets[key] = group
        }
        return buckets.values.sorted {
            $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending
        }
    }
}

public struct InventoryProgress: Equatable, Sendable {
    public var total: Int
    public var nalezeno: Int
    public var premisteni: Int
    public var nenalezeno: Int
    public var ostatni: Int

    public init(total: Int, nalezeno: Int, premisteni: Int, nenalezeno: Int, ostatni: Int) {
        self.total = total
        self.nalezeno = nalezeno
        self.premisteni = premisteni
        self.nenalezeno = nenalezeno
        self.ostatni = ostatni
    }

    public var done: Int { nalezeno + premisteni + ostatni }
}

public struct LocationGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var sortKey: String
    public var total: Int
    public var done: Int
}
