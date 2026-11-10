import AppKit
import CoreGraphics

// Continuity Camera panel není NSWindow — jen CGS. Schováme ho přes SkyLight.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32
@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: UInt32, _ wid: UInt32, _ alpha: Float) -> Int32
@_silgen_name("CGSMoveWindow")
func CGSMoveWindow(_ cid: UInt32, _ wid: UInt32, _ point: UnsafePointer<CGPoint>) -> Int32

/// Continuity Take Photo → JPEG do --out.
/// Continuity panel schováme mimo obrazovku; zrušení = okno zanikne (optionAll), ne jen zmizí z monitoru.

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

/// Pevná pasteboard (+ App Group soubory) — NSWorkspace často nepředá --session argv.
enum ContinuityIPC {
    static let pasteboardName = NSPasteboard.Name("cz.samekt.keo.continuity.transfer")
    static let statusType = NSPasteboard.PasteboardType("cz.samekt.keo.continuity.status")
    static let jpegType = NSPasteboard.PasteboardType("cz.samekt.keo.continuity.jpeg")
    static let appGroupID = "group.cz.samekt.keo"
    static let jpegFileName = "keo-continuity-last.jpg"
    static let statusFileName = "keo-continuity-status.txt"

    static var pasteboard: NSPasteboard { NSPasteboard(name: pasteboardName) }

    static func groupURL(_ name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(name)
    }

    static let darwinName = "cz.samekt.keo.continuity.result" as CFString

