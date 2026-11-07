import Foundation
import GameController

struct WedgeScan: Equatable {
    var id = UUID()
    var text: String
}

/// Laserové čtečky v režimu HID posílají americké klávesové kódy. iOS by je jinak
/// přeložilo podle české klávesnice a z čísla by vznikly jiné znaky.
@MainActor
final class KeyboardWedge: NSObject, ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var latest: WedgeScan?
    private var buffer = ""
    private var leftShift = false
    private var rightShift = false
    private var tokens: [NSObjectProtocol] = []
    private var flushTask: Task<Void, Never>?

    func start() {
        guard tokens.isEmpty else {
            attach()
            return
        }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        })
        tokens.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.buffer = ""
                self?.attach()
            }
        })
        attach()
    }

    func stop() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        flushTask?.cancel()
        buffer = ""
        connected = false
    }

    private func attach() {
        connected = GCKeyboard.coalesced != nil
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
            Task { @MainActor in
                self?.feed(code, pressed: pressed)
            }
        }
    }

    private func feed(_ code: GCKeyCode, pressed: Bool) {
        if code == .leftShift {
            leftShift = pressed
            return
        }
        if code == .rightShift {
            rightShift = pressed
            return
        }
        guard pressed else { return }
        if code == .returnOrEnter || code == .keypadEnter || code == .tab {
            buffer.append("\n")
            scheduleFlush()
            return
        }
        if code == .deleteOrBackspace {
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        guard let character = Self.character(for: code, shifted: leftShift || rightShift) else { return }
        buffer.append(character)
        if buffer.count > 512 { buffer.removeFirst(buffer.count - 512) }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        flushTask?.cancel()
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !text.isEmpty else { return }
        latest = WedgeScan(text: text)
    }

    private static func character(for code: GCKeyCode, shifted: Bool) -> Character? {
        let pair = keys[code]
        let value = shifted ? (pair?.shifted ?? pair?.plain) : pair?.plain
        return value?.first
    }

    private static let keys: [GCKeyCode: (plain: String, shifted: String)] = [
        .keyA: ("a", "A"), .keyB: ("b", "B"), .keyC: ("c", "C"), .keyD: ("d", "D"),
        .keyE: ("e", "E"), .keyF: ("f", "F"), .keyG: ("g", "G"), .keyH: ("h", "H"),
        .keyI: ("i", "I"), .keyJ: ("j", "J"), .keyK: ("k", "K"), .keyL: ("l", "L"),
        .keyM: ("m", "M"), .keyN: ("n", "N"), .keyO: ("o", "O"), .keyP: ("p", "P"),
        .keyQ: ("q", "Q"), .keyR: ("r", "R"), .keyS: ("s", "S"), .keyT: ("t", "T"),
        .keyU: ("u", "U"), .keyV: ("v", "V"), .keyW: ("w", "W"), .keyX: ("x", "X"),
        .keyY: ("y", "Y"), .keyZ: ("z", "Z"),
        .one: ("1", "!"), .two: ("2", "@"), .three: ("3", "#"), .four: ("4", "$"),
        .five: ("5", "%"), .six: ("6", "^"), .seven: ("7", "&"), .eight: ("8", "*"),
        .nine: ("9", "("), .zero: ("0", ")"),
        .hyphen: ("-", "_"), .equalSign: ("=", "+"),
        .openBracket: ("[", "{"), .closeBracket: ("]", "}"),
        .backslash: ("\\", "|"), .nonUSBackslash: ("\\", "|"), .nonUSPound: ("\\", "|"),
        .semicolon: (";", ":"), .quote: ("'", "\""),
        .graveAccentAndTilde: ("`", "~"),
        .comma: (",", "<"), .period: (".", ">"), .slash: ("/", "?"),
        .spacebar: (" ", " "),
        .keypad0: ("0", "0"), .keypad1: ("1", "1"), .keypad2: ("2", "2"),
        .keypad3: ("3", "3"), .keypad4: ("4", "4"), .keypad5: ("5", "5"),
        .keypad6: ("6", "6"), .keypad7: ("7", "7"), .keypad8: ("8", "8"),
        .keypad9: ("9", "9"),
        .keypadHyphen: ("-", "-"), .keypadPlus: ("+", "+"),
        .keypadPeriod: (".", "."), .keypadSlash: ("/", "/"),
        .keypadAsterisk: ("*", "*"), .keypadEqualSign: ("=", "="),
    ]
}
