import Foundation

public struct PackageInfo: Equatable, Sendable {
    public var description: String
    public var date: String
    public var databaseVersion: String
    public var schema: String

    public init(description: String, date: String, databaseVersion: String, schema: String) {
        self.description = description
        self.date = date
        self.databaseVersion = databaseVersion
        self.schema = schema
    }
}

public struct Location: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var version: String
    public var kodUtvaru: String
    public var kodMistnosti: String
    public var nazev: String

    public init(id: String, version: String, kodUtvaru: String, kodMistnosti: String, nazev: String) {
        self.id = id
        self.version = version
        self.kodUtvaru = kodUtvaru
        self.kodMistnosti = kodMistnosti
        self.nazev = nazev
    }

    public var label: String {
        let code = [kodUtvaru, kodMistnosti].filter { !$0.isEmpty }.joined(separator: " / ")
        if nazev.isEmpty { return code.isEmpty ? "Bez názvu" : code }
        if code.isEmpty { return nazev }
        return "\(code) · \(nazev)"
    }

    static let empty = Location(id: "", version: "0", kodUtvaru: "", kodMistnosti: "", nazev: "")
}

public struct FindingCode: Identifiable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var kod: String
    public var nazev: String

    public init(id: String, version: String, kod: String, nazev: String) {
        self.id = id
        self.version = version
        self.kod = kod
        self.nazev = nazev
    }
}

public struct AssetCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var inventarniCislo: String
    public var nazevMajetku: String
    public var typMajetku: String
    public var podtypMajetku: String
    public var porizCenaUcetni: String
    public var ucetniOpravky: String
    public var zustatkovaHodnota: String
    public var datumZarazeni: String
    public var umisteni: Location?
    public var umisteniReference: String?
    public var vyrazZustCena: String
    public var zivotnost: String?
    public var organizace: String
    public var stavInventarizace: String
    public var vyrizeno: Bool
    public var premisteniSchvaleno: Bool
    public var oskenovano: Bool
    public var inventuraID: String
    public var inventuraNazev: String
    public var inventuraReference: String?
    public var navrh: Location?
    public var navrhReference: String?

    public var cislo: String {
        inventarniCislo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let empty = AssetCard(
        id: "",
        version: "0",
        inventarniCislo: "",
        nazevMajetku: "",
        typMajetku: "",
        podtypMajetku: "",
        porizCenaUcetni: "",
        ucetniOpravky: "",
        zustatkovaHodnota: "",
        datumZarazeni: "",
        umisteni: nil,
        umisteniReference: nil,
        vyrazZustCena: "",
        zivotnost: nil,
        organizace: "",
        stavInventarizace: "NENALEZENO",
        vyrizeno: false,
        premisteniSchvaleno: false,
        oskenovano: false,
        inventuraID: "",
        inventuraNazev: "",
        inventuraReference: nil,
        navrh: nil,
        navrhReference: nil
    )
}

public struct CardChange: Codable, Equatable, Sendable {
    public var stav: String
    public var oskenovano: Bool
    public var navrhPremisteniID: String?

    public init(stav: String, oskenovano: Bool, navrhPremisteniID: String?) {
        self.stav = stav
        self.oskenovano = oskenovano
        self.navrhPremisteniID = navrhPremisteniID
    }

    public static func nalezeno() -> CardChange {
        CardChange(stav: "NALEZENO", oskenovano: true, navrhPremisteniID: nil)
    }

    public static func nenalezeno() -> CardChange {
        CardChange(stav: "NENALEZENO", oskenovano: false, navrhPremisteniID: nil)
    }

    public static func premisteni(locationID: String) -> CardChange {
        CardChange(stav: "PREMISTENI", oskenovano: true, navrhPremisteniID: locationID)
    }
}

public struct EffectiveCard: Equatable, Sendable {
    public var stav: String
    public var oskenovano: Bool
    public var navrhID: String?

    public init(stav: String, oskenovano: Bool, navrhID: String?) {
        self.stav = stav
        self.oskenovano = oskenovano
        self.navrhID = navrhID
    }
}

public enum InventoryError: LocalizedError, Equatable {
    case notAZip
    case missingCards
    case badXML(String)
    case unknownLocation(String)
    case zipCorrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip:
            return "Soubor není zip s inventurou."
        case .missingCards:
            return "V zipu chybí InventarizovaneKarty.xml."
        case .badXML(let name):
            return "Nepodařilo se přečíst \(name)."
        case .unknownLocation(let id):
            return "Umístění \(id) v číselníku chybí."
        case .zipCorrupt(let detail):
            return "Zip nejde přečíst (\(detail))."
        }
    }
}

