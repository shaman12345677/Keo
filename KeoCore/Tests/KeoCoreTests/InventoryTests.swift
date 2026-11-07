import XCTest
@testable import KeoCore

final class InventoryTests: XCTestCase {
    func testZipRoundTripAndReference() throws {
        let xml = """
        <list>
          <MblInventarizovanaKarta>
            <id>1</id>
            <version>0</version>
            <inventarniCislo>  10-A</inventarniCislo>
            <nazevMajetku>Stůl</nazevMajetku>
            <typMajetku>028</typMajetku>
            <podtypMajetku></podtypMajetku>
            <porizCenaUcetni>10.00</porizCenaUcetni>
            <ucetniOpravky>0.00</ucetniOpravky>
            <zustatkovaHodnota>10.00</zustatkovaHodnota>
            <datumZarazeni class="sql-date">2020-05-01</datumZarazeni>
            <umisteni>
              <id>L1</id>
              <version>2</version>
              <kodUtvaru>A</kodUtvaru>
              <kodMistnosti></kodMistnosti>
              <nazev>Dílna &amp; sklad</nazev>
            </umisteni>
            <vyrazZustCena>0.00</vyrazZustCena>
            <organizace>Škola</organizace>
            <stavInventarizace>NENALEZENO</stavInventarizace>
            <vyrizeno>false</vyrizeno>
            <premisteniSchvaleno>false</premisteniSchvaleno>
            <oskenovano>false</oskenovano>
            <inventura>
              <id>9</id>
              <version>0</version>
              <nazev>Inventura</nazev>
            </inventura>
          </MblInventarizovanaKarta>
          <MblInventarizovanaKarta>
            <id>2</id>
            <version>0</version>
            <inventarniCislo>11-A</inventarniCislo>
            <nazevMajetku>Židle</nazevMajetku>
            <typMajetku>028</typMajetku>
            <podtypMajetku></podtypMajetku>
            <porizCenaUcetni>5.00</porizCenaUcetni>
            <ucetniOpravky>0.00</ucetniOpravky>
            <zustatkovaHodnota>5.00</zustatkovaHodnota>
            <datumZarazeni class="sql-date">2020-05-01</datumZarazeni>
            <umisteni reference="../../MblInventarizovanaKarta/umisteni"/>
            <vyrazZustCena>0.00</vyrazZustCena>
            <organizace>Škola</organizace>
            <stavInventarizace>NENALEZENO</stavInventarizace>
            <vyrizeno>false</vyrizeno>
            <premisteniSchvaleno>false</premisteniSchvaleno>
            <oskenovano>false</oskenovano>
            <inventura reference="../../MblInventarizovanaKarta/inventura"/>
          </MblInventarizovanaKarta>
        </list>
        """
        let locations = """
        <list>
          <MblUtvaryMistnosti>
            <id>L1</id>
            <version>2</version>
            <kodUtvaru>A</kodUtvaru>
            <kodMistnosti></kodMistnosti>
            <nazev>Dílna &amp; sklad</nazev>
          </MblUtvaryMistnosti>
          <MblUtvaryMistnosti>
            <id>L2</id>
            <version>0</version>
            <kodUtvaru>B</kodUtvaru>
            <kodMistnosti>3</kodMistnosti>
            <nazev>Sborovna</nazev>
          </MblUtvaryMistnosti>
        </list>
        """
        let info = """
        <package-info>
          <packageId>ekomaj_majetek.db</packageId>
          <databaseVersion>21</databaseVersion>
          <description>Inventura</description>
          <date>2020-05-01 08:00:00</date>
          <schema>skola</schema>
        </package-info>
        """
        let zip = try ZipArchive.write(entries: [
            ZipEntry(name: "info/package-info.xml", data: Data(info.utf8)),
            ZipEntry(name: "InventarizovaneKarty.xml", data: Data(xml.utf8)),
            ZipEntry(name: "UtvaryMistnosti.xml", data: Data(locations.utf8)),
            ZipEntry(name: "ZjisteneInventarizovaneKarty.xml", data: Data("<list/>".utf8)),
        ])
        let bundle = try InventoryBundle.load(data: zip, filename: "Inventura.zip")
        XCTAssertEqual(bundle.cards.count, 2)
        XCTAssertEqual(bundle.cards[0].cislo, "10-A")
        XCTAssertEqual(bundle.cards[0].inventarniCislo, "  10-A")
        XCTAssertEqual(bundle.cards[0].datumZarazeni, "2020-05-01")
        XCTAssertEqual(bundle.cards[1].umisteni?.nazev, "Dílna & sklad")
        XCTAssertEqual(bundle.cards[1].inventuraNazev, "Inventura")
        XCTAssertEqual(bundle.package.databaseVersion, "21")
        XCTAssertEqual(bundle.locations.count, 2)

        let index = CodeIndex(cards: bundle.cards)
        XCTAssertEqual(index.match("10-A").map(\.id), ["1"])
        XCTAssertEqual(index.match("10-A|Stůl|2020-05-01|V:2").map(\.id), ["1"])
        XCTAssertEqual(index.match("10-A Stůl 2020-05-01 V:2").map(\.id), ["1"])
        XCTAssertEqual(index.match("V:2").map(\.id), [])
        XCTAssertEqual(index.match("10-AStůl2020").map(\.id), ["1"])
        XCTAssertEqual(index.match("110-A").map(\.id), [])

        let moved = CardChange.premisteni(locationID: "L2")
        let exported = try bundle.exportZip(changes: ["1": .nalezeno(), "2": moved])
        let again = try InventoryBundle.load(data: exported, filename: "export.zip")
        XCTAssertEqual(again.cards[0].stavInventarizace, "NALEZENO")
        XCTAssertTrue(again.cards[0].oskenovano)
        XCTAssertNil(again.cards[0].navrh)
        XCTAssertEqual(again.cards[0].datumZarazeni, "2020-05-01")
        XCTAssertEqual(again.cards[0].inventarniCislo, "  10-A")
        XCTAssertEqual(again.cards[1].stavInventarizace, "PREMISTENI")
        XCTAssertEqual(again.cards[1].navrh?.id, "L2")
        XCTAssertEqual(again.cards[1].navrh?.nazev, "Sborovna")
        XCTAssertEqual(again.cards[1].umisteni?.nazev, "Dílna & sklad")

        let raw = String(data: again.entries.first { $0.name == "InventarizovaneKarty.xml" }!.data, encoding: .utf8)!
        XCTAssertTrue(raw.contains("class=\"sql-date\""))
        XCTAssertEqual(raw.components(separatedBy: "<navrhPremisteni>").count - 1, 1)
        XCTAssertTrue(cardSlice(id: "2", in: raw).contains("<stavInventarizace>PREMISTENI</stavInventarizace>"))
        XCTAssertTrue(cardSlice(id: "1", in: raw).contains("class=\"sql-date\">2020-05-01</datumZarazeni>"))
    }

