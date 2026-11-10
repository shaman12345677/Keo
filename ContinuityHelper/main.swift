import AppKit

/// Samostatný Continuity Camera helper (Take Photo → JPEG do --out).
/// Vlastní NSApplication + File menu — funguje i ze sandboxu (ověřeno).

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let outDir: String
    let outFile: String
    var window: NSWindow!
    var textView: CaptureTextView!
    var received = false
    var invoked = false

    init(outDir: String, outFile: String) {
        self.outDir = outDir
        self.outFile = outFile
    }

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

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.midX - 150, y: screen.midY - 60, width: 300, height: 120)
        window = KeyableWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.02
        window.level = .floating

        textView = CaptureTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        textView.isRichText = true
        textView.isEditable = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.delegate = self
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidChange(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.trigger(attempt: 1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if !self.received {
                fputs("timeout\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }

    func trigger(attempt: Int) {
        func retry(_ reason: String) {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.trigger(attempt: attempt + 1) }
            } else {
                fputs("\(reason)\n", stderr)
                NSApp.terminate(nil)
            }
        }

        guard let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu,
              let magic = fileMenu.items.first(where: { $0.submenu != nil }),
              let sub = magic.submenu else {
            retry("import submenu never attached")
            return
        }
        sub.update()
        let dump = sub.items.map { "'\($0.title)'\($0.isEnabled ? "" : "(off)")\($0.submenu != nil ? "+sub" : "")" }.joined(separator: ", ")
        fputs("submenu[\(attempt)]: \(dump)\n", stderr)

        if fireTakePhoto(in: sub) {
            return
        }
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
        if let idx = menu.items.firstIndex(where: { !$0.isSeparatorItem && $0.isEnabled && isPhotoTitle($0.title) }) {
            invoked = true
            fputs("firing '\(menu.items[idx].title)'\n", stderr)
            menu.performActionForItem(at: idx)
            return true
        }
        for item in menu.items {
            guard let nested = item.submenu else { continue }
            nested.update()
            if fireTakePhoto(in: nested) { return true }
        }
        // Některé buildy mají Take Photo disabled, dokud není first responder hotový — zkus i disabled.
        if let idx = menu.items.firstIndex(where: { !$0.isSeparatorItem && isPhotoTitle($0.title) }) {
            invoked = true
            fputs("firing (forced) '\(menu.items[idx].title)' enabled=\(menu.items[idx].isEnabled)\n", stderr)
            menu.performActionForItem(at: idx)
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
            try? FileManager.default.createDirectory(atPath: self.outDir, withIntermediateDirectories: true)
            do {
                try jpeg.write(to: URL(fileURLWithPath: self.outFile), options: .atomic)
                self.received = true
                fputs("saved \(self.outFile)\n", stderr)
                stop.pointee = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            } catch {
                fputs("write failed: \(error)\n", stderr)
            }
        }
    }
}

var outDir = FileManager.default.temporaryDirectory.path
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--out", !args.isEmpty {
        outDir = (args.removeFirst() as NSString).expandingTildeInPath
    }
}
let stamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}()
let outFile = (outDir as NSString).appendingPathComponent("Keo_\(stamp).jpg")

let app = NSApplication.shared
let delegate = AppDelegate(outDir: outDir, outFile: outFile)
app.delegate = delegate
app.run()
