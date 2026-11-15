import XCTest
@testable import GardenBootCore

final class PlaybackOverviewTests: XCTestCase {
    func testSharedPlaybackStatusPriorities() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("launcher-spec/conformance/overview.json")
        struct Cases: Decodable { let cases: [Case] }
        struct Case: Decodable { let name: String; let input: PlaybackStatusInput; let expect: String }
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: file)).cases
        XCTAssertEqual(cases.count, 18)
        for item in cases {
            XCTAssertEqual(PlaybackStatusReason.resolve(item.input).rawValue, item.expect, item.name)
        }
    }
}
