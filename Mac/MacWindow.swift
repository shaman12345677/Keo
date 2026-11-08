import AppKit
import KeoCore
import SwiftUI
import UniformTypeIdentifiers

private enum PlaceFilter: Hashable {
    case all
    case room(String)
}

private struct ScanNotice: Identifiable {
    enum Kind {
        case found
        case already
        case elsewhere
        case missing
        case room
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var cardID: String?
    var canUndo: Bool
}

struct MacWindow: View {
    @EnvironmentObject private var store: InventoryStore
    @EnvironmentObject private var scanner: MacScanner
    @State private var place: PlaceFilter? = .all
    @State private var roomQuery = ""
    @State private var cardQuery = ""
    @FocusState private var cardSearchFocused: Bool
    @State private var listSelection: String?
    @State private var detailID: String?
    @State private var notice: ScanNotice?
    @State private var cardChoices: [CardPresentation] = []
    @State private var roomChoices: [Location] = []
    @State private var pickingPlace = false
    @State private var showOpen = false
    @State private var confirmReplace = false
    @State private var confirmClose = false
    @State private var showExport = false
    @State private var exportDocument: MacZipDocument?
    @State private var exportName = "keo4-export"
    @State private var lastCode = ""
    @State private var lastAt = Date.distantPast
    @State private var acceptedAt = Date.distantPast
    @State private var fragment = ""
    @State private var fragmentAt = Date.distantPast

