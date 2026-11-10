import AppKit

/// Continuity Camera „Vyfotit na iPhonu“.
/// Běží in-process (NSTextView + dočasné File menu) — samostatný ContinuityHelper
/// v TestFlight/App Store padal (SIGTRAP / prázdný sandbox).
enum ContinuityCameraSupport {
    static let photoTitles = [
        "Take Photo", "Vyfotit", "Pořídit fotografii", "Pořídit fotku", "사진 찍기"
    ]

    static func registerServices() {
        let returnTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
            + [NSPasteboard.PasteboardType("com.adobe.pdf")]
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)
    }

    @discardableResult
    static func installMenuItemIfNeeded() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        if let existing = findImportItem(in: mainMenu) { return existing }

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

    static func isTakePhotoTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        if t.contains("scan") || t.contains("sken") || t.contains("nasken")
            || t.contains("sketch") || t.contains("náčrt") || t.contains("kresb") {
            return false
        }
        return photoTitles.contains(title)
            || t.contains("take photo")
            || t.contains("vyfotit")
            || t.contains("pořídit fot")
            || t.contains("fotograf")
            || t.contains("fotku")
    }
}

// MARK: - In-process capture (ContinuityCapture styl)

final class ContinuityTakePhotoSession: NSObject, NSTextViewDelegate {
    private let onImage: (Data) -> Void
    private let onStatus: (String) -> Void
    private let onFailed: (String) -> Void

    private var window: KeyableWindow?
    private var textView: CaptureTextView?
    private var previousMainMenu: NSMenu?
    private var captureMainMenu: NSMenu?
    private var menuGuard: Timer?
    private var observers: [NSObjectProtocol] = []
    private var received = false
    private var invoked = false
    private var finished = false

    init(
        onStatus: @escaping (String) -> Void,
        onImage: @escaping (Data) -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        self.onStatus = onStatus
        self.onImage = onImage
        self.onFailed = onFailed
        super.init()
    }

