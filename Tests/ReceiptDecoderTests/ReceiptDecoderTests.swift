import XCTest
@testable import ReceiptDecoder

final class ReceiptDecoderTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(ReceiptDecoder().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
