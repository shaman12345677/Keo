import KeoCore
import SwiftUI

struct CardListView: View {
    @EnvironmentObject private var store: InventoryStore
    var route: CardListRoute
    @State private var query = ""
    @State private var filter: StatusFilter = .all

    var body: some View {
        let items = filtered
        let browsingPlaces = route.locationID == nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        InventorySearchContainer(query: $query, prompt: "Číslo nebo název") {
            list(items: items, browsingPlaces: browsingPlaces)
        }
    }

    private func list(items: [CardPresentation], browsingPlaces: Bool) -> some View {
        List {
            if browsingPlaces {
                Section("Umístění") {
                    ForEach(store.groups) { group in
                        NavigationLink(value: CardListRoute(locationID: group.id, title: group.title)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                    Text("\(group.done) / \(group.total)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ProgressView(value: Double(group.done), total: Double(max(group.total, 1)))
                                    .frame(width: 72)
                            }
                        }
                    }
                }
            } else {
                Section(items.isEmpty ? "Nic tu není" : "Karty") {
                    ForEach(items) { item in
                        NavigationLink {
                            CardDetailView(item: item)
                        } label: {
                            CardRow(item: item)
                        }
                    }
                }
            }
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if route.locationID == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: LocationScanRoute()) {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel("Načíst kód umístění")
                }
            }
            if route.locationID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: ScanRoute(locationID: route.locationID, locationTitle: route.title)) {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel("Rychlá inventura")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filtr", selection: $filter) {
                        ForEach(StatusFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private var filtered: [CardPresentation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.presentations(locationID: route.locationID).filter { item in
            if !filter.matches(item.stav) { return false }
            guard !needle.isEmpty else { return true }
            return item.card.cislo.localizedStandardContains(needle)
                || item.card.nazevMajetku.localizedStandardContains(needle)
        }
    }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case remaining
    case found
    case moved
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remaining: return "Zbývá"
        case .found: return "Nalezeno"
        case .moved: return "Přemístění"
        case .all: return "Vše"
        }
    }

    func matches(_ stav: String) -> Bool {
        switch self {
        case .remaining: return stav == "NENALEZENO"
        case .found: return stav == "NALEZENO"
        case .moved: return stav == "PREMISTENI"
        case .all: return true
        }
    }
}

struct CardRow: View {
    var item: CardPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor(item.stav))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.card.cislo)
                    .font(.headline.monospacedDigit())
                Text(item.card.nazevMajetku)
                    .foregroundStyle(.primary)
                if let place = item.card.umisteni?.label {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(statusTitle(item.stav))
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor(item.stav))
        }
        .padding(.vertical, 2)
    }
}

struct InfoView: View {
    @EnvironmentObject private var store: InventoryStore
    @State private var confirmReset = false

    var body: some View {
        List {
            if let package = store.bundle?.package {
                Section("Soubor") {
                    LabeledContent("Název", value: package.description.isEmpty ? "—" : package.description)
                    LabeledContent("Vytvořeno", value: Format.packageDate(package.date))
                    LabeledContent("Schéma", value: package.schema.isEmpty ? "—" : package.schema)
                    LabeledContent("Verze dat", value: package.databaseVersion.isEmpty ? "—" : package.databaseVersion)
                    LabeledContent("Karet", value: "\(store.bundle?.cards.count ?? 0)")
                    LabeledContent("Umístění", value: "\(store.bundle?.locations.count ?? 0)")
                    LabeledContent("Upraveno v telefonu", value: "\(store.changes.count)")
                }
            }
            Section {
                Text("Export uložte a v KEO4 ho načtěte přes Elektronické inventury, Akce, Nahrát soubor ze čtečky. Datum zařazení a ostatní údaje karty zůstávají tak, jak je vyexportovalo KEO4.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                VStack(spacing: 0) {
                    Text(appVersionLabel)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Color(.separator)
                        .frame(height: 1 / UIScreen.main.scale)
                        .frame(maxWidth: .infinity)
                    Text("© 2026 Samek Tomáš")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            Section {
                Button("Smazat inventuru z telefonu", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle("Informace")
        .confirmationDialog("Smazat načtenou inventuru?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Smazat", role: .destructive) { store.reset() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Soubor v KEO4 to nemění. Smaže se jen kopie v telefonu a rozpracované stavy.")
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty { return build.isEmpty ? "" : "Verze \(build)" }
        if build.isEmpty || build == version { return "Verze \(version)" }
        return "Verze \(version) (\(build))"
    }
}

func statusColor(_ stav: String) -> Color {
    switch stav {
    case "NALEZENO": return .green
    case "PREMISTENI": return .orange
    default: return Color(.tertiaryLabel)
    }
}