public func effectiveState(card: AssetCard, change: CardChange?) -> EffectiveCard {
    if let change {
        return EffectiveCard(stav: change.stav, oskenovano: change.oskenovano, navrhID: change.navrhPremisteniID)
    }
    return EffectiveCard(
        stav: card.stavInventarizace,
        oskenovano: card.oskenovano,
        navrhID: card.navrh?.id
    )
}

public func changeMatchesOriginal(_ change: CardChange, card: AssetCard) -> Bool {
    let original = effectiveState(card: card, change: nil)
    return change.stav == original.stav
        && change.oskenovano == original.oskenovano
        && change.navrhPremisteniID == original.navrhID
}

public func normalizeCode(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
}

public struct CodeIndex: Sendable {
    private let byCode: [String: [AssetCard]]

    public init(cards: [AssetCard]) {
        var map: [String: [AssetCard]] = [:]
        for card in cards {
            let key = normalizeCode(card.inventarniCislo)
            guard !key.isEmpty else { continue }
            map[key, default: []].append(card)
        }
        byCode = map
    }

    public func match(_ raw: String) -> [AssetCard] {
        let prefix = matchLongestPrefix(raw)
        if !prefix.isEmpty { return prefix }
        let leading = matchLeadingNumber(raw)
        if !leading.isEmpty { return leading }
        if let extended = matchFirstLineExtension(raw), !extended.isEmpty {
            return extended
        }
        for token in codeTokens(raw) {
            guard let cards = byCode[token], !cards.isEmpty else { continue }
            if Self.isYear(token) || Self.isNumberInsideName(token, raw: raw) { continue }
            return cards
        }
        return []
    }

    /// Štítek má „1016“, v evidenci je „1016-POD“. Čtečka k tomu přilepí název.
    private func matchLeadingNumber(_ raw: String) -> [AssetCard] {
        let haystack = raw.lowercased().filter { !$0.isWhitespace }
        let digits = String(haystack.prefix { $0.isNumber })
        guard digits.count >= 3 else { return [] }
        if let exact = byCode[digits] { return exact }
        return byCode.compactMap { code, cards in
            code.hasPrefix(digits + "-") ? cards : nil
        }.flatMap { $0 }
    }

    /// První řádek štítku je jen „1016“, v evidenci je „1016-POD“.
    private func matchFirstLineExtension(_ raw: String) -> [AssetCard]? {
        let line = raw.split(whereSeparator: \.isNewline)
            .map { normalizeCode(String($0)) }
            .first { !$0.isEmpty } ?? ""
        guard line.count >= 2 else { return nil }
        if let exact = byCode[line] { return exact }
        let extended = byCode.filter { $0.key.hasPrefix(line + "-") }
        guard extended.count == 1, let only = extended.values.first else { return nil }
        return only
    }

    /// „55“ v názvu Televize LG 55 není inventární číslo tabule.
    private static func isNumberInsideName(_ token: String, raw: String) -> Bool {
        guard token.count <= 3, token.allSatisfy(\.isNumber) else { return false }
        let firstLine = raw.split(whereSeparator: \.isNewline)
            .map { normalizeCode(String($0)) }
            .first { !$0.isEmpty } ?? ""
        return token != firstLine
    }

    private static func isYear(_ code: String) -> Bool {
        guard code.count == 4, code.allSatisfy(\.isNumber), let year = Int(code) else { return false }
        return (1900...2099).contains(year)
    }

    /// Když čtečka slepí číslo s názvem, platí nejdelší známý kód na začátku textu.
    private func matchLongestPrefix(_ raw: String) -> [AssetCard] {
        let haystack = raw.lowercased().filter { !$0.isWhitespace }
        guard haystack.count > 1 else { return [] }
        var bestCount = 0
        var best: [AssetCard] = []
        for (code, cards) in byCode where code.count > bestCount && haystack.hasPrefix(code) {
            bestCount = code.count
            best = cards
        }
        return best
    }
}

public struct LocationIndex: Sendable {
    private let locations: [Location]
    private let byKey: [String: [Location]]
    private let codeKeys: [String: [Location]]

