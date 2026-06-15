import XCTest
import Foundation
@testable import StrandAnalytics

final class SleepWindowReclipTests: XCTestCase {

    private func segments(_ json: String) -> [(start: Int, end: Int, stage: String)] {
        let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        return arr.compactMap {
            guard let s = ($0["start"] as? NSNumber)?.intValue,
                  let e = ($0["end"] as? NSNumber)?.intValue,
                  let st = $0["stage"] as? String else { return nil }
            return (s, e, st)
        }
    }

    private func minutes(_ json: String) -> [String: Double] {
        let dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return dict.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    // MARK: - segment array (computed nights)

    func testSegmentTrimDropsAndClips() throws {
        let json = """
        [{"start":1000,"end":2000,"stage":"light"},
         {"start":2000,"end":3000,"stage":"deep"},
         {"start":3000,"end":4000,"stage":"wake"}]
        """
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 1000, oldEnd: 4000, newEnd: 2500))
        let segs = segments(out)
        XCTAssertEqual(segs.count, 2, "the wholly-after segment is dropped")
        XCTAssertEqual(segs[0].stage, "light")
        XCTAssertEqual(segs[1].stage, "deep")
        XCTAssertEqual(segs[1].end, 2500, "the segment spanning the new wake is clipped to it")
    }

    func testSegmentExtendAppendsTrailingWake() throws {
        let json = """
        [{"start":1000,"end":2000,"stage":"light"},
         {"start":2000,"end":3000,"stage":"deep"}]
        """
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 1000, oldEnd: 3000, newEnd: 3600))
        let segs = segments(out)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs.last?.stage, "wake")
        XCTAssertEqual(segs.last?.start, 3000)
        XCTAssertEqual(segs.last?.end, 3600)
    }

    // MARK: - minute dict (imported nights)

    func testMinutesTrimCascadesFromAwakeThenLight() throws {
        // Shorten by 40 min: awake (30) → 0 and the remaining 10 comes off light.
        let json = #"{"awake":30,"light":200,"deep":80,"rem":90}"#
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 0, oldEnd: 8 * 3600, newEnd: 8 * 3600 - 40 * 60))
        let m = minutes(out)
        XCTAssertEqual(try XCTUnwrap(m["awake"]), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["light"]), 190, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["deep"]), 80, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["rem"]), 90, accuracy: 0.001)
    }

    func testMinutesExtendAddsToAwake() throws {
        let json = #"{"awake":30,"light":200,"deep":80,"rem":90}"#
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 0, oldEnd: 8 * 3600, newEnd: 8 * 3600 + 20 * 60))
        let m = minutes(out)
        XCTAssertEqual(try XCTUnwrap(m["awake"]), 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["light"]), 200, accuracy: 0.001)
    }

    func testSegmentTrimBeforeAllSegmentsReturnsWakeFillNotNil() throws {
        // Corrected wake lands before every stage → instead of returning nil (which would let the store's
        // COALESCE keep the OLD stages extending PAST the new wake), emit a single wake segment that
        // covers exactly the corrected window. (#318 review #8)
        let json = """
        [{"start":2000,"end":3000,"stage":"light"},{"start":3000,"end":4000,"stage":"deep"}]
        """
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 1000, oldEnd: 4000, newEnd: 1500))
        let segs = segments(out)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].stage, "wake")
        XCTAssertEqual(segs.map { $0.end }.max(), 1500, "no stage extends past the corrected wake")
    }

    // MARK: - degenerate input

    func testNilAndGarbageReturnNil() {
        XCTAssertNil(SleepWindowReclip.reclip(stagesJSON: nil, sessionStart: 0, oldEnd: 1, newEnd: 1))
        XCTAssertNil(SleepWindowReclip.reclip(stagesJSON: "not json", sessionStart: 0, oldEnd: 1, newEnd: 1))
    }
}