    func testGluedScannerTextUsesLongestInventoryNumber() {
        func card(_ id: String, _ number: String) -> AssetCard {
            var card = AssetCard.empty
            card.id = id
            card.inventarniCislo = number
            return card
        }
        let index = CodeIndex(cards: [
            card("short", "1550"),
            card("full", "1550-POD"),
            card("inside", "59-DKP"),
            card("item", "998"),
            card("year", "2022"),
            card("pod", "998-POD"),
            card("late", "1016-POD"),
            card("tv", "1016"),
            card("board", "55"),
        ])
        XCTAssertEqual(index.match("1550-\nPODV4317543170k01.01.2019V:\n2").map(\.id), ["full"])
        XCTAssertEqual(index.match("998název01.01.2022V:2").map(\.id), ["item"])
        XCTAssertEqual(index.match("998název\n2022\nV:2").map(\.id), ["item"])
        XCTAssertEqual(index.match("998-PODnázev01.01.2022V:2").map(\.id), ["pod"])
        let television = """
                   1016
        Televize LG 55 NANO826Q
        30.11.2023
        V:2
        """
        XCTAssertEqual(index.match(television).map(\.id), ["tv"])
        XCTAssertEqual(index.match("1016Televize LG 55 NANO826Q").map(\.id), ["tv"])
        XCTAssertEqual(index.match("55").map(\.id), ["board"])
        let onlySuffix = CodeIndex(cards: [card("late", "1016-POD"), card("board", "55")])
        XCTAssertEqual(onlySuffix.match(television).map(\.id), ["late"])
        XCTAssertEqual(onlySuffix.match("1016Televize LG 55 NANO826Q30.11.2023V:2").map(\.id), ["late"])
        XCTAssertEqual(index.match("159-DKP").map(\.id), [])
        XCTAssertEqual(index.match("59-DKP").map(\.id), ["inside"])
    }

