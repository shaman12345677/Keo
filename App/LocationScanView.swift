import KeoCore
import SwiftUI

struct LocationScanView: View {
    @EnvironmentObject private var store: InventoryStore
    @State private var room: CardListRoute?
    @State private var choices: [Location] = []
    @State private var message = "Namiřte na štítek místnosti"
    @State private var missed = false
    @State private var torchOn = false
    @State private var useFront = false
    @State private var lastCode = ""
    @State private var lastAt = Date.distantPast
    @StateObject private var wedge = KeyboardWedge()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreview(
                    isRunning: room == nil,
                    position: useFront ? .front : .back,
                    torchOn: torchOn && !useFront
                ) { code in
                    handle(code)
                }
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 220, height: 220)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                Button {
                    useFront.toggle()
                    if useFront { torchOn = false }
                } label: {
                    Image(systemName: "camera.rotate")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(useFront ? "Přepnout na zadní kameru" : "Přepnout na přední kameru")
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if !useFront {
                    Button {
                        torchOn.toggle()
                    } label: {
                        Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title2)
                            .foregroundStyle(torchOn ? .yellow : .white)
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .accessibilityLabel(torchOn ? "Vypnout svítilnu" : "Zapnout svítilnu")
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.headline)
                    .foregroundStyle(missed ? .red : .primary)
                if wedge.connected {
                    Label("Čtečka připojena", systemImage: "barcode.viewfinder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
        .navigationTitle("Kód umístění")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $room) { route in
            CardListView(route: route)
        }
        .onAppear { wedge.start() }
        .onDisappear {
            torchOn = false
            wedge.stop()
        }
        .onChange(of: wedge.latest) { _, scan in
            guard let scan else { return }
            handle(scan.text)
        }
        .confirmationDialog("Vyberte místnost", isPresented: choicesShown, titleVisibility: .visible) {
            ForEach(choices) { place in
                Button(place.label) { open(place) }
            }
            Button("Zrušit", role: .cancel) {}
        }
    }

    private var choicesShown: Binding<Bool> {
        Binding(get: { !choices.isEmpty }, set: { if !$0 { choices = [] } })
    }

    private func handle(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, room == nil, choices.isEmpty else { return }
        if trimmed == lastCode, Date().timeIntervalSince(lastAt) < 2.2 { return }
        lastCode = trimmed
        lastAt = Date()
        let hits = store.matchLocations(trimmed)
        guard !hits.isEmpty else {
            missed = true
            message = "Místnost není v inventuře"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        if hits.count == 1 {
            open(hits[0])
        } else {
            missed = false
            message = "Víc místností se stejným kódem"
            choices = hits
        }
    }

    private func open(_ place: Location) {
        missed = false
        message = place.label
        choices = []
        room = CardListRoute(locationID: place.id, title: place.label)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
