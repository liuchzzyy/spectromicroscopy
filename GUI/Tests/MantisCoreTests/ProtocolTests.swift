import XCTest
@testable import MantisCore

final class ProtocolTests: XCTestCase {
    func testRejectsBooleanIdentifiersAndNumericStatus() {
        for json in [
            #"{"id":true,"protocol":1,"ok":true,"result":{}}"#,
            #"{"id":1,"protocol":true,"ok":true,"result":{}}"#,
            #"{"id":1,"protocol":1,"ok":1,"result":{}}"#
        ] {
            XCTAssertThrowsError(try Wire.validateResponse(Data(json.utf8), id: 1), json)
        }
    }
    func testRejectsMismatchedID() {
        XCTAssertThrowsError(try Wire.validateResponse(Data(#"{"id":9,"protocol":1,"ok":true,"result":{}}"#.utf8), id: 1))
    }
    func testReportsStructuredEngineError() {
        XCTAssertThrowsError(try Wire.validateResponse(Data(#"{"id":1,"protocol":1,"ok":false,"error":{"code":"invalid_data","message":"Positive transmission required"}}"#.utf8), id: 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Positive transmission required"))
        }
    }
    func testReturnsOnlyResultPayload() throws {
        let result = try Wire.validateResponse(Data(#"{"id":1,"protocol":1,"ok":true,"result":{"source":"synthetic"}}"#.utf8), id: 1)
        let object = try JSONSerialization.jsonObject(with: result) as? [String: String]
        XCTAssertEqual(object?["source"], "synthetic")
    }
    func testRejectsWrongProtocolBeforeAcceptingResult() throws {
        let data = Data(#"{"id":1,"protocol":2,"ok":true,"result":{}}"#.utf8)
        XCTAssertThrowsError(try Wire.validateResponse(data, id: 1))
    }
}