    public init(locations: [Location]) {
        self.locations = locations
        var codes: [String: [Location]] = [:]
        var names: [String: [Location]] = [:]
        func add(_ key: String, _ place: Location, codesOnly: Bool) {
            let normalized = normalizeCode(key)
            guard !normalized.isEmpty else { return }
            var target = codesOnly ? codes[normalized, default: []] : names[normalized, default: []]
            if !target.contains(where: { $0.id == place.id }) {
                target.append(place)
            }
            if codesOnly {
                codes[normalized] = target
            } else {
                names[normalized] = target
            }
        }
        for place in locations {
            add(place.id, place, codesOnly: true)
            add(place.kodUtvaru, place, codesOnly: true)
            if !place.kodMistnosti.isEmpty {
                add(place.kodMistnosti, place, codesOnly: true)
                add("\(place.kodUtvaru)/\(place.kodMistnosti)", place, codesOnly: true)
                add("\(place.kodUtvaru)-\(place.kodMistnosti)", place, codesOnly: true)
                add(place.kodUtvaru + place.kodMistnosti, place, codesOnly: true)
            }
            add(place.nazev, place, codesOnly: false)
        }
        codeKeys = codes
        byKey = codes.merging(names) { current, _ in current }
    }

    public func match(_ raw: String) -> [Location] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let whole = normalizeCode(trimmed)
        if whole.isEmpty || whole == "v:2" { return [] }
        if let hit = byKey[whole], !hit.isEmpty { return Self.sorted(hit) }
        let collapsed = Self.collapse(trimmed)
        if collapsed != whole, let hit = byKey[collapsed], !hit.isEmpty { return Self.sorted(hit) }
        let first = trimmed.split(whereSeparator: \.isNewline)
            .map { normalizeCode(String($0)) }
            .first { !$0.isEmpty && $0 != "v:2" } ?? ""
        if let hit = byKey[first], !hit.isEmpty { return Self.sorted(hit) }
        if let prefixed = longestCodePrefix(collapsed), !prefixed.isEmpty { return Self.sorted(prefixed) }
        if collapsed.allSatisfy(\.isNumber), let value = Int(collapsed), value > 0 {
            let numeric = locations.filter {
                Self.codeEquals($0.kodUtvaru, value) || Self.codeEquals($0.kodMistnosti, value)
            }
            if !numeric.isEmpty { return Self.sorted(numeric) }
        }
        return []
    }

    private func longestCodePrefix(_ haystack: String) -> [Location]? {
        guard haystack.count > 1 else { return nil }
        var best = 0
        var found: [Location] = []
        for (code, places) in codeKeys where code.count >= 2 && code.count > best && haystack.hasPrefix(code) {
            best = code.count
            found = places
        }
        guard best > 0 else { return nil }
        var merged = found
        for (code, places) in codeKeys where code.count == best && haystack.hasPrefix(code) {
            for place in places where !merged.contains(where: { $0.id == place.id }) {
                merged.append(place)
            }
        }
        return merged
    }

    private static func collapse(_ raw: String) -> String {
        raw.lowercased().filter { !$0.isWhitespace && $0 != "/" && $0 != "-" }
    }

    private static func codeEquals(_ code: String, _ value: Int) -> Bool {
        guard !code.isEmpty, code.allSatisfy(\.isNumber), let number = Int(code) else { return false }
        return number == value
    }

    private static func sorted(_ places: [Location]) -> [Location] {
        var seen: [String: Location] = [:]
        for place in places where seen[place.id] == nil {
            seen[place.id] = place
        }
        return seen.values.sorted { $0.id < $1.id }
    }
}

func codeTokens(_ raw: String) -> [String] {
    let separators = CharacterSet(charactersIn: "\n\r\t;|, ")
    var tokens: [String] = []
    func add(_ value: String) {
        let token = normalizeCode(value)
        if token.isEmpty || token == "v:2" { return }
        if !tokens.contains(token) { tokens.append(token) }
    }
    add(raw)
    for part in raw.components(separatedBy: separators) {
        add(part)
    }
    return tokens
}

public func statusTitle(_ stav: String) -> String {
    switch stav {
    case "NALEZENO": return "Nalezeno"
    case "PREMISTENI": return "Přemístění"
    case "NENALEZENO": return "Nenalezeno"
    default: return stav
    }
}