    var body: some View {
        Group {
            if store.bundle == nil {
                empty
            } else {
                loaded
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .focusedValue(\.inventoryActions, InventoryActions(
            open: requestOpen,
            export: exportInventory,
            canExport: store.bundle != nil
        ))
        .onOpenURL { url in
            store.importFile(at: url)
        }
        .onAppear {
            scanner.installMonitor()
            Task { @MainActor in scanner.installMonitor() }
        }
        .onChange(of: scanner.isScanning) { _, isOn in
            scanner.installMonitor()
            if !isOn {
                scanner.stopScanning()
                fragment = ""
                fragmentAt = Date.distantPast
                notice = nil
            }
        }
        .onChange(of: scanner.latest?.id) { _, _ in
            guard scanner.isScanning, let scan = scanner.latest else { return }
            handleScan(scan.text)
        }
        .fileImporter(isPresented: $showOpen, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result {
                store.importFile(at: url)
            } else if case .failure(let error) = result {
                store.alert = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .zip, defaultFilename: exportName) { result in
            if case .failure(let error) = result {
                store.alert = error.localizedDescription
            }
        }
        .confirmationDialog("Nahradit otevřenou inventuru?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Nahradit", role: .destructive) { showOpen = true }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Nový soubor nahradí rozpracovanou inventuru v tomto Macu.")
        }
        .confirmationDialog("Zavřít inventuru?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Zavřít", role: .destructive) { store.reset() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Soubor v KEO4 to nemění. Smaže se jen kopie v tomto Macu a rozpracované stavy.")
        }
        .confirmationDialog("Vyberte kartu", isPresented: cardChoicesShown, titleVisibility: .visible) {
            ForEach(cardChoices) { item in
                Button("\(item.card.cislo) · \(item.card.nazevMajetku)") { accept(item) }
            }
            Button("Zrušit", role: .cancel) {}
        }
        .confirmationDialog("Vyberte místnost", isPresented: roomChoicesShown, titleVisibility: .visible) {
            ForEach(roomChoices) { room in
                Button(room.label) { openRoom(room) }
            }
            Button("Zrušit", role: .cancel) {}
        }
        .alert("Keo4 inventura", isPresented: alertShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
        .sheet(isPresented: $pickingPlace) {
            PlaceSheet { room in
                if let detailID {
                    store.markMoved(detailID, location: room)
                }
                pickingPlace = false
            }
            .environmentObject(store)
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Inventura majetku")
                .font(.title2.bold())
            Text("Otevřete soubor Inventura.zip, který KEO4 vytvořilo pro čtečku. Skenování jde čtečkou, která se chová jako klávesnice.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Otevřít inventuru…") { requestOpen() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loaded: some View {
        VStack(spacing: 0) {
            progressBar
            if scanner.isScanning {
                HStack(spacing: 8) {
                    Image(systemName: "barcode.viewfinder")
                    Text("Skenování je zapnuté. Čtečka hledá a označuje karty.")
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15))
            }
            if scanner.isScanning, let notice {
                scanBanner(notice)
            }
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 280)
                Divider()
                cardColumn
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Keo4 inventura")
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $scanner.isScanning) {
                    HStack(spacing: 8) {
                        Image(systemName: "barcode.viewfinder")
                            .font(.title2)
                        Text(scanner.isScanning ? "Skenování zapnuto" : "Skenování vypnuto")
                            .font(.title3.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .toggleStyle(.button)
                .controlSize(.extraLarge)
                .keyboardShortcut("k", modifiers: [.command])
                Button("Otevřít…") { requestOpen() }
                Button("Exportovat…") { exportInventory() }
                    .disabled(store.bundle == nil)
                Button("Zavřít inventuru") { confirmClose = true }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Vše")
                    Spacer(minLength: 8)
                    Text("\(store.progress.done)/\(store.progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(showsAllRooms ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : .secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(showsAllRooms ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                .background(alignment: .leading) {
                    progressWash(done: store.progress.done, total: store.progress.total, selected: showsAllRooms)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(showsAllRooms ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                        .padding(.horizontal, 6)
                )
                .contentShape(Rectangle())
                .onTapGesture { place = .all }
                .padding(.top, 8)
                TextField("Místnost", text: $roomQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
            List(selection: $place) {
                Section("Umístění") {
                    ForEach(visibleRooms) { group in
                        let selected = place == .room(group.id)
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.title)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text("\(group.done)/\(group.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : .secondary)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(alignment: .leading) {
                            progressWash(done: group.done, total: group.total, selected: selected)
                        }
                        .tag(PlaceFilter.room(group.id))
                    }
                }
            }
            .onKeyPress(phases: .down) { _ in .handled }
            .scrollClipDisabled(false)
            .keoScrollEdgeHidden()
            VStack(spacing: 2) {
                Text(versionLabel)
                Text("© 2026 Samek Tomáš")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var cardColumn: some View {
        VStack(spacing: 0) {
            TextField("Číslo nebo název", text: $cardQuery)
                .textFieldStyle(.roundedBorder)
                .focused($cardSearchFocused)
                .focusEffectDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
            cardList
        }
    }

    private var cardList: some View {
        List(visibleCards, selection: $listSelection) { item in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.card.cislo)
                        .font(.body.monospacedDigit().weight(.semibold))
                    Spacer()
                    Text(statusTitle(item.stav))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(item.stav))
                }
                Text(item.card.nazevMajetku)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            .tag(item.id)
        }
        .onKeyPress(phases: .down) { _ in .handled }
        .onChange(of: listSelection) { _, id in
            if let id { detailID = id }
        }
        .scrollClipDisabled(false)
        .keoScrollEdgeHidden()
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedCard {
            CardPane(item: item) {
                pickingPlace = true
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Naskenujte štítek nebo vyberte kartu.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var progressBar: some View {
        let progress = store.progress
        return HStack(spacing: 22) {
            progressCount("Předmětů", progress.total, .primary)
            progressCount("Nalezeno", progress.nalezeno, .green)
            progressCount("Přemístěno", progress.premisteni, .orange)
            progressCount("Zbývá", progress.nenalezeno, .secondary)
            Spacer(minLength: 12)
            Text("\(progress.done) z \(progress.total)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func progressWash(done: Int, total: Int, selected: Bool) -> some View {
        let fraction = total == 0 ? 0 : min(1, Double(done) / Double(total))
        let complete = total > 0 && done >= total
        let fill = selected
            ? Color.white.opacity(0.4)
            : Color.green.opacity(complete ? 0.62 : 0.5)
        return GeometryReader { geo in
            fill.frame(width: max(0, geo.size.width * fraction), height: geo.size.height)
        }
        .accessibilityLabel("Hotovo \(done) z \(total)")
    }

    private func progressCount(_ title: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func scanBanner(_ notice: ScanNotice) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: notice.kind == .missing ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(noticeColor(notice.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.headline)
                Text(notice.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if notice.canUndo, let cardID = notice.cardID {
                Button("Vrátit") {
                    store.revert(cardID)
                    self.notice = nil
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(noticeColor(notice.kind).opacity(0.12))
    }

    private var showsAllRooms: Bool {
        place == nil || place == .all
    }

    private var visibleRooms: [LocationGroup] {
        let groups = store.groups
        let query = roomQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { $0.title.localizedStandardContains(query) }
    }

    private var visibleCards: [CardPresentation] {
        let locationID: String?
        switch place ?? .all {
        case .all:
            locationID = nil
        case .room(let id):
            locationID = id
        }
        var items = store.presentations(locationID: locationID)
        let query = cardQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter {
                $0.card.cislo.localizedStandardContains(query) || $0.card.nazevMajetku.localizedCaseInsensitiveContains(query)
            }
        }
        return items
    }

    private var selectedCard: CardPresentation? {
        guard let detailID, let card = store.bundle?.cards.first(where: { $0.id == detailID }) else { return nil }
        return store.presentation(for: card)
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty { return "" }
        if build.isEmpty || build == version { return "Verze \(version)" }
        return "Verze \(version) (\(build))"
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })
    }

    private var cardChoicesShown: Binding<Bool> {
        Binding(get: { !cardChoices.isEmpty }, set: { if !$0 { cardChoices = [] } })
    }

    private var roomChoicesShown: Binding<Bool> {
        Binding(get: { !roomChoices.isEmpty }, set: { if !$0 { roomChoices = [] } })
    }

    private func requestOpen() {
        if store.bundle == nil {
            showOpen = true
        } else {
            confirmReplace = true
        }
    }

    private func exportInventory() {
        do {
            let export = try store.makeExport()
            exportName = (export.name as NSString).deletingPathExtension
            exportDocument = MacZipDocument(data: export.data)
            showExport = true
        } catch {
            store.alert = error.localizedDescription
        }
    }

    private func handleScan(_ raw: String) {
        let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty, normalizeCode(piece) != "v:2", cardChoices.isEmpty, roomChoices.isEmpty else { return }
        let trimmed = joinedFragment(piece)
        if trimmed == lastCode, Date().timeIntervalSince(lastAt) < 2.2 { return }
        if !looksLikeAsset(trimmed) {
            let rooms = exactRooms(trimmed)
            if rooms.count == 1 {
                lastCode = trimmed
                lastAt = Date()
                openRoom(rooms[0])
                return
            }
            if rooms.count > 1 {
                lastCode = trimmed
                lastAt = Date()
                roomChoices = rooms
                notice = ScanNotice(kind: .room, title: "Víc místností", detail: "Vyberte, kterou štítek označuje.", cardID: nil, canUndo: false)
                return
            }
        }
        let hits = store.match(trimmed)
        if let current = selectedCard,
           Date().timeIntervalSince(acceptedAt) < 2.5,
           !hits.contains(where: { $0.id == current.id }) {
            return
        }
        guard !hits.isEmpty else {
            if Date().timeIntervalSince(acceptedAt) < 2.5 { return }
            lastCode = trimmed
            lastAt = Date()
            notice = ScanNotice(kind: .missing, title: "Není v inventuře", detail: trimmed, cardID: nil, canUndo: false)
            return
        }
        lastCode = trimmed
        lastAt = Date()
        let currentRoom = currentRoomID
        let inRoom = hits.filter { ($0.card.umisteni?.id ?? "") == currentRoom }
        let pool = (currentRoom == nil || inRoom.isEmpty) ? hits : inRoom
        if pool.count == 1 {
            accept(pool[0])
        } else {
            cardChoices = pool
        }
    }

    /// Konec štítku (datum a V:2) někdy dorazí jako další dávka. Přilepí se k číslu, které už přišlo.
    private func joinedFragment(_ piece: String) -> String {
        let recent = Date().timeIntervalSince(fragmentAt) < 2 && !fragment.isEmpty
        let joined = (recent && looksLikeContinuation(piece)) ? fragment + "\n" + piece : piece
        fragment = joined
        fragmentAt = Date()
        return joined
    }

    private func looksLikeContinuation(_ piece: String) -> Bool {
        let firstLine = piece.split(whereSeparator: \.isNewline).first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? piece
        guard !firstLine.isEmpty else { return true }
        if firstLine.range(of: #"^\d{1,2}\.\d{1,2}\.\d{4}"#, options: .regularExpression) != nil { return true }
        let token = normalizeCode(firstLine)
        if token == "v:2" || token.hasSuffix("v:2") { return true }
        if firstLine.range(of: #"\d{2}\.\d{2}\.\d{4}"#, options: .regularExpression) != nil { return true }
        return false
    }

    private func accept(_ item: CardPresentation) {
        let currentRoom = currentRoomID
        let elsewhere = currentRoom != nil && (item.card.umisteni?.id ?? "") != currentRoom
        let already = item.stav == "NALEZENO"
        if !already {
            store.markFound(item.id)
        }
        NSSound(named: already ? "Pop" : "Glass")?.play()
        let current = store.presentation(for: item.card)
        detailID = current.id
        listSelection = current.id
        let kind: ScanNotice.Kind = elsewhere ? .elsewhere : (already ? .already : .found)
        let title = elsewhere ? "Evidováno jinde" : (already ? "Už bylo nalezeno" : "Nalezeno")
        let place = current.card.umisteni?.label ?? "Bez umístění"
        notice = ScanNotice(
            kind: kind,
            title: title,
            detail: "\(current.card.cislo) · \(current.card.nazevMajetku) · \(place)",
            cardID: current.id,
            canUndo: !already
        )
        acceptedAt = Date()
    }

    private func openRoom(_ room: Location) {
        place = .room(room.id)
        roomChoices = []
        notice = ScanNotice(kind: .room, title: "Místnost", detail: room.label, cardID: nil, canUndo: false)
    }

    private var currentRoomID: String? {
        if case .room(let id) = place { return id }
        return nil
    }

    private func exactRooms(_ raw: String) -> [Location] {
        let whole = normalizeCode(raw)
        guard !whole.isEmpty, whole != "v:2" else { return [] }
        return store.matchLocations(raw).filter { room in
            let keys = [
                room.id,
                room.kodUtvaru,
                room.kodMistnosti,
                room.nazev,
                "\(room.kodUtvaru)/\(room.kodMistnosti)",
                room.kodUtvaru + room.kodMistnosti,
            ].map(normalizeCode)
            return keys.contains(whole)
        }
    }

    private func looksLikeAsset(_ raw: String) -> Bool {
        raw.contains("\n") || raw.contains("\r") || raw.lowercased().contains("v:2")
    }

    private func noticeColor(_ kind: ScanNotice.Kind) -> Color {
        switch kind {
        case .found, .room: return .green
        case .already, .elsewhere: return .orange
        case .missing: return .red
        }
    }
}

private struct CardPane: View {
    @EnvironmentObject private var store: InventoryStore
    var item: CardPresentation
    var onMove: () -> Void

    private var current: CardPresentation {
        store.presentation(for: item.card)
    }

    var body: some View {
        let item = current
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.card.cislo)
                        .font(.largeTitle.monospacedDigit().weight(.semibold))
                    Text(item.card.nazevMajetku)
                        .font(.title3)
                    Text(statusTitle(item.stav))
                        .font(.headline)
                        .foregroundStyle(statusColor(item.stav))
                }
                HStack(spacing: 8) {
                    statusButton("Nalezeno", selected: item.stav == "NALEZENO") {
                        store.markFound(item.id)
                    }
                    statusButton("Přemístit", selected: item.stav == "PREMISTENI", action: onMove)
                    statusButton("Nenalezeno", selected: item.stav == "NENALEZENO") {
                        store.markMissing(item.id)
                    }
                    if item.changed {
                        Button("Vrátit ze souboru") { store.revert(item.id) }
                            .buttonStyle(.bordered)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    fact("Umístění", item.card.umisteni?.label ?? "Bez umístění")
                    if let navrh = item.navrh {
                        fact("Návrh přemístění", navrh.label)
                    }
                    fact("Zařazeno", Format.date(item.card.datumZarazeni))
                    fact("Typ", item.card.typMajetku)
                    if !item.card.podtypMajetku.isEmpty {
                        fact("Podtyp", item.card.podtypMajetku)
                    }
                    fact("Pořizovací cena", Format.money(item.card.porizCenaUcetni))
                    fact("Zůstatková cena", Format.money(item.card.zustatkovaHodnota))
                    if let years = item.card.zivotnost, !years.isEmpty {
                        fact("Životnost", years)
                    }
                    fact("Organizace", item.card.organizace)
                    fact("Sejmuto", item.oskenovano ? "Ano" : "Ne")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled(false)
        .keoScrollEdgeHidden()
    }

    private func statusButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(selected ? Color.accentColor : Color.secondary.opacity(0.35))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
        }
    }
}

private struct PlaceSheet: View {
    @EnvironmentObject private var store: InventoryStore
    @Environment(\.dismiss) private var dismiss
    var onPick: (Location) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Přemístit do")
                .font(.title2.bold())
            TextField("Útvar nebo místnost", text: $query)
                .textFieldStyle(.roundedBorder)
            List(places) { room in
                Button {
                    onPick(room)
                } label: {
                    Text(room.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Zrušit") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 480)
    }

    private var places: [Location] {
        let all = (store.bundle?.locations ?? []).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.label.localizedStandardContains(needle) }
    }
}

private struct MacZipDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension View {
    @ViewBuilder
    func keoScrollEdgeHidden() -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

private func statusColor(_ stav: String) -> Color {
    switch stav {
    case "NALEZENO": return .green
    case "PREMISTENI": return .orange
    default: return Color.secondary
    }
}
