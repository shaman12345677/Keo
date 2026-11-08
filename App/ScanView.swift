import AVFoundation
import KeoCore
import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var store: InventoryStore
    var locationID: String?
    var locationTitle: String?
    @State private var selected: CardPresentation?
    @State private var choices: [CardPresentation] = []
    @State private var lastCode = ""
    @State private var lastAt = Date.distantPast
    @State private var result: ScanHit?
    @State private var torchOn = false
    @State private var useFront = false
    @State private var acceptedAt = Date.distantPast
    @StateObject private var wedge = KeyboardWedge()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    if selected == nil {
                        #if targetEnvironment(simulator)
                        SimulatorScanBackdrop()
                        #else
                        CameraPreview(
                            isRunning: true,
                            position: useFront ? .front : .back,
                            torchOn: torchOn && !useFront
                        ) { code in
                            handle(code)
                        }
                        #endif
                    } else {
                        Color.black
                    }
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

            VStack(alignment: .leading, spacing: 10) {
                if let result {
                    ScanResultCard(hit: result, onDetail: {
                        if let item = result.item { selected = item }
                    }, onUndo: result.canUndo ? {
                        if let id = result.item?.id {
                            store.revert(id)
                            self.result?.canUndo = false
                            self.result?.title = "Vráceno"
                            self.result?.tone = .gray
                        }
                    } : nil)
                }
                if wedge.connected && Screenshot.current == nil {
                    Label("Čtečka připojena", systemImage: "barcode.viewfinder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(locationTitle ?? "Celá inventura")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(progressText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
        .navigationTitle("Rychlá inventura")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            wedge.start()
            if Screenshot.current == .scan {
                handle("1022\nTiskárna\n14.04.2020\nV:2")
            }
        }
        .onDisappear {
            torchOn = false
            wedge.stop()
        }
        .onChange(of: wedge.latest) { _, scan in
            guard let scan else { return }
            handle(scan.text)
        }
        .sheet(item: $selected) { item in
            NavigationStack {
                CardDetailView(item: item)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Vyberte kartu", isPresented: choicesShown, titleVisibility: .visible) {
            ForEach(choices) { item in
                Button("\(item.card.cislo) · \(item.card.nazevMajetku)") {
                    accept(item)
                }
            }
            Button("Zrušit", role: .cancel) {}
        }
    }

    private var progressText: String {
        if let locationID {
            let items = store.presentations(locationID: locationID)
            let done = items.filter { $0.stav == "NALEZENO" || $0.stav == "PREMISTENI" }.count
            return "\(done) / \(items.count)"
        }
        let progress = store.progress
        return "\(progress.nalezeno) / \(progress.total)"
    }

    private var choicesShown: Binding<Bool> {
        Binding(get: { !choices.isEmpty }, set: { if !$0 { choices = [] } })
    }

    private func handle(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, selected == nil, choices.isEmpty else { return }
        if trimmed == lastCode, Date().timeIntervalSince(lastAt) < 2.2 { return }
        let hits = store.match(trimmed)
        if let current = result?.item,
           Date().timeIntervalSince(acceptedAt) < 1.5,
           !hits.contains(where: { $0.id == current.id }) {
            return
        }
        guard !hits.isEmpty else {
            if Date().timeIntervalSince(acceptedAt) < 1.2 { return }
            lastCode = trimmed
            lastAt = Date()
            result = ScanHit(
                title: "Není v inventuře",
                tone: .red,
                cislo: trimmed,
                nazev: "Kód se nepovedlo spárovat s kartou.",
                place: "",
                note: nil,
                item: nil,
                canUndo: false
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        lastCode = trimmed
        lastAt = Date()
        let inRoom = hits.filter { ($0.card.umisteni?.id ?? "") == locationID }
        let pool = (locationID == nil || inRoom.isEmpty) ? hits : inRoom
        if pool.count == 1 {
            accept(pool[0])
        } else {
            choices = pool
        }
    }

    private func accept(_ item: CardPresentation) {
        let elsewhere = locationID != nil && (item.card.umisteni?.id ?? "") != locationID
        let already = item.stav == "NALEZENO" || item.stav == "PREMISTENI"
        if !already {
            store.markFound(item.id)
        }
        let current = store.presentation(for: item.card)
        result = ScanHit(
            title: item.stav == "PREMISTENI" ? "Přemístěno" : (already ? "Už bylo nalezeno" : "Nalezeno"),
            tone: elsewhere ? .orange : .green,
            cislo: current.card.cislo,
            nazev: current.card.nazevMajetku,
            place: current.card.umisteni?.label ?? "Bez umístění",
            note: elsewhere ? "Evidováno v jiném umístění" : nil,
            item: current,
            canUndo: !already
        )
        acceptedAt = Date()
        UINotificationFeedbackGenerator().notificationOccurred(already ? .warning : .success)
    }
}

private struct ScanHit {
    var title: String
    var tone: Color
    var cislo: String
    var nazev: String
    var place: String
    var note: String?
    var item: CardPresentation?
    var canUndo: Bool
}

private struct ScanResultCard: View {
    var hit: ScanHit
    var onDetail: () -> Void
    var onUndo: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(hit.title, systemImage: hit.tone == .red ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(hit.tone)
            Text(hit.cislo)
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(hit.nazev)
                .font(.body)
                .lineLimit(2)
            if !hit.place.isEmpty {
                Text(hit.place)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let note = hit.note {
                Text(note)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            HStack {
                if hit.item != nil {
                    Button("Detail", action: onDetail)
                        .buttonStyle(.bordered)
                }
                if let onUndo {
                    Button("Vrátit", role: .destructive, action: onUndo)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CameraPreview: UIViewControllerRepresentable {
    var isRunning: Bool
    var position: AVCaptureDevice.Position
    var torchOn: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: CameraViewController, context: Context) {
        controller.onCode = onCode
        controller.setPosition(position)
        controller.setRunning(isRunning)
        controller.setTorch(isRunning && torchOn && position == .back)
    }
}

final class CameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let queue = DispatchQueue(label: "cz.samekt.keo.camera")
    private var configured = false
    private var device: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back
    private var wantsTorch = false
    private let readableTypes: Set<AVMetadataObject.ObjectType> = [
        .qr, .code128, .code39, .code93, .ean13, .ean8, .pdf417, .aztec, .dataMatrix, .interleaved2of5, .itf14, .upce, .codabar,
    ]

    deinit {
        let session = session
        let device = device
        queue.async {
            if let device, device.hasTorch {
                try? device.lockForConfiguration()
                device.torchMode = .off
                device.unlockForConfiguration()
            }
            if session.isRunning { session.stopRunning() }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        updateMirroring()
    }

    func setRunning(_ running: Bool) {
        guard running else {
            queue.async { [weak self] in
                guard let self else { return }
                self.wantsTorch = false
                self.applyTorch()
                if self.session.isRunning { self.session.stopRunning() }
            }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard allowed else { return }
                DispatchQueue.main.async { self?.start() }
            }
        default:
            break
        }
    }

    func setTorch(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsTorch = on && self.position == .back
            self.applyTorch()
        }
    }

    func setPosition(_ newPosition: AVCaptureDevice.Position) {
        queue.async { [weak self] in
            guard let self, self.position != newPosition else { return }
            if !self.configured {
                self.position = newPosition
                return
            }
            guard self.swapCamera(to: newPosition) else { return }
            self.position = newPosition
            if newPosition == .front { self.wantsTorch = false }
            self.applyTorch()
            DispatchQueue.main.async { [weak self] in self?.updateMirroring() }
        }
    }

    private func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            guard self.configured else { return }
            if !self.session.isRunning { self.session.startRunning() }
            self.applyTorch()
        }
    }

    private func applyTorch() {
        guard let device, device.hasTorch else { return }
        try? device.lockForConfiguration()
        if wantsTorch, session.isRunning, device.isTorchAvailable {
            try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
    }

    private func configure() {
        guard let (device, input) = makeInput(for: position), session.canAddInput(input) else { return }
        self.device = device
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: queue)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.filter { readableTypes.contains($0) }
        session.commitConfiguration()
        configured = true
    }

    private func swapCamera(to newPosition: AVCaptureDevice.Position) -> Bool {
        guard let (device, input) = makeInput(for: newPosition) else { return false }
        if let current = self.device, current.hasTorch, current.torchMode != .off {
            try? current.lockForConfiguration()
            current.torchMode = .off
            current.unlockForConfiguration()
        }
        session.beginConfiguration()
        let previous = session.inputs
        previous.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            previous.forEach { if session.canAddInput($0) { session.addInput($0) } }
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        self.device = device
        if let output = session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }).first {
            output.metadataObjectTypes = output.availableMetadataObjectTypes.filter { readableTypes.contains($0) }
        }
        session.commitConfiguration()
        return true
    }

    private func makeInput(for position: AVCaptureDevice.Position) -> (AVCaptureDevice, AVCaptureDeviceInput)? {
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        return (device, input)
    }

    private func updateMirroring() {
        guard let connection = preview?.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onCode?(code)
        }
    }
}
