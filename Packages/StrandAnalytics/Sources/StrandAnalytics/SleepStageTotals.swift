import Foundation

/// Decode a sleep session's `stagesJSON` (either the on-device segment array `[{start,end,stage}]` or
/// the imported minute dict `{light,deep,rem,awake}`) into stage MINUTE totals, and aggregate a night's
/// blocks into the sleep-derived daily fields. Pure + deterministic, so the daily-aggregate recompute
/// that honors a user's wake-time edit can run off the stored (reshaped) stages — no raw streams needed.
public enum SleepStageTotals {

    public struct Minutes: Equatable {
        public var awake: Double, light: Double, deep: Double, rem: Double
        public var asleep: Double { light + deep + rem }
        public var inBed: Double { asleep + awake }
        public init(awake: Double = 0, light: Double = 0, deep: Double = 0, rem: Double = 0) {
            self.awake = awake; self.light = light; self.deep = deep; self.rem = rem
        }
    }

    /// Stage minutes for one session's `stagesJSON`, or nil if it decodes to nothing usable. The on-device
    /// stager calls awake "wake"; the importer "awake" — both map to `awake`.
    public static func minutes(fromStagesJSON json: String?) -> Minutes? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [[String: Any]] {                 // segment array (computed)
            var m = Minutes()
            for seg in arr {
                guard let s = (seg["start"] as? NSNumber)?.intValue,
                      let e = (seg["end"] as? NSNumber)?.intValue, e > s,
                      let name = seg["stage"] as? String else { continue }
                let mins = Double(e - s) / 60.0
                switch name {
                case "wake", "awake": m.awake += mins
                case "light": m.light += mins
                case "deep": m.deep += mins
                case "rem": m.rem += mins
                default: continue
                }
            }
            return m.inBed > 0 ? m : nil
        }
        if let dict = obj as? [String: Any] {                  // minute dict (imported)
            func v(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
            let m = Minutes(awake: v("awake"), light: v("light"), deep: v("deep"), rem: v("rem"))
            return m.inBed > 0 ? m : nil
        }
        return nil
    }

    /// The sleep-derived daily fields for a night made of these blocks' `stagesJSON`, or nil if none
    /// decode. `efficiency` is asleep / in-bed (TST / Σ stage minutes) in [0,1]. For the segment stages
    /// noop stores (which TILE the window, last segment clamped to the wake), Σ stage minutes equals the
    /// clock span, so this coincides with `AnalyticsEngine.analyzeDay`'s TST/(end−start); it is not the
    /// literal same expression, and would diverge only for malformed non-tiling stages.
    public struct DailySleep: Equatable {
        public let totalSleepMin: Double, efficiency: Double
        public let deepMin: Double, remMin: Double, lightMin: Double
    }

    public static func dailyAggregate(_ stagesJSONs: [String?]) -> DailySleep? {
        var total = Minutes()
        var any = false
        for j in stagesJSONs {
            if let m = minutes(fromStagesJSON: j) {
                total.awake += m.awake; total.light += m.light
                total.deep += m.deep; total.rem += m.rem
                any = true
            }
        }
        guard any, total.inBed > 0 else { return nil }
        return DailySleep(totalSleepMin: total.asleep, efficiency: total.asleep / total.inBed,
                          deepMin: total.deep, remMin: total.rem, lightMin: total.light)
    }

    /// The night's daily sleep aggregate, substituting any USER-EDITED block for its detected twin
    /// before summing. `detected` is the auto-detected blocks (their stable startTs + stages); `edited`
    /// maps a block's startTs → its hand-corrected (reshaped) stages. A wake-time edit never moves
    /// startTs, so the edited block lands exactly on its detected twin. Returns the aggregate plus
    /// whether an edit actually applied (so the caller only overrides the day when it did), or nil when
    /// nothing decodes. This is the integration seam between the edit and the daily recompute — kept
    /// pure so it's unit-tested with synthetic data, no store or stager needed.
    public static func dailyAggregateHonoringEdits(
        detected: [(startTs: Int, stagesJSON: String?)],
        edited: [Int: String?]
    ) -> (sleep: DailySleep, editApplied: Bool)? {
        // Substitute an edited block's stages ONLY when the edit has usable (non-nil) stages — an edit
        // that reshaped to nil must fall back to the detected stages, never drop the block (which would
        // collapse the night's sleep total). `editApplied` likewise reflects a real substitution.
        var applied = false
        let effective: [String?] = detected.map { d in
            if let stages = edited[d.startTs] ?? nil {   // flatten String?? → String?, then require non-nil
                applied = true
                return stages
            }
            return d.stagesJSON
        }
        guard let agg = dailyAggregate(effective) else { return nil }
        return (agg, applied)
    }
}
