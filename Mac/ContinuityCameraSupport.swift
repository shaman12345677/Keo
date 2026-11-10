import AppKit
import CoreGraphics

/// Continuity Camera přes ContinuityHelper.app (vlastní bundle id + vlastní sandbox).
/// Spouštění přes NSWorkspace (ne Process/inherit) — vhodné pro TestFlight / Mac App Store.
/// JPEG + status: pevná pasteboard + App Group soubory / UserDefaults suite.
enum ContinuityCameraSupport {
    static let helperBundleID = "cz.samekt.keo.continuityhelper"
    static let appGroupID = "group.cz.samekt.keo"
    static let pasteboardName = NSPasteboard.Name("cz.samekt.keo.continuity.transfer")
    static let statusType = NSPasteboard.PasteboardType("cz.samekt.keo.continuity.status")
    static let jpegType = NSPasteboard.PasteboardType("cz.samekt.keo.continuity.jpeg")
    static let jpegFileName = "keo-continuity-last.jpg"
    static let statusFileName = "keo-continuity-status.txt"

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

    static func helperAppURL() -> URL? {
        let nested = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ContinuityHelper.app")
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        return nil
    }

    static var pasteboard: NSPasteboard { NSPasteboard(name: pasteboardName) }

    static func groupURL(_ name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(name)
    }

    static func clearTransfer() {
        pasteboard.clearContents()
        try? groupURL(jpegFileName).map { try FileManager.default.removeItem(at: $0) }
        try? groupURL(statusFileName).map { try FileManager.default.removeItem(at: $0) }
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: "lastJPEG")
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: "lastStatus")
        UserDefaults(suiteName: appGroupID)?.synchronize()
    }

    static func readJPEG() -> Data? {
        if let data = pasteboard.data(forType: jpegType), !data.isEmpty { return data }
        if let data = pasteboard.data(forType: .init("public.jpeg")), !data.isEmpty { return data }
        if let url = groupURL(jpegFileName), let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        if let data = UserDefaults(suiteName: appGroupID)?.data(forKey: "lastJPEG"), !data.isEmpty {
            return data
        }
        return nil
    }

    static func readStatus() -> String? {
        if let s = pasteboard.string(forType: statusType)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        if let url = groupURL(statusFileName),
           let s = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        if let s = UserDefaults(suiteName: appGroupID)?.string(forKey: "lastStatus")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        return nil
    }
}

final class ContinuityTakePhotoSession {
    private let onImage: (Data) -> Void
    private let onStatus: (String) -> Void
    private let onFailed: (String) -> Void

    private var helperPID: pid_t?
    private var pollTimer: Timer?
    private var finished = false
    private var startedAt = Date()
    private var sawHelperContinuityPanel = false
    private var missingHelperPanelTicks = 0
    private var sawHelperRunning = false
    private var missingHelperAppTicks = 0
    private var resultObserver: NSObjectProtocol?

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

        guard let helperApp = ContinuityCameraSupport.helperAppURL() else {
            onFailed("ContinuityHelper chybí v aplikaci. Znovu sestav Mac target.")
            return
        }

        ContinuityCameraSupport.clearTransfer()
        startedAt = Date()
        installResultObserver()

