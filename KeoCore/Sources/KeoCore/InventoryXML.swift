import Foundation

enum InventoryXML {
    static func parsePackage(_ data: Data) throws -> PackageInfo {
        let parser = NodeParser()
        try parser.parse(data, label: "package-info.xml")
        return parser.package
    }

    static func parseCards(_ data: Data) throws -> [AssetCard] {
        let parser = NodeParser()
        try parser.parse(data, label: "InventarizovaneKarty.xml")
        var cards = parser.cards
        resolveReferences(&cards)
        return cards
    }

    static func parseLocations(_ data: Data) throws -> [Location] {
        let parser = NodeParser()
        try parser.parse(data, label: "UtvaryMistnosti.xml")
        return parser.locations
    }

    static func parseFindings(_ data: Data) throws -> [FindingCode] {
        let parser = NodeParser()
        try parser.parse(data, label: "KodyZjisteni.xml")
        return parser.findings
    }
}

private final class NodeParser: NSObject, XMLParserDelegate {
    var package = PackageInfo(description: "", date: "", databaseVersion: "", schema: "")
    var cards: [AssetCard] = []
    var locations: [Location] = []
    var findings: [FindingCode] = []

    private var stack: [String] = []
    private var text = ""
    private var card: AssetCard?
    private var listLocation: Location?
    private var nestedLocation: Location?
    private var nestedKey: String?
    private var finding: FindingCode?
    private var failure: String?

