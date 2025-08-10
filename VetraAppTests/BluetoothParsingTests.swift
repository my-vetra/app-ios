import XCTest
@testable import VetraApp

final class BluetoothParsingTests: XCTestCase {

    private func makePuffsBatch(first: UInt16, nums: [UInt16]) -> Data {
        var d = Data([0x01])
        d.append(contentsOf: [UInt8(first & 0xff), UInt8(first >> 8)])
        d.append(UInt8(nums.count))
        for n in nums {
            // Puff: u16 puffNumber, u32 ts, u16 dur_ms, u8 phaseIndex
            d.append(contentsOf: [UInt8(n & 0xff), UInt8(n >> 8)])
            d.append(contentsOf: [0xEF,0xBE,0xAD,0xDE]) // 0xDEADBEEF
            d.append(contentsOf: [0xE8,0x03])           // 1000 ms
            d.append(2)                                  // phaseIndex
        }
        return d
    }

    func testParsePuffsBatch_ok() {
        let data = makePuffsBatch(first: 1, nums: [1,2,3])
        let items = BluetoothManager.parsePuffsBatch(data)
        XCTAssertNotNil(items)
        XCTAssertEqual(items?.count, 3)
        XCTAssertEqual(items?.first?.puffNumber, 1)
        XCTAssertEqual(items?.last?.phaseIndex, 2)
    }

    func testParsePuffsBatch_badLength_returnsNil() {
        var data = makePuffsBatch(first: 1, nums: [1,2])
        data.removeLast() // break the size
        XCTAssertNil(BluetoothManager.parsePuffsBatch(data))
    }

    func testParseActivePhase_ok() {
        var d = Data()
        d.append(2) // phaseIndex
        d.append(contentsOf: [0xEF,0xBE,0xAD,0xDE]) // ts
        let ap = BluetoothManager.parseActivePhase(d)
        XCTAssertNotNil(ap)
        XCTAssertEqual(ap?.phaseIndex, 2)
    }
}
