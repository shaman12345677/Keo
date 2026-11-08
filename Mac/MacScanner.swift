import AppKit
import Combine
import KeoCore

private final class KeyGate: @unchecked Sendable {
    var scanning = false
    var editing = false
}

private final class EventCarrier: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}

struct MacScan: Equatable, Identifiable {
    var id = UUID()
    var text: String
}

/// Čtečka v režimu klávesnice posílá americké kódy kláves. Česká klávesnice Macu
/// by z nich udělala jiné znaky, proto se kód skenu bere z polohy klávesy.
/// Pomalé psaní se do čtečky nepočítá a zůstane v textovém poli.
@MainActor
final class MacScanner: ObservableObject {
    @Published var isScanning = false {
        didSet { refreshGate() }
    }
    @Published private(set) var latest: MacScan?
    private var assembler = ScanBurstAssembler()
    private var monitor: Any?
    private var held: NSEvent?
    private var burst: [NSEvent] = []
    private var arm: Task<Void, Never>?
    private var passing = false
    private let gate = KeyGate()
    private var eventTap: CFMachPort?

    init() {
        assembler.idle = 1.2
        installTap()
        installMonitor()
        observeEditing()
        refreshGate()
    }

    private func observeEditing() {
        let center = NotificationCenter.default
        for name in [NSText.didBeginEditingNotification, NSText.didEndEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshGate()
                }
            }
        }
    }

    /// Poslední nainstalovaný monitor dostane klávesu jako první. Jinak seznam
    /// karet stihne výběr posunout dřív, než čtečku spolkne skenování.
    func installMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let carrier = EventCarrier(event)
            guard let self else { return event }
            let swallow = MainActor.assumeIsolated {
                self.consume(carrier)
            }
            return swallow ? nil : event
        }
    }

    func stopScanning() {
        arm?.cancel()
        apply(assembler.interrupt(), event: nil)
    }

    private func consume(_ carrier: EventCarrier) -> Bool {
        handle(carrier.event) == nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if passing || event.isARepeat { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = event.keyCode
        refreshGate()
        if !isScanning {
            if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
                return event
            }
            return Self.isEditingText ? event : nil
        }
        if modifiers.contains(.command) {
            return event
        }
        if modifiers.contains(.control) || modifiers.contains(.option) {
            return nil
        }
        if Self.navigation.contains(code) {
            return nil
        }
        if Self.terminators.contains(code) {
            let steps = assembler.pushTerminator(at: event.timestamp)
            apply(steps, event: event)
            armTick(from: event.timestamp)
            return swallows(steps) ? nil : event
        }
        guard let character = Self.character(for: code, shifted: modifiers.contains(.shift)) else {
            return nil
        }
        let steps = assembler.pushForced(character: character, at: event.timestamp)
        apply(steps, event: event)
        armTick(from: event.timestamp)
        return nil
    }

    private func apply(_ steps: [ScanBurstStep], event: NSEvent?) {
        for step in steps {
            switch step {
            case .pass(let flush):
                if flush { deliverHeld() }
            case .hold(let flush):
                if flush { deliverHeld() }
                held = event
            case .capture:
                if let held {
                    burst.append(held)
                    self.held = nil
                }
                if let event { burst.append(event) }
            case .commit(let text), .commitIdle(let text):
                held = nil
                burst = []
                guard !text.isEmpty else { continue }
                latest = MacScan(text: text)
            case .flushPending:
                deliverHeld()
            case .typeBurst:
                let events = burst
                burst = []
                held = nil
                for item in events { deliver(item) }
            case .dropBurst:
                burst = []
                held = nil
            }
        }
    }

    private func swallows(_ steps: [ScanBurstStep]) -> Bool {
        steps.contains { step in
            switch step {
            case .hold, .capture, .commit, .commitIdle:
                return true
            default:
                return false
            }
        }
    }

    private func armTick(from stamp: TimeInterval) {
        arm?.cancel()
        guard let wake = assembler.nextWake(after: stamp) else { return }
        let delay = max(0.01, wake - stamp)
        arm = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.apply(self.assembler.tick(at: wake + 0.001), event: nil)
        }
    }

    private func deliverHeld() {
        guard let held else { return }
        self.held = nil
        deliver(held)
    }

    private func deliver(_ event: NSEvent) {
        guard Self.isEditingText else { return }
        passing = true
        NSApp.sendEvent(event)
        passing = false
    }

    private func refreshGate() {
        gate.scanning = isScanning
        gate.editing = Self.isEditingText
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    /// Čtečka nesmí dojít do seznamu dřív než místní monitor. Při vypnutém
    /// skenování se klávesa zahodí ještě před oknem, hledání v poli zůstane.
    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(gate).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let gate = Unmanaged<KeyGate>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                if gate.scanning || gate.editing { return Unmanaged.passUnretained(event) }
                let flags = event.flags
                if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
                    return Unmanaged.passUnretained(event)
                }
                return nil
            },
            userInfo: info
        ) else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static var isEditingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    private static let terminators: Set<UInt16> = [36, 76, 48]
    private static let navigation: Set<UInt16> = [53, 51, 123, 124, 125, 126, 115, 116, 119, 121]

    private static func character(for code: UInt16, shifted: Bool) -> Character? {
        guard let pair = keys[code] else { return nil }
        let value = shifted ? pair.shifted : pair.plain
        return value.first
    }

    private static let keys: [UInt16: (plain: String, shifted: String)] = [
        0x00: ("a", "A"), 0x01: ("s", "S"), 0x02: ("d", "D"), 0x03: ("f", "F"),
        0x04: ("h", "H"), 0x05: ("g", "G"), 0x06: ("z", "Z"), 0x07: ("x", "X"),
        0x08: ("c", "C"), 0x09: ("v", "V"), 0x0B: ("b", "B"), 0x0C: ("q", "Q"),
        0x0D: ("w", "W"), 0x0E: ("e", "E"), 0x0F: ("r", "R"), 0x10: ("y", "Y"),
        0x11: ("t", "T"), 0x1F: ("o", "O"), 0x20: ("u", "U"), 0x22: ("i", "I"),
        0x23: ("p", "P"), 0x25: ("l", "L"), 0x26: ("j", "J"), 0x28: ("k", "K"),
        0x2D: ("n", "N"), 0x2E: ("m", "M"),
        0x12: ("1", "!"), 0x13: ("2", "@"), 0x14: ("3", "#"), 0x15: ("4", "$"),
        0x17: ("5", "%"), 0x16: ("6", "^"), 0x1A: ("7", "&"), 0x1C: ("8", "*"),
        0x19: ("9", "("), 0x1D: ("0", ")"),
        0x1B: ("-", "_"), 0x18: ("=", "+"), 0x21: ("[", "{"), 0x1E: ("]", "}"),
        0x2A: ("\\", "|"), 0x0A: ("\\", "|"), 0x29: (";", ":"), 0x27: ("'", "\""),
        0x32: ("`", "~"), 0x2B: (",", "<"), 0x2F: (".", ">"), 0x2C: ("/", "?"),
        0x31: (" ", " "),
        0x52: ("0", "0"), 0x53: ("1", "1"), 0x54: ("2", "2"), 0x55: ("3", "3"),
        0x56: ("4", "4"), 0x57: ("5", "5"), 0x58: ("6", "6"), 0x59: ("7", "7"),
        0x5B: ("8", "8"), 0x5C: ("9", "9"),
        0x4E: ("-", "-"), 0x45: ("+", "+"), 0x41: (".", "."), 0x4B: ("/", "/"),
        0x43: ("*", "*"), 0x51: ("=", "="),
    ]
}