    func testRoomLabelOpensMatchingLocation() {
        let rooms = [
            Location(id: "1", version: "0", kodUtvaru: "0001", kodMistnosti: "", nazev: "školní jídelna"),
            Location(id: "4", version: "0", kodUtvaru: "0004", kodMistnosti: "", nazev: "Učebna Přír.+Zeměpis místnost č.10"),
            Location(id: "19", version: "0", kodUtvaru: "0014", kodMistnosti: "0019", nazev: "Učebna AJ místnost č.16"),
            Location(id: "14", version: "0", kodUtvaru: "0014", kodMistnosti: "0014", nazev: "třídy"),
        ]
        let index = LocationIndex(locations: rooms)
        XCTAssertEqual(index.match("0004").map(\.id), ["4"])
        XCTAssertEqual(index.match("4").map(\.id), ["4"])
        XCTAssertEqual(index.match("0004\nUčebna Přír.+Zeměpis místnost č.10").map(\.id), ["4"])
        XCTAssertEqual(index.match("0004Učebna Přír.+Zeměpis").map(\.id), ["4"])
        XCTAssertEqual(index.match("0014").map(\.id), ["14", "19"])
        XCTAssertEqual(index.match("0014/0019").map(\.id), ["19"])
        XCTAssertEqual(index.match("00140019Učebna AJ").map(\.id), ["19"])
        XCTAssertEqual(index.match("19").map(\.id), ["19"])
        XCTAssertEqual(index.match("školní jídelna").map(\.id), ["1"])
        XCTAssertEqual(index.match("1038Televize LG 55 NANO826Q30.11.2023V:2").map(\.id), [])
        XCTAssertEqual(index.match("V:2").map(\.id), [])
    }

    func testSampleInventoryKeepsOriginalDates() throws {
        let candidates = [
            "/tmp/keo4/in.zip",
            "/Users/samekt/Library/CloudStorage/OneDrive-Osobní/skola/Inventura 2025 B2.zip",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("Vzorový Inventura.zip není stažený.")
        }
        let bundle = try InventoryBundle.load(data: data, filename: "Inventura 2025 B2.zip")
        XCTAssertEqual(bundle.cards.count, 1119)
        XCTAssertEqual(bundle.locations.count, 157)
        let card = try XCTUnwrap(bundle.cards.first { $0.cislo == "59-DKP" })
        XCTAssertEqual(card.nazevMajetku, "Mikroskop Busch")
        XCTAssertEqual(card.stavInventarizace, "NENALEZENO")
        XCTAssertTrue(card.inventarniCislo.hasPrefix(" "))
        XCTAssertEqual(card.datumZarazeni, "2019-01-01")

        let untouchedID = bundle.cards[1].id
        let originalXML = String(data: bundle.entries.first { ($0.name as NSString).lastPathComponent == "InventarizovaneKarty.xml" }!.data, encoding: .utf8)!
        let exported = try bundle.exportZip(changes: [card.id: .nalezeno()])
        let raw = String(data: try ZipArchive.read(data: exported).first { ($0.name as NSString).lastPathComponent == "InventarizovaneKarty.xml" }!.data, encoding: .utf8)!
        XCTAssertEqual(cardSlice(id: untouchedID, in: raw), cardSlice(id: untouchedID, in: originalXML))
        let patched = cardSlice(id: card.id, in: raw)
        XCTAssertTrue(patched.contains("class=\"sql-date\">2019-01-01</datumZarazeni>"))
        XCTAssertTrue(patched.contains("<stavInventarizace>NALEZENO</stavInventarizace>"))
        XCTAssertTrue(patched.contains("<oskenovano>true</oskenovano>"))
        XCTAssertTrue(patched.contains("<inventarniCislo>\(card.inventarniCislo)</inventarniCislo>"))
    }

    private func cardSlice(id: String, in xml: String) -> String {
        var search = xml.startIndex
        while let open = xml.range(of: "<MblInventarizovanaKarta", range: search..<xml.endIndex),
              let close = xml.range(of: "</MblInventarizovanaKarta>", range: open.lowerBound..<xml.endIndex) {
            let slice = String(xml[open.lowerBound..<close.upperBound])
            if slice.contains("<id>\(id)</id>") { return slice }
            search = close.upperBound
        }
        return ""
    }
}
