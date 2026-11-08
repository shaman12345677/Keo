import XCTest
@testable import KeoCore

final class ScanBurstTests: XCTestCase {
    func testSlowKeyIsReleasedForTyping() {
        var assembler = ScanBurstAssembler()
        XCTAssertEqual(assembler.push(character: "a", at: 0), [.hold(flushPending: false)])
        XCTAssertEqual(assembler.tick(at: 0.1), [.flushPending])
        XCTAssertEqual(assembler.pushTerminator(at: 1), [.pass(flushPending: false)])
    }

    func testFastDigitsAndEnterAreOneScan() {
        var assembler = ScanBurstAssembler()
        XCTAssertEqual(assembler.push(character: "1", at: 0), [.hold(flushPending: false)])
        XCTAssertEqual(assembler.push(character: "0", at: 0.01), [.capture])
        XCTAssertEqual(assembler.push(character: "2", at: 0.02), [.capture])
        XCTAssertEqual(assembler.pushTerminator(at: 0.03), [.capture])
        XCTAssertEqual(assembler.tick(at: 0.6), [.commitIdle("102")])
    }

    func testLongBurstWithoutEnterCommitsAfterPause() {
        var assembler = ScanBurstAssembler()
        _ = assembler.push(character: "1", at: 0)
        _ = assembler.push(character: "0", at: 0.01)
        _ = assembler.push(character: "2", at: 0.02)
        _ = assembler.push(character: "2", at: 0.03)
        XCTAssertEqual(assembler.tick(at: 0.6), [.commitIdle("1022")])
    }

    func testShortBurstIsTypedAfterPause() {
        var assembler = ScanBurstAssembler()
        _ = assembler.push(character: "a", at: 0)
        _ = assembler.push(character: "b", at: 0.01)
        XCTAssertEqual(assembler.tick(at: 0.6), [.typeBurst])
    }

    func testPauseSplitsScanFromLaterTyping() {
        var assembler = ScanBurstAssembler()
        _ = assembler.push(character: "1", at: 0)
        _ = assembler.push(character: "0", at: 0.01)
        _ = assembler.push(character: "2", at: 0.02)
        _ = assembler.push(character: "2", at: 0.03)
        XCTAssertEqual(
            assembler.push(character: "a", at: 1),
            [.commitIdle("1022"), .hold(flushPending: false)]
        )
    }

    func testSlowScannerStillBuildsOneCode() {
        var assembler = ScanBurstAssembler()
        var time = 0.0
        for character in "19-DKP" {
            _ = assembler.pushForced(character: character, at: time)
            time += 0.15
        }
        _ = assembler.pushTerminator(at: time)
        XCTAssertEqual(assembler.tick(at: time + 0.6), [.commitIdle("19-DKP")])
    }

    func testEscapeDropsBurst() {
        var assembler = ScanBurstAssembler()
        _ = assembler.push(character: "1", at: 0)
        _ = assembler.push(character: "0", at: 0.01)
        XCTAssertEqual(assembler.interrupt(), [.dropBurst])
        XCTAssertEqual(assembler.tick(at: 1), [])
    }

    func testMultilineLabelIsOneScan() {
        var assembler = ScanBurstAssembler()
        var time = 0.0
        func type(_ text: String) {
            for character in text {
                _ = assembler.push(character: character, at: time)
                time += 0.01
            }
            _ = assembler.pushTerminator(at: time)
            time += 0.2
        }
        type("19-DKP")
        type("Termos")
        type("V:2")
        XCTAssertEqual(assembler.tick(at: time + 0.6), [.commitIdle("19-DKP\nTermos\nV:2")])
    }

    func testSlowGapInsideLabelStaysOneScan() {
        var assembler = ScanBurstAssembler()
        assembler.idle = 1.2
        var time = 0.0
        func type(_ text: String, pauseAfter: Double) {
            for character in text {
                _ = assembler.pushForced(character: character, at: time)
                time += 0.04
            }
            _ = assembler.pushTerminator(at: time)
            time += pauseAfter
        }
        type("1550-POD", pauseAfter: 0.8)
        type("Nazev k", pauseAfter: 0.8)
        type("01.01.2019", pauseAfter: 0.3)
        type("V:2", pauseAfter: 0)
        XCTAssertEqual(
            assembler.tick(at: time + 1.2),
            [.commitIdle("1550-POD\nNazev k\n01.01.2019\nV:2")]
        )
    }
}