    static func publish(status: String, jpeg: Data? = nil) {
        let pb = pasteboard
        pb.clearContents()
        let result: String
        if let jpeg, !jpeg.isEmpty {
            pb.setData(jpeg, forType: jpegType)
            pb.setData(jpeg, forType: .init("public.jpeg"))
            pb.setString("ok", forType: statusType)
            if let url = groupURL(jpegFileName) {
                try? jpeg.write(to: url, options: .atomic)
            }
            if let url = groupURL(statusFileName) {
                try? "ok".write(to: url, atomically: true, encoding: .utf8)
            }
            UserDefaults(suiteName: appGroupID)?.set(jpeg, forKey: "lastJPEG")
            UserDefaults(suiteName: appGroupID)?.set("ok", forKey: "lastStatus")
            result = "ok"
        } else {
            pb.setString(status, forType: statusType)
            if let url = groupURL(statusFileName) {
                try? status.write(to: url, atomically: true, encoding: .utf8)
            }
            try? groupURL(jpegFileName).map { try FileManager.default.removeItem(at: $0) }
            UserDefaults(suiteName: appGroupID)?.removeObject(forKey: "lastJPEG")
            UserDefaults(suiteName: appGroupID)?.set(status, forKey: "lastStatus")
            result = status
        }
        UserDefaults(suiteName: appGroupID)?.synchronize()
        DistributedNotificationCenter.default().post(
            name: Notification.Name("cz.samekt.keo.continuity.result"),
            object: result
        )
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName),
            nil,
            nil,
            true
        )
    }

    static func clear() {
        pasteboard.clearContents()
        try? groupURL(jpegFileName).map { try FileManager.default.removeItem(at: $0) }
        try? groupURL(statusFileName).map { try FileManager.default.removeItem(at: $0) }
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: "lastJPEG")
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: "lastStatus")
        UserDefaults(suiteName: appGroupID)?.synchronize()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var textView: CaptureTextView!
    var received = false
    var invoked = false
    var finished = false
    var watchTimer: Timer?
    var trackedPanelIDs: Set<UInt32> = []
    var banishedCGWindowIDs: Set<UInt32> = []
    var goneTicks = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ContinuityHelper")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let magic = NSMenuItem(title: "Import from Device", action: nil, keyEquivalent: "")
        magic.identifier = NSMenuItem.importFromDeviceIdentifier
        fileMenu.addItem(magic)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let returnTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
            + [NSPasteboard.PasteboardType("com.adobe.pdf")]
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)

        // Host mimo obrazovku — Continuity panel se často váže na pozici key window.
        window = KeyableWindow(
            contentRect: NSRect(x: -9000, y: -9000, width: 300, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.level = .floating
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        textView = CaptureTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        textView.isRichText = true
        textView.isEditable = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.drawsBackground = false
        textView.delegate = self
        window.contentView = textView
        window.orderFront(nil)
        window.makeKey()
        window.makeFirstResponder(textView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidChange(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(someWindowClosed(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        // Okamžitě schovej Continuity panel, jakmile vznikne / dostane focus.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didExposeNotification] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, self.invoked, !self.finished else { return }
                if let w = note.object as? NSWindow { self.banishWindowIfNeeded(w) }
                self.banishContinuityChrome()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.trigger(attempt: 1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if !self.received { self.failAndQuit("timeout") }
        }
    }

    @objc func someWindowClosed(_ note: Notification) {
        guard invoked, !received, !finished else { return }
        if let w = note.object as? NSWindow, w === window { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.received, !self.finished else { return }
            self.failAndQuit("cancelled")
        }
    }

    func startWatch() {
        watchTimer?.invalidate()
        trackedPanelIDs = []
        goneTicks = 0
        let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(watchTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        watchTimer = t
    }

    @objc func watchTick() {
        guard invoked, !received, !finished else {
            watchTimer?.invalidate()
            watchTimer = nil
            return
        }

        // 1) Schovej Continuity panel (NEzavírej)
        banishContinuityChrome()

        // 2) Sleduj Continuity panel (optionAll). Po cancel Continuity okno zruší.
        let live = Self.continuityPanelWindowIDs()
        if !live.isEmpty {
            trackedPanelIDs.formUnion(live)
            goneTicks = 0
            return
        }
        if trackedPanelIDs.isEmpty { return }

        // Panel zmizel — krátká grace na JPEG, pak cancel (nesmíme CGS holdovat okno).
        goneTicks += 1
        extract()
        if received || finished { return }
        if goneTicks >= 12 { // ~0.4 s
            failAndQuit("cancelled")
        }
    }

    func banishWindowIfNeeded(_ w: NSWindow) {
        guard w !== window else { return }
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.contentView?.isHidden = true
        w.contentView?.alphaValue = 0
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 2)
        let target = NSRect(x: -20000, y: -20000, width: max(w.frame.width, 180), height: max(w.frame.height, 140))
        if abs(w.frame.origin.x - target.origin.x) > 10 || abs(w.frame.origin.y - target.origin.y) > 10 {
            w.setFrame(target, display: false)
        }
        w.orderBack(nil)
    }

    func banishContinuityChrome() {
        for w in NSApp.windows where w !== window {
            banishWindowIfNeeded(w)
        }
        banishForeignCGWindows()
    }

    /// Continuity panel (181×157) a buffer (500×500) nejsou v NSApp.windows.
    /// Banish jen jednou na window id — opakovaný CGS move brání Continuity zrušit panel při cancel.
    func banishForeignCGWindows() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let hostNum = UInt32(window.windowNumber)
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
        let cid = CGSMainConnectionID()
        var off = CGPoint(x: -30000, y: -30000)
        for item in info {
            guard (item[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let wid = item[kCGWindowNumber as String] as? UInt32,
                  wid != hostNum else { continue }
            if banishedCGWindowIDs.contains(wid) { continue }
            _ = CGSSetWindowAlpha(cid, wid, 0)
            _ = CGSMoveWindow(cid, wid, &off)
            banishedCGWindowIDs.insert(wid)
        }
    }

    /// Continuity panel window IDs tohoto procesu (optionAll = i offscreen).
    static func continuityPanelWindowIDs() -> Set<UInt32> {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids: Set<UInt32> = []
        for item in info {
            guard (item[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let wid = item[kCGWindowNumber as String] as? UInt32 else { continue }
            let bounds = item[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            if abs(width - 300) < 2, abs(height - 120) < 2 { continue } // host
            if width >= 150, width <= 280, height >= 120, height <= 240 {
                ids.insert(wid)
            }
        }
        return ids
    }

    func trigger(attempt: Int) {
        func retry(_ reason: String) {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.trigger(attempt: attempt + 1) }
            } else {
                self.failAndQuit(reason)
            }
        }

        window.orderFront(nil)
        window.makeKey()
        window.makeFirstResponder(textView)

        guard let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu,
              let magic = fileMenu.items.first(where: { $0.submenu != nil }),
              let sub = magic.submenu else {
            retry("import submenu never attached")
            return
        }
        sub.update()
        if fireTakePhoto(in: sub) { return }
        let dump = sub.items.map { "'\($0.title)'\($0.isEnabled ? "" : "(off)")" }.joined(separator: ", ")
        retry("no Take Photo item (\(dump))")
    }

    func isPhotoTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        if t.contains("scan") || t.contains("sken") || t.contains("nasken")
            || t.contains("sketch") || t.contains("náčrt") || t.contains("kresb") {
            return false
        }
        return [
            "Take Photo", "Vyfotit", "Pořídit fotografii", "Pořídit fotku", "사진 찍기"
        ].contains(title)
            || t.contains("take photo")
            || t.contains("vyfotit")
            || t.contains("pořídit fot")
            || t.contains("fotograf")
            || t.contains("fotku")
            || t == "photo"
    }

    @discardableResult
    func fireTakePhoto(in menu: NSMenu) -> Bool {
        func fire(at idx: Int) {
            invoked = true
            fputs("firing '\(menu.items[idx].title)'\n", stderr)
            fflush(stderr)
            menu.performActionForItem(at: idx)
            startWatch()
        }
        if let idx = menu.items.firstIndex(where: { !$0.isSeparatorItem && $0.isEnabled && isPhotoTitle($0.title) }) {
            fire(at: idx)
            return true
        }
        for item in menu.items {
            guard let nested = item.submenu else { continue }
            nested.update()
            if fireTakePhoto(in: nested) { return true }
        }
        if let idx = menu.items.firstIndex(where: { !$0.isSeparatorItem && isPhotoTitle($0.title) }) {
            fire(at: idx)
            return true
        }
        return false
    }

    @objc func textStorageDidChange(_ note: Notification) {
        guard !received, let storage = textView.textStorage, storage.length > 0 else { return }
        DispatchQueue.main.async { self.extract() }
    }

    func extract() {
        guard !received, let storage = textView.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let att = value as? NSTextAttachment else { return }
            var data: Data?
            if let fw = att.fileWrapper, fw.isRegularFile { data = fw.regularFileContents }
            else { data = att.contents }
            guard let raw = data, !raw.isEmpty else { return }
            let jpeg: Data
            if raw.starts(with: [0xFF, 0xD8, 0xFF]) {
                jpeg = raw
            } else if let image = NSImage(data: raw),
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let j = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                jpeg = j
            } else {
                jpeg = raw
            }
            ContinuityIPC.publish(status: "ok", jpeg: jpeg)
            self.received = true
            self.finished = true
            self.watchTimer?.invalidate()
            fputs("published jpeg \(jpeg.count) B\n", stderr)
            fflush(stderr)
            stop.pointee = true
            // Nech Keo čas přečíst pasteboard / App Group (poll 0.35 s).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
        }
    }

    func failAndQuit(_ reason: String) {
        guard !finished else { return }
        finished = true
        watchTimer?.invalidate()
        watchTimer = nil
        ContinuityIPC.publish(status: reason)
        fputs("\(reason)\n", stderr)
        fflush(stderr)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NSApp.terminate(nil) }
    }
}

fputs("ContinuityHelper argv=\(CommandLine.arguments)\n", stderr)
fflush(stderr)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
