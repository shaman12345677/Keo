import Foundation

/// Rozliší dávku z čtečky od psaní na klávesnici. Štítek má víc řádků oddělených
/// Enterem a končí „V:2“. Celý štítek je jeden sken, teprve pauza ho uzavře.
/// Pomalé stisky patří do textového pole.
public enum ScanBurstStep: Equatable, Sendable {
    case pass(flushPending: Bool)
    case hold(flushPending: Bool)
    case capture
    case commit(String)
    case commitIdle(String)
    case flushPending
    case typeBurst
    case dropBurst
}

public struct ScanBurstAssembler: Sendable {
    private struct Held {
        var char: Character
        var time: TimeInterval
    }

    private var held: Held?
    private var burst: [Character] = []
    private var capturing = false
    private var sawTerminator = false
    private var lastTime: TimeInterval = -.greatestFiniteMagnitude
    public var gap: TimeInterval = 0.1
    public var idle: TimeInterval = 0.55
    public var minimumIdleCount = 3

    public init() {}

    public mutating func push(character: Character, at time: TimeInterval) -> [ScanBurstStep] {
        if capturing {
            if time - lastTime > idle {
                let finished = finishCapturing()
                held = Held(char: character, time: time)
                lastTime = time
                return [finished, .hold(flushPending: false)]
            }
            burst.append(character)
            lastTime = time
            return [.capture]
        }
        if let held, time - held.time <= gap {
            capturing = true
            burst = [held.char, character]
            self.held = nil
            lastTime = time
            return [.capture]
        }
        let flush = held != nil
        held = Held(char: character, time: time)
        lastTime = time
        return [.hold(flushPending: flush)]
    }

    /// Seznam karet nemá dostat znaky z čtečky. Každý stisk patří do skenu, i když čtečka není nejrychlejší.
    public mutating func pushForced(character: Character, at time: TimeInterval) -> [ScanBurstStep] {
        var steps: [ScanBurstStep] = []
        if capturing, time - lastTime > idle {
            steps.append(finishCapturing())
        }
        if let held {
            burst.append(held.char)
            self.held = nil
        }
        burst.append(character)
        capturing = true
        lastTime = time
        steps.append(.capture)
        return steps
    }

    public mutating func pushTerminator(at time: TimeInterval) -> [ScanBurstStep] {
        let fast = time - lastTime <= gap
        if capturing || (held != nil && fast) {
            if let held {
                burst.append(held.char)
                self.held = nil
            }
            if !burst.isEmpty { burst.append("\n") }
            capturing = true
            sawTerminator = true
            lastTime = time
            return [.capture]
        }
        let flush = held != nil
        held = nil
        lastTime = time
        return [.pass(flushPending: flush)]
    }

    public mutating func interrupt() -> [ScanBurstStep] {
        if capturing || !burst.isEmpty {
            burst = []
            capturing = false
            sawTerminator = false
            held = nil
            return [.dropBurst]
        }
        let flush = held != nil
        held = nil
        return flush ? [.flushPending] : []
    }

    public mutating func tick(at time: TimeInterval) -> [ScanBurstStep] {
        if capturing, time - lastTime >= idle {
            return [finishCapturing()]
        }
        if let held, time - held.time >= gap {
            self.held = nil
            return [.flushPending]
        }
        return []
    }

    public func nextWake(after time: TimeInterval) -> TimeInterval? {
        let wake: TimeInterval?
        if capturing {
            wake = lastTime + idle
        } else if let held {
            wake = held.time + gap
        } else {
            wake = nil
        }
        guard let wake, wake > time else { return nil }
        return wake
    }

    private mutating func finishCapturing() -> ScanBurstStep {
        let text = String(burst).trimmingCharacters(in: .whitespacesAndNewlines)
        let finishedByEnter = sawTerminator
        burst = []
        capturing = false
        sawTerminator = false
        if finishedByEnter || text.count >= minimumIdleCount {
            return text.isEmpty ? .dropBurst : .commitIdle(text)
        }
        return .typeBurst
    }
}
