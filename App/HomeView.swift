import KeoCore
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var store: InventoryStore
    @State private var importing = false
    @State private var confirmReplace = false
    @State private var exportDocument: ZipDocument?
    @State private var exportName = "keo4-export.zip"
    @State private var showExporter = false
    @State private var path = NavigationPath()
    @State private var didOpenScreenshot = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.bundle == nil {
                    empty
                } else {
                    loaded
                }
            }
            .navigationTitle("Keo4 inventura")
            .navigationDestination(for: CardListRoute.self) { route in
                CardListView(route: route)
            }
            .navigationDestination(for: ScanRoute.self) { route in
                ScanView(locationID: route.locationID, locationTitle: route.locationTitle)
            }
            .navigationDestination(for: LocationScanRoute.self) { _ in
                LocationScanView()
            }
            .navigationDestination(for: InfoRoute.self) { _ in
                InfoView()
            }
            .navigationDestination(for: ScreenshotDetail.self) { route in
                if let card = store.bundle?.cards.first(where: { $0.id == route.cardID }) {
                    CardDetailView(item: store.presentation(for: card))
                }
            }
            .task { openScreenshot() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result {
                store.importFile(at: url)
            } else if case .failure(let error) = result {
                store.alert = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .zip, defaultFilename: exportName) { result in
            if case .failure(let error) = result {
                store.alert = error.localizedDescription
            }
        }
        .confirmationDialog("Nahradit otevřenou inventuru?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Nahradit", role: .destructive) { importing = true }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Nový soubor nahradí rozpracovanou inventuru v telefonu.")
        }
        .alert("Keo4 inventura", isPresented: alertShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })
    }

    private var empty: some View {
        VStack(spacing: 20) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text("Inventura majetku")
                .font(.title2.bold())
            Text("Načtěte soubor Inventura.zip, který KEO4 vytvořilo pro čtečku.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button {
                importing = true
            } label: {
                Label("Načíst Inventura.zip", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var loaded: some View {
        let progress = store.progress
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.bundle?.package.description ?? "Inventura")
                        .font(.title2.bold())
                    Text(store.filename)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .tint(Color.accentColor)
                    Text("\(progress.done) z \(progress.total)")
                        .font(.headline.monospacedDigit())
                    HStack(spacing: 8) {
                        CountPill(title: "Nalezeno", value: progress.nalezeno, color: .green)
                        CountPill(title: "Přemístění", value: progress.premisteni, color: .orange)
                        CountPill(title: "Zbývá", value: progress.nenalezeno, color: .secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 12) {
                    NavigationLink(value: ScanRoute()) {
                        HomeTile(title: "Inventura", subtitle: "Skenovat kódy", systemImage: "barcode.viewfinder")
                    }
                    .buttonStyle(.plain)
                    NavigationLink(value: CardListRoute(locationID: nil, title: "Umístění")) {
                        HomeTile(title: "Umístění", subtitle: "Místnosti a karty", systemImage: "building.2")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Spacer(minLength: 0)
                    NavigationLink(value: InfoRoute()) {
                        Label("Informace", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Button {
                        confirmReplace = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        prepareExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle("Keo4 inventura")
    }

    private func openScreenshot() {
        guard !didOpenScreenshot, let shot = Screenshot.current else { return }
        didOpenScreenshot = true
        switch shot {
        case .home:
            break
        case .places:
            path.append(CardListRoute(locationID: nil, title: "Umístění"))
        case .room:
            path.append(CardListRoute(locationID: "L3", title: "0003 · Učebna informatiky"))
        case .detail:
            path.append(ScreenshotDetail(cardID: "7"))
        case .scan:
            path.append(ScanRoute())
        }
    }

    private func prepareExport() {
        do {
            let export = try store.makeExport()
            exportName = (export.name as NSString).deletingPathExtension
            exportDocument = ZipDocument(data: export.data)
            showExporter = true
        } catch {
            store.alert = error.localizedDescription
        }
    }
}

struct ZipDocument: FileDocument {
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

struct LocationScanRoute: Hashable {}

struct ScanRoute: Hashable {
    var locationID: String?
    var locationTitle: String?

    init(locationID: String? = nil, locationTitle: String? = nil) {
        self.locationID = locationID
        self.locationTitle = locationTitle
    }
}
struct InfoRoute: Hashable {}

struct CardListRoute: Hashable {
    var locationID: String?
    var title: String
}

private struct HomeTile: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CountPill: View {
    var title: String
    var value: Int
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
