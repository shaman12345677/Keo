import Foundation

enum CardPatcher {
    static func apply(xml: String, changes: [String: CardChange], locations: [String: Location]) throws -> String {
        guard !changes.isEmpty else { return xml }
        var output = ""
        var cursor = xml.startIndex
        while let open = xml.range(of: "<MblInventarizovanaKarta", range: cursor..<xml.endIndex) {
            output += xml[cursor..<open.lowerBound]
            guard let close = xml.range(of: "</MblInventarizovanaKarta>", range: open.lowerBound..<xml.endIndex) else {
                throw InventoryError.badXML("InventarizovaneKarty.xml")
            }
            let cardXML = String(xml[open.lowerBound..<close.upperBound])
            let id = topLevelText("id", in: cardXML) ?? ""
            if let change = changes[id] {
                output += try patch(cardXML, change: change, locations: locations)
            } else {
                output += cardXML
            }
            cursor = close.upperBound
        }
        output += xml[cursor...]
        return output
    }

    private static func patch(_ card: String, change: CardChange, locations: [String: Location]) throws -> String {
        var result = card
        result = setTopLevelText("stavInventarizace", value: change.stav, in: result)
        result = setTopLevelText("oskenovano", value: change.oskenovano ? "true" : "false", in: result)
        if let locationID = change.navrhPremisteniID {
            guard let location = locations[locationID] else { throw InventoryError.unknownLocation(locationID) }
            result = setRelocation(location, in: result)
        } else {
            result = removeTopLevel("navrhPremisteni", in: result)
        }
        return result
    }

    private static func setRelocation(_ location: Location, in card: String) -> String {
        let version = location.version.isEmpty ? "0" : location.version
        let block = [
            "<navrhPremisteni>",
            "      <id>\(xmlEscape(location.id))</id>",
            "      <version>\(xmlEscape(version))</version>",
            "      <kodUtvaru>\(xmlEscape(location.kodUtvaru))</kodUtvaru>",
            "      <kodMistnosti>\(xmlEscape(location.kodMistnosti))</kodMistnosti>",
            "      <nazev>\(xmlEscape(location.nazev))</nazev>",
            "    </navrhPremisteni>",
        ].joined(separator: "\n")
        if let existing = topLevelElement("navrhPremisteni", in: card) {
            return card.replacingCharacters(in: existing.full, with: block)
        }
        guard let close = card.range(of: "</MblInventarizovanaKarta>", options: .backwards) else { return card }
        let insertion = "\n    " + block + "\n  "
        return card.replacingCharacters(in: close, with: insertion + "</MblInventarizovanaKarta>")
    }
}

private struct ElementSlice {
    var full: Range<String.Index>
    var inner: Range<String.Index>?
}

private func topLevelText(_ name: String, in card: String) -> String? {
    guard let element = topLevelElement(name, in: card), let inner = element.inner else { return nil }
    return String(card[inner])
}

private func setTopLevelText(_ name: String, value: String, in card: String) -> String {
    if let element = topLevelElement(name, in: card), let inner = element.inner {
        return card.replacingCharacters(in: inner, with: xmlEscape(value))
    }
    let tag = "<\(name)>\(xmlEscape(value))</\(name)>"
    guard let close = card.range(of: "</MblInventarizovanaKarta>", options: .backwards) else { return card }
    return card.replacingCharacters(in: close, with: "    \(tag)\n  </MblInventarizovanaKarta>")
}

private func removeTopLevel(_ name: String, in card: String) -> String {
    guard let element = topLevelElement(name, in: card) else { return card }
    var start = element.full.lowerBound
    var cursor = start
    while cursor > card.startIndex {
        let previous = card.index(before: cursor)
        let character = card[previous]
        if character == " " || character == "\t" {
            cursor = previous
            continue
        }
        if character == "\n" {
            cursor = previous
            start = cursor
        }
        break
    }
    return card.replacingCharacters(in: start..<element.full.upperBound, with: "")
}

private func topLevelElement(_ name: String, in card: String) -> ElementSlice? {
    topLevelElements(in: card).first { $0.name == name }?.slice
}

private func topLevelElements(in card: String) -> [(name: String, slice: ElementSlice)] {
    var results: [(name: String, slice: ElementSlice)] = []
    var depth = 0
    var pending: [(name: String, start: String.Index, innerStart: String.Index)] = []
    var index = card.startIndex
    while index < card.endIndex {
        guard card[index] == "<" else {
            index = card.index(after: index)
            continue
        }
        guard let tag = readTag(in: card, at: index) else { break }
        if tag.isClose {
            depth -= 1
            if depth == 1, let open = pending.popLast() {
                let inner = open.innerStart..<tag.start
                results.append((open.name, ElementSlice(full: open.start..<tag.end, inner: inner)))
            }
        } else if tag.isSelfClosing {
            if depth == 1 {
                results.append((tag.name, ElementSlice(full: index..<tag.end, inner: nil)))
            }
        } else {
            if depth == 1 {
                pending.append((tag.name, index, tag.end))
            }
            depth += 1
        }
        index = tag.end
    }
    return results
}

private struct TagScan {
    var name: String
    var isClose: Bool
    var isSelfClosing: Bool
    var start: String.Index
    var end: String.Index
}

private func readTag(in text: String, at start: String.Index) -> TagScan? {
    var index = text.index(after: start)
    guard index < text.endIndex else { return nil }
    let isClose = text[index] == "/"
    if isClose { index = text.index(after: index) }
    if index < text.endIndex, text[index] == "!" || text[index] == "?" {
        guard let end = text[index...].firstIndex(of: ">") else { return nil }
        return TagScan(name: "", isClose: false, isSelfClosing: false, start: start, end: text.index(after: end))
    }
    let nameStart = index
    while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "_" || text[index] == "-" || text[index] == ":" {
        index = text.index(after: index)
    }
    let name = String(text[nameStart..<index])
    var quote: Character?
    while index < text.endIndex {
        let character = text[index]
        if let active = quote {
            if character == active { quote = nil }
            index = text.index(after: index)
            continue
        }
        if character == "\"" || character == "'" {
            quote = character
            index = text.index(after: index)
            continue
        }
        if character == ">" {
            let end = text.index(after: index)
            let before = text.index(before: index)
            let selfClosing = !isClose && text[before] == "/"
            return TagScan(name: name, isClose: isClose, isSelfClosing: selfClosing, start: start, end: end)
        }
        index = text.index(after: index)
    }
    return nil
}

func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
