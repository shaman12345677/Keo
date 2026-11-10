import AppKit

/// Continuity Camera „Vyfotit na iPhonu“.
/// Primárně spouští vestavěný ContinuityHelper (vlastní NSApp + File menu) —
/// ve SwiftUI appce samotné Continuity submenu spolehlivě nepřipojí.
enum ContinuityCameraSupport {
    static func registerServices() {
        let returnTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
            + [NSPasteboard.PasteboardType("com.adobe.pdf")]
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)
    }

    @discardableResult
    static func installMenuItemIfNeeded() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        if findImportItem(in: mainMenu) != nil { return findImportItem(in: mainMenu) }

        let item = NSMenuItem(title: "Importovat z iPhonu nebo iPadu", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        if let fileMenu = mainMenu.item(withTitle: "File")?.submenu
            ?? mainMenu.item(withTitle: "Soubor")?.submenu {
            fileMenu.addItem(NSMenuItem.separator())
            fileMenu.addItem(item)
            return item
        }
        let fileTop = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item)
        fileTop.submenu = fileMenu
        mainMenu.insertItem(fileTop, at: min(1, mainMenu.items.count))
        return item
    }

    static func findImportItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.identifier == NSMenuItem.importFromDeviceIdentifier { return item }
            if let found = findImportItem(in: item.submenu) { return found }
        }
        return nil
    }

    static func helperURL() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "ContinuityHelper") {
            return url
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ContinuityHelper")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }
}

// MARK: - Capture session (helper process)

final class ContinuityTakePhotoSession {
    private let onImage: (Data) -> Void
    private let onStatus: (String) -> Void
    private let onFailed: (String) -> Void

    private var process: Process?
    private var pollTimer: Timer?
    private var finished = false
    private var outDir: URL?
    private var startedAt = Date()

    init(
        onStatus: @escaping (String) -> Void,
        onImage: @escaping (Data) -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        self.onStatus = onStatus
        self.onImage = onImage
        self.onFailed = onFailed
    }

    func start() {
        ContinuityCameraSupport.registerServices()
        ContinuityCameraSupport.installMenuItemIfNeeded()

        guard let helper = ContinuityCameraSupport.helperURL() else {
            onFailed("ContinuityHelper chybí v aplikaci. Znovu sestav Mac target.")
            return
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeoContinuity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outDir = dir
        startedAt = Date()

        let proc = Process()
        proc.executableURL = helper
        proc.arguments = ["--out", dir.path]
        proc.qualityOfService = .userInitiated

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.handleTermination(exitCode: process.terminationStatus, errPipe: errPipe)
            }
        }

        do {
            onStatus("Otevírám foťák na iPhonu…")
            try proc.run()
            process = proc
            startPolling()
        } catch {
            fail("Nepodařilo se spustit ContinuityHelper: \(error.localizedDescription)")
        }
    }

    func cancel() {
        finished = true
        process?.terminate()
        tearDown()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollForPhoto()
        }
    }

    private func pollForPhoto() {
        guard !finished, let dir = outDir else { return }
        if Date().timeIntervalSince(startedAt) > 120 {
            fail("Vypršel čas. Odemkni iPhone a nech ho poblíž Macu (Wi‑Fi + Bluetooth, stejné Apple ID).")
            process?.terminate()
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let photos = files.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        guard let newest = photos.max(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }), let data = try? Data(contentsOf: newest), !data.isEmpty else {
            onStatus("Čekám na fotku z iPhonu…")
            return
        }

        finished = true
        process?.terminate()
        onStatus("Fotografie přijata.")
        onImage(data)
        tearDown()
    }

    private func handleTermination(exitCode: Int32, errPipe: Pipe) {
        guard !finished else { return }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Možná fotka dorazila těsně před exitem
        pollForPhoto()
        guard !finished else { return }

        if errText.contains("submenu never attached") || errText.contains("no Take Photo") {
            fail("iPhone nenalezen. Odemkni iPhone poblíž Macu (stejné Apple ID, Wi‑Fi, Bluetooth).")
        } else if errText.contains("timeout") {
            fail("Vypršel čas čekání na iPhone.")
        } else if exitCode != 0 {
            fail(errText.isEmpty ? "Continuity focení skončilo chybou (\(exitCode))." : errText)
        } else {
            fail("Focení skončilo bez fotografie. Zkus znovu s odemčeným iPhonem poblíž.")
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        onFailed(message)
        tearDown()
    }

    private func tearDown() {
        pollTimer?.invalidate()
        pollTimer = nil
        process = nil
        if let dir = outDir {
            try? FileManager.default.removeItem(at: dir)
            outDir = nil
        }
    }
}
