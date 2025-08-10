import XCTest
@testable import VetraApp

final class BluetoothParsingFuzzTests: XCTestCase {

    private func makePuff(_ n: UInt16, ts: UInt32, dur: UInt16, phase: UInt8) -> Data {
        var d = Data()
        d.append(contentsOf: [UInt8(n & 0xff), UInt8(n >> 8)])
        d.append(contentsOf: [UInt8(ts & 0xff), UInt8((ts>>8)&0xff), UInt8((ts>>16)&0xff), UInt8((ts>>24)&0xff)])
        d.append(contentsOf: [UInt8(dur & 0xff), UInt8(dur >> 8)])
        d.append(phase)
        return d
    }

    private func makeBatch(first: UInt16, puffs: [Data]) -> Data {
        var d = Data([0x01])
        d.append(contentsOf: [UInt8(first & 0xff), UInt8(first >> 8)])
        d.append(UInt8(puffs.count))
        for p in puffs { d.append(p) }
        return d
    }

    func testUnknownMessageTypeReturnsNil() {
        let data = Data([0x7F, 0x00])
        // call the private handler path via parse functions; here just ensure batch parser rejects:
        XCTAssertNil(BluetoothManager.parsePuffsBatch(data))
    }

    func testTruncatedBatchReturnsNil() {
        let p = makePuff(1, ts: 0, dur: 1, phase: 0)
        var d = makeBatch(first: 1, puffs: [p, p])
        d.removeLast() // truncate
        XCTAssertNil(BluetoothManager.parsePuffsBatch(d))
    }

    func testExtremeValues() {
        let p = makePuff(.max, ts: .max, dur: .max, phase: .max)
        let d = makeBatch(first: .max, puffs: [p])
        let items = BluetoothManager.parsePuffsBatch(d)!
        XCTAssertEqual(items[0].puffNumber, Int(UInt16.max))
        XCTAssertEqual(items[0].duration, TimeInterval(UInt16.max) / 1000.0)
        XCTAssertEqual(items[0].phaseIndex, Int(UInt8.max))
    }

    func testFuzzSmallBatches() {
        for n in 1...50 {
            var puffBlobs: [Data] = []
            for i in 0..<n {
                puffBlobs.append(makePuff(UInt16(i+1), ts: 123456 + UInt32(i), dur: 1000, phase: 2))
            }
            let d = makeBatch(first: 1, puffs: puffBlobs)
            let items = BluetoothManager.parsePuffsBatch(d)!
            XCTAssertEqual(items.count, n)
            XCTAssertEqual(items.first?.puffNumber, 1)
            XCTAssertEqual(items.last?.puffNumber, n)
        }
    }

    func testParseActivePhaseEdge() {
        // exactly 5 bytes
        let d = Data([3, 0x11, 0x22, 0x33, 0x44])
        let ap = BluetoothManager.parseActivePhase(d)!
        XCTAssertEqual(ap.phaseIndex, 3)
        XCTAssertEqual(ap.phaseStartDate, Date(timeIntervalSince1970: TimeInterval(0x44332211)))
    }
}