        for app in NSRunningApplication.runningApplications(
            withBundleIdentifier: ContinuityCameraSupport.helperBundleID
        ) {
            app.terminate()
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.allowsRunningApplicationSubstitution = false
        config.createsNewApplicationInstance = true

        onStatus("Otevírám foťák na iPhonu…")
        NSWorkspace.shared.openApplication(at: helperApp, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let error {
                    self.fail("Nepodařilo se spustit ContinuityHelper: \(error.localizedDescription)")
                    return
                }
                self.helperPID = app?.processIdentifier
                self.sawHelperRunning = app != nil
                self.startPolling()
            }
        }
    }

    private func installResultObserver() {
        if let resultObserver {
            DistributedNotificationCenter.default().removeObserver(resultObserver)
        }
        resultObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("cz.samekt.keo.continuity.result"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, !self.finished else { return }
            let result = (note.object as? String) ?? ""
            self.handleIPCResult(result)
        }
    }

    private func handleIPCResult(_ result: String) {
        if let jpeg = ContinuityCameraSupport.readJPEG(), !jpeg.isEmpty {
            finished = true
            terminateHelper()
            onStatus("Fotografie přijata.")
            onImage(jpeg)
            tearDown()
            return
        }
        let status = result.isEmpty ? (ContinuityCameraSupport.readStatus() ?? "") : result
        if status == "ok" {
            // JPEG ještě nemusí být vidět — poll to dožene.
            return
        }
        if !status.isEmpty {
            fail(mapStatus(status))
        }
    }

    private func banishLocalContinuityChrome() {
        for w in NSApp.windows {
            if w.styleMask.contains(.titled), w.frame.width > 500 { continue }
            let f = w.frame
            let looks = w.title.lowercased().contains("fot")
                || w.title.lowercased().contains("iphone")
                || w.title.lowercased().contains("photo")
            let sizeOK = f.width >= 150 && f.width <= 420 && f.height >= 120 && f.height <= 280
            guard looks || sizeOK else { continue }
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.contentView?.isHidden = true
            if f.origin.x > -5000 {
                w.setFrame(NSRect(x: -20000, y: -20000, width: f.width, height: f.height), display: false)
            }
        }
    }

    func cancel() {
        fail("Zrušeno.")
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollForPhoto()
        }
    }

    private func helperStillRunning() -> Bool {
        if let pid = helperPID {
            return NSRunningApplication(processIdentifier: pid) != nil
        }
        return !NSRunningApplication.runningApplications(
            withBundleIdentifier: ContinuityCameraSupport.helperBundleID
        ).isEmpty
    }

    private func resolvedHelperPID() -> pid_t? {
        if let pid = helperPID, NSRunningApplication(processIdentifier: pid) != nil {
            return pid
        }
        return NSRunningApplication.runningApplications(
            withBundleIdentifier: ContinuityCameraSupport.helperBundleID
        ).first?.processIdentifier
    }

    private func pollForPhoto() {
        guard !finished else { return }
        if Date().timeIntervalSince(startedAt) > 100 {
            fail("Vypršel čas. Odemkni iPhone a nech ho poblíž Macu (Wi‑Fi + Bluetooth, stejné Apple ID).")
            return
        }

        banishLocalContinuityChrome()

        if let jpeg = ContinuityCameraSupport.readJPEG(), !jpeg.isEmpty {
            finished = true
            terminateHelper()
            onStatus("Fotografie přijata.")
            onImage(jpeg)
            tearDown()
            return
        }

        if let status = ContinuityCameraSupport.readStatus(), status != "ok" {
            fail(mapStatus(status))
            return
        }

        if let pid = resolvedHelperPID() {
            helperPID = pid
            if Self.helperContinuityPanelExists(pid: pid) {
                sawHelperContinuityPanel = true
                missingHelperPanelTicks = 0
            } else if sawHelperContinuityPanel {
                // Panel pryč: krátká grace na JPEG, jinak cancel (helper taky posílá status).
                missingHelperPanelTicks += 1
                if missingHelperPanelTicks >= 4 { // ~1 s
                    if let jpeg = ContinuityCameraSupport.readJPEG(), !jpeg.isEmpty {
                        finished = true
                        terminateHelper()
                        onStatus("Fotografie přijata.")
                        onImage(jpeg)
                        tearDown()
                        return
                    }
                    if let status = ContinuityCameraSupport.readStatus(), status != "ok" {
                        fail(mapStatus(status))
                        return
                    }
                    fail("Zrušeno.")
                    return
                }
            }
        }

        if helperStillRunning() {
            sawHelperRunning = true
            missingHelperAppTicks = 0
        } else if sawHelperRunning {
            missingHelperAppTicks += 1
            if missingHelperAppTicks >= 3 {
                handleHelperExit()
                return
            }
        }

        onStatus("Čekám na fotku z iPhonu…")
    }

    private func mapStatus(_ status: String) -> String {
        if status.contains("cancelled") { return "Zrušeno." }
        if status.contains("submenu never attached") || status.contains("no Take Photo") {
            return "iPhone nenalezen. Odemkni iPhone poblíž Macu (stejné Apple ID, Wi‑Fi, Bluetooth)."
        }
        if status.contains("timeout") { return "Vypršel čas čekání na iPhone." }
        if status.hasPrefix("write failed") { return "Nepodařilo se uložit fotku z Continuity." }
        return status
    }

    private func handleHelperExit() {
        guard !finished else { return }
        if let jpeg = ContinuityCameraSupport.readJPEG(), !jpeg.isEmpty {
            finished = true
            onStatus("Fotografie přijata.")
            onImage(jpeg)
            tearDown()
            return
        }
        if let status = ContinuityCameraSupport.readStatus(), status != "ok" {
            fail(mapStatus(status))
            return
        }
        fail("Focení skončilo bez fotografie. Zkus znovu s odemčeným iPhonem poblíž.")
    }

    private static func helperContinuityPanelExists(pid: Int32) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for item in info {
            guard (item[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            let bounds = item[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            if abs(width - 300) < 2, abs(height - 120) < 2 { continue }
            if width >= 150, width <= 280, height >= 120, height <= 240 {
                return true
            }
        }
        return false
    }

    private func terminateHelper() {
        if let pid = helperPID, let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        }
        for app in NSRunningApplication.runningApplications(
            withBundleIdentifier: ContinuityCameraSupport.helperBundleID
        ) {
            app.terminate()
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        terminateHelper()
        onFailed(message)
        tearDown()
    }

    private func tearDown() {
        pollTimer?.invalidate()
        pollTimer = nil
        helperPID = nil
        if let resultObserver {
            DistributedNotificationCenter.default().removeObserver(resultObserver)
            self.resultObserver = nil
        }
        ContinuityCameraSupport.clearTransfer()
    }
}
