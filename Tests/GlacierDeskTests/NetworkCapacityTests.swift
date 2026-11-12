import XCTest
@testable import GlacierDesk

final class NetworkCapacityTests: XCTestCase {
    func testParsesUploadCapacityAndRejectsMissingOrZero() throws {
        let measurement = try NetworkCapacityTest.parse(Data(#"{"ul_throughput":125000000,"interface_name":"en0"}"#.utf8))
        XCTAssertEqual(measurement.bitsPerSecond, 125_000_000)
        XCTAssertEqual(measurement.interface, "en0")
        XCTAssertThrowsError(try NetworkCapacityTest.parse(Data(#"{"ul_throughput":0}"#.utf8)))
        XCTAssertThrowsError(try NetworkCapacityTest.parse(Data(#"{}"#.utf8)))
    }
}
