import KeoCore
import SwiftUI
import UIKit

struct CardDetailView: View {
    @EnvironmentObject private var store: InventoryStore
    @Environment(\.dismiss) private var dismiss
    var item: CardPresentation
    @State private var pickingPlace = false
    @State private var showCamera = false
    @State private var capturedData: Data?
    @State private var previewPhoto: SessionPhoto?

    private var current: CardPresentation {
        store.presentation(for: item.card)
    }

    var body: some View {
        let item = current
        let cardPhotos = store.photos(forCardID: item.id)
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.card.cislo)
                            .font(.title.monospacedDigit().weight(.semibold))
                        Text(item.card.nazevMajetku)
                            .font(.title3)
                        Text(statusTitle(item.stav))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusColor(item.stav))
                    }
                    HStack(spacing: 8) {
                        CardAction(title: "Nalezeno", systemImage: "checkmark.circle.fill", selected: item.stav == "NALEZENO") {
                            store.markFound(item.id)
                        }
                        CardAction(title: "Přemístit", systemImage: "arrow.left.arrow.right", selected: item.stav == "PREMISTENI") {
                            pickingPlace = true
                        }
                        CardAction(title: "Nenalezeno", systemImage: "circle", selected: item.stav == "NENALEZENO") {
                            store.markMissing(item.id)
                        }
                        if item.changed {
                            CardAction(title: "Vrátit", caption: "ze souboru", systemImage: "arrow.uturn.backward", selected: false, destructive: true) {
                                store.revert(item.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Fotografie") {
                if cardPhotos.isEmpty {
                    Text("Zatím bez fotografie")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cardPhotos) { photo in
                                if let data = store.photoData(for: photo), let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .onTapGesture { previewPhoto = photo }
                                        .contextMenu {
                                            Button("Smazat", role: .destructive) {
                                                store.removePhoto(photo)
                                            }
                                        }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                Button {
                    showCamera = true
                } label: {
                    Label("Vyfotit", systemImage: "camera.fill")
                }
            }
            Section("Evidence") {
                labeled("Umístění", item.card.umisteni?.label ?? "Bez umístění")
                if let navrh = item.navrh {
                    labeled("Návrh přemístění", navrh.label)
                }
                labeled("Zařazeno", Format.date(item.card.datumZarazeni))
                labeled("Typ", item.card.typMajetku)
                if !item.card.podtypMajetku.isEmpty {
                    labeled("Podtyp", item.card.podtypMajetku)
                }
                labeled("Pořizovací cena", Format.money(item.card.porizCenaUcetni))
                labeled("Zůstatková cena", Format.money(item.card.zustatkovaHodnota))
                if let years = item.card.zivotnost, !years.isEmpty {
                    labeled("Životnost", years)
                }
                labeled("Organizace", item.card.organizace)
                labeled("Sejmuto", item.oskenovano ? "Ano" : "Ne")
            }
        }
        .navigationTitle("Karta")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Hotovo") { dismiss() }
            }
        }
        .sheet(isPresented: $pickingPlace) {
            NavigationStack {
                PlacePicker { place in
                    store.markMoved(item.id, location: place)
                    pickingPlace = false
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(imageData: $capturedData)
                .ignoresSafeArea()
        }
        .onChange(of: capturedData) { _, data in
            guard let data else { return }
            store.addPhoto(cardID: item.id, imageData: data)
            capturedData = nil
        }
        .sheet(item: $previewPhoto) { photo in
            if let data = store.photoData(for: photo), let image = UIImage(data: data) {
                NavigationStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                        .navigationTitle("Fotografie")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Zavřít") { previewPhoto = nil }
                            }
                            ToolbarItem(placement: .destructiveAction) {
                                Button("Smazat", role: .destructive) {
                                    store.removePhoto(photo)
                                    previewPhoto = nil
                                }
                            }
                        }
                }
            }
        }
    }

    private struct CardAction: View {
        var title: String
        var caption: String? = nil
        var systemImage: String
        var selected: Bool
        var destructive: Bool = false
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.title3)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let caption {
                        Text(caption)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: caption == nil ? 64 : 72)
                .padding(.vertical, 6)
                .foregroundStyle(destructive ? Color.red : (selected ? Color.accentColor : Color.primary))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(selected ? Color.accentColor.opacity(0.16) : Color(.secondarySystemFill))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
        }
    }
}

private struct PlacePicker: View {
    @EnvironmentObject private var store: InventoryStore
    @Environment(\.dismiss) private var dismiss
    var onPick: (Location) -> Void
    @State private var query = ""

    var body: some View {
        InventorySearchContainer(query: $query, prompt: "Útvar nebo místnost") {
            placeList
        }
    }

    private var placeList: some View {
        List(places) { place in
            Button {
                onPick(place)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.label)
                        .foregroundStyle(.primary)
                    if !place.kodUtvaru.isEmpty {
                        Text(place.kodUtvaru)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Nové umístění")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Zavřít") { dismiss() }
            }
        }
    }

    private var places: [Location] {
        let all = (store.bundle?.locations ?? []).sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.label.localizedStandardContains(needle) || $0.kodUtvaru.localizedStandardContains(needle)
        }
    }
}