    func start() {
        ContinuityCameraSupport.registerServices()
        installCaptureMainMenu()

        let mouse = NSEvent.mouseLocation
        let rect = NSRect(x: mouse.x - 20, y: mouse.y - 20, width: 40, height: 40)
        let window = KeyableWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.02
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let textView = CaptureTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        textView.isRichText = true
        textView.isEditable = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.delegate = self
        window.contentView = textView

        self.window = window
        self.textView = textView

        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage,
            queue: .main
        ) { [weak self] _ in
            self?.extractAttachments()
        })

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        // SwiftUI občas vrátí své menu — drž Continuity File menu po dobu focení.
        menuGuard = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.ensureCaptureMenu()
        }
        if let menuGuard {
            RunLoop.main.add(menuGuard, forMode: .common)
        }

        onStatus("Hledám iPhone…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.trigger(attempt: 1)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, !self.received, !self.finished else { return }
            self.fail("Vypršel čas. Odemkni iPhone a nech ho poblíž Macu (Wi‑Fi + Bluetooth, stejné Apple ID).")
        }
    }

    func cancel() {
        finished = true
        tearDown()
    }

    private func installCaptureMainMenu() {
        previousMainMenu = NSApp.mainMenu
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Keo4 inventura")
        let cancelItem = NSMenuItem(title: "Zrušit focení", action: #selector(cancelFromMenu), keyEquivalent: ".")
        cancelItem.target = self
        appMenu.addItem(cancelItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let magic = NSMenuItem(title: "Import from Device", action: nil, keyEquivalent: "")
        magic.identifier = NSMenuItem.importFromDeviceIdentifier
        fileMenu.addItem(magic)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        captureMainMenu = mainMenu
        NSApp.mainMenu = mainMenu
    }

    private func ensureCaptureMenu() {
        guard !finished, let captureMainMenu else { return }
        if NSApp.mainMenu !== captureMainMenu {
            NSApp.mainMenu = captureMainMenu
        }
    }

    @objc private func cancelFromMenu() {
        fail("Zrušeno.")
    }

    private func trigger(attempt: Int) {
        guard !finished, !received else { return }
        ensureCaptureMenu()
        window?.makeKeyAndOrderFront(nil)
        if let textView { window?.makeFirstResponder(textView) }

        let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu
        fileMenu?.update()
        guard let magic = fileMenu?.items.first(where: { $0.submenu != nil }),
              let sub = magic.submenu else {
            if attempt < 25 {
                onStatus("Čekám na Continuity menu… (\(attempt))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.trigger(attempt: attempt + 1)
                }
            } else {
                fail("iPhone nenalezen. Odemkni iPhone poblíž Macu (stejné Apple ID, Wi‑Fi, Bluetooth).")
            }
            return
        }

        sub.update()
        if fireTakePhoto(in: sub) { return }

        let titles = sub.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: ", ")
        if attempt < 25 {
            onStatus(titles.isEmpty ? "Čekám na iPhone… (\(attempt))" : "Nabídka: \(titles)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.trigger(attempt: attempt + 1)
            }
        } else if titles.isEmpty {
            fail("iPhone nenalezen. Musí být poblíž a odemčený.")
        } else {
            fail("Continuity nabídka je tu (\(titles)), ale bez „Pořídit fotku“.")
        }
    }

    @discardableResult
    private func fireTakePhoto(in menu: NSMenu) -> Bool {
        if let idx = menu.items.firstIndex(where: {
            !$0.isSeparatorItem && $0.isEnabled && ContinuityCameraSupport.isTakePhotoTitle($0.title)
        }) {
            invoked = true
            onStatus("Otevírám foťák na iPhonu… vyfoťte a potvrďte.")
            menu.performActionForItem(at: idx)
            return true
        }
        for item in menu.items {
            guard let nested = item.submenu else { continue }
            nested.update()
            if fireTakePhoto(in: nested) { return true }
        }
        // Fallback: i disabled „Pořídit fotku“
        if let idx = menu.items.firstIndex(where: {
            !$0.isSeparatorItem && ContinuityCameraSupport.isTakePhotoTitle($0.title)
        }) {
            invoked = true
            onStatus("Otevírám foťák na iPhonu… vyfoťte a potvrďte.")
            menu.performActionForItem(at: idx)
            return true
        }
        return false
    }

    private func extractAttachments() {
        guard !received, let storage = textView?.textStorage, storage.length > 0 else { return }
        DispatchQueue.main.async { [weak self] in self?.pullAttachments() }
    }

    private func pullAttachments() {
        guard !received, let storage = textView?.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let att = value as? NSTextAttachment else { return }
            if let data = self.attachmentData(att) {
                self.received = true
                self.finished = true
                stop.pointee = true
                self.onStatus("Fotografie přijata.")
                self.onImage(data)
                self.tearDown()
            }
        }
    }

    private func attachmentData(_ att: NSTextAttachment) -> Data? {
        if let fw = att.fileWrapper, fw.isRegularFile, let data = fw.regularFileContents, !data.isEmpty {
            return jpegIfNeeded(data)
        }
        if let contents = att.contents, !contents.isEmpty {
            return jpegIfNeeded(contents)
        }
        if let cell = att.attachmentCell as? NSTextAttachmentCell, let image = cell.image {
            return jpegFromImage(image)
        }
        return nil
    }

    private func jpegIfNeeded(_ data: Data) -> Data {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return data }
        if let image = NSImage(data: data) { return jpegFromImage(image) ?? data }
        return data
    }

    private func jpegFromImage(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        onFailed(message)
        tearDown()
    }

    private func tearDown() {
        menuGuard?.invalidate()
        menuGuard = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window?.orderOut(nil)
        window = nil
        textView = nil
        if let previousMainMenu {
            NSApp.mainMenu = previousMainMenu
            self.previousMainMenu = nil
        }
        captureMainMenu = nil
        _ = invoked
    }
}

final class CaptureTextView: NSTextView {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if let returnType,
           NSImage.imageTypes.contains(returnType.rawValue) || returnType.rawValue == "com.adobe.pdf" {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