    func parse(_ data: Data, label: String) throws {
        let xml = XMLParser(data: data)
        xml.delegate = self
        xml.shouldProcessNamespaces = false
        guard xml.parse(), failure == nil else {
            throw InventoryError.badXML(failure ?? label)
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        let parent = stack.last
        stack.append(name)
        switch name {
        case "MblInventarizovanaKarta":
            card = .empty
        case "MblUtvaryMistnosti":
            listLocation = .empty
        case "MblKodZjisteni":
            finding = FindingCode(id: "", version: "0", kod: "", nazev: "")
        case "umisteni", "navrhPremisteni":
            if parent == "MblInventarizovanaKarta" {
                if let reference = attributeDict["reference"] {
                    if name == "umisteni" {
                        card?.umisteniReference = reference
                    } else {
                        card?.navrhReference = reference
                    }
                } else {
                    nestedLocation = .empty
                    nestedKey = name
                }
            }
        case "inventura":
            if let reference = attributeDict["reference"] {
                card?.inventuraReference = reference
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let parent = stack.dropLast().last
        let value = text
        switch name {
        case "MblInventarizovanaKarta":
            if let card { cards.append(card) }
            card = nil
        case "MblUtvaryMistnosti":
            if let listLocation { locations.append(listLocation) }
            listLocation = nil
        case "MblKodZjisteni":
            if let finding { findings.append(finding) }
            finding = nil
        case "umisteni", "navrhPremisteni":
            if nestedKey == name, let nestedLocation {
                if name == "umisteni" {
                    card?.umisteni = nestedLocation
                } else {
                    card?.navrh = nestedLocation
                }
            }
            nestedLocation = nil
            nestedKey = nil
        default:
            apply(name: name, parent: parent, value: value)
        }
        stack.removeLast()
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError.localizedDescription
    }

    private func apply(name: String, parent: String?, value: String) {
        switch parent {
        case "package-info":
            switch name {
            case "description": package.description = value.trimmed
            case "date": package.date = value.trimmed
            case "databaseVersion": package.databaseVersion = value.trimmed
            case "schema": package.schema = value.trimmed
            default: break
            }
        case "MblInventarizovanaKarta":
            guard card != nil else { return }
            switch name {
            case "id": card?.id = value.trimmed
            case "version": card?.version = value.trimmed
            case "inventarniCislo": card?.inventarniCislo = value.withoutNewlines
            case "nazevMajetku": card?.nazevMajetku = value.trimmed
            case "typMajetku": card?.typMajetku = value.trimmed
            case "podtypMajetku": card?.podtypMajetku = value.trimmed
            case "porizCenaUcetni": card?.porizCenaUcetni = value.trimmed
            case "ucetniOpravky": card?.ucetniOpravky = value.trimmed
            case "zustatkovaHodnota": card?.zustatkovaHodnota = value.trimmed
            case "datumZarazeni": card?.datumZarazeni = value.trimmed
            case "vyrazZustCena": card?.vyrazZustCena = value.trimmed
            case "zivotnost": card?.zivotnost = value.trimmed
            case "organizace": card?.organizace = value.trimmed
            case "stavInventarizace": card?.stavInventarizace = value.trimmed
            case "vyrizeno": card?.vyrizeno = value.trimmed == "true"
            case "premisteniSchvaleno": card?.premisteniSchvaleno = value.trimmed == "true"
            case "oskenovano": card?.oskenovano = value.trimmed == "true"
            default: break
            }
        case "inventura":
            switch name {
            case "id": card?.inventuraID = value.trimmed
            case "nazev": card?.inventuraNazev = value.trimmed
            default: break
            }
        case "umisteni", "navrhPremisteni":
            guard var place = nestedLocation else { return }
            setLocation(name, value, into: &place)
            nestedLocation = place
        case "MblUtvaryMistnosti":
            guard var place = listLocation else { return }
            setLocation(name, value, into: &place)
            listLocation = place
        case "MblKodZjisteni":
            switch name {
            case "id": finding?.id = value.trimmed
            case "version": finding?.version = value.trimmed
            case "kod": finding?.kod = value.trimmed
            case "nazev": finding?.nazev = value.trimmed
            default: break
            }
        default:
            break
        }
    }

    private func setLocation(_ name: String, _ value: String, into location: inout Location) {
        switch name {
        case "id": location.id = value.trimmed
        case "version": location.version = value.trimmed
        case "kodUtvaru": location.kodUtvaru = value.trimmed
        case "kodMistnosti": location.kodMistnosti = value.trimmed
        case "nazev": location.nazev = value.trimmed
        default: break
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var withoutNewlines: String {
        replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    }
}

func resolveReferences(_ cards: inout [AssetCard]) {
    for index in cards.indices {
        if cards[index].umisteni == nil, let path = cards[index].umisteniReference {
            cards[index].umisteni = location(at: path, in: cards, visiting: [])
        }
        if cards[index].navrh == nil, let path = cards[index].navrhReference {
            cards[index].navrh = location(at: path, in: cards, visiting: [])
        }
        if cards[index].inventuraID.isEmpty, let path = cards[index].inventuraReference {
            if let found = inventory(at: path, in: cards, visiting: []) {
                cards[index].inventuraID = found.id
                cards[index].inventuraNazev = found.name
            }
        }
    }
}

private func location(at path: String, in cards: [AssetCard], visiting: Set<String>) -> Location? {
    guard !visiting.contains(path), let target = xstreamTarget(path), target.index >= 0, target.index < cards.count else {
        return nil
    }
    let card = cards[target.index]
    switch target.field {
    case "umisteni":
        if let place = card.umisteni { return place }
        if let next = card.umisteniReference {
            return location(at: next, in: cards, visiting: visiting.union([path]))
        }
    case "navrhPremisteni":
        if let place = card.navrh { return place }
        if let next = card.navrhReference {
            return location(at: next, in: cards, visiting: visiting.union([path]))
        }
    default:
        return nil
    }
    return nil
}

private func inventory(at path: String, in cards: [AssetCard], visiting: Set<String>) -> (id: String, name: String)? {
    guard !visiting.contains(path), let target = xstreamTarget(path), target.index >= 0, target.index < cards.count else {
        return nil
    }
    let card = cards[target.index]
    if !card.inventuraID.isEmpty {
        return (card.inventuraID, card.inventuraNazev)
    }
    if let next = card.inventuraReference {
        return inventory(at: next, in: cards, visiting: visiting.union([path]))
    }
    return nil
}

private func xstreamTarget(_ path: String) -> (index: Int, field: String)? {
    guard let range = path.range(of: "MblInventarizovanaKarta") else { return nil }
    var rest = path[range.upperBound...]
    var index = 0
    if rest.hasPrefix("[") {
        rest = rest.dropFirst()
        let digits = rest.prefix(while: \.isNumber)
        index = (Int(digits) ?? 1) - 1
        rest = rest.dropFirst(digits.count)
        if rest.hasPrefix("]") { rest = rest.dropFirst() }
    }
    if rest.hasPrefix("/") { rest = rest.dropFirst() }
    let field = String(rest)
    guard !field.isEmpty else { return nil }
    return (index, field)
}
