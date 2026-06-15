import Foundation
import GRDB

// MARK: - Offline cache of SERVER-computed metrics (Task 3.1 → M0.4)
// This file is purely a local cache of values computed by the server — the phone does NO metric
// computation here. DailyMetric and CachedSleepSession mirror the server's daily_metrics /
// sleep_sessions tables and are cached locally so History = union(phone-collected raw streams,
// server-computed derived metrics). ServerSync.pull() populates this cache; MetricsRepository
// reads it for the view layer.

/// One cached sleep session pulled from the server's /v1/sleep. Natural key (deviceId, startTs).
/// `stagesJSON` is the verbatim JSON array of stage segments ([{start,end,stage}]) — stored as a
/// string so the cache stays schema-agnostic about the staging shape.
public struct CachedSleepSession: Equatable, Codable {
    public let startTs: Int          // unix seconds
    public let endTs: Int            // unix seconds
    public let efficiency: Double?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let stagesJSON: String?
    /// True once the user has hand-corrected this session's wake/sleep bounds. The recompute/import
    /// upsert preserves an edited session's `endTs`/`stagesJSON` instead of overwriting them with the
    /// strap-detected values (see `upsertSleepSessions`). Defaults false so every cache/recompute path
    /// that doesn't know about edits keeps producing un-edited rows.
    public let userEdited: Bool
    /// The user's hand-corrected sleep ONSET, or nil when the onset wasn't edited. `startTs` remains the
    /// immutable detected key; display + re-staging use `effectiveStartTs`. (#318)
    public let startTsAdjusted: Int?
    /// The onset to display / stage from: the user's correction if present, else the detected `startTs`.
    public var effectiveStartTs: Int { startTsAdjusted ?? startTs }
    public init(startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?,
                avgHrv: Double?, stagesJSON: String?, userEdited: Bool = false,
                startTsAdjusted: Int? = nil) {
        self.startTs = startTs; self.endTs = endTs
        self.efficiency = efficiency; self.restingHr = restingHr
        self.avgHrv = avgHrv; self.stagesJSON = stagesJSON
        self.userEdited = userEdited
        self.startTsAdjusted = startTsAdjusted
    }
}

/// One cached daily-metrics row pulled from the server's /v1/daily. Natural key (deviceId, day).
public struct DailyMetric: Equatable, Codable {
    public let day: String           // YYYY-MM-DD
    public let totalSleepMin: Double?
    public let efficiency: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let lightMin: Double?
    public let disturbances: Int?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let recovery: Double?
    public let strain: Double?
    public let exerciseCount: Int?
    // In-sleep signal aggregates (v7 columns). All nullable; computed server-side.
    public let spo2Pct: Double?        // mean SpO2 (%) during sleep
    public let skinTempDevC: Double?   // skin-temperature deviation (°C) from baseline
    public let respRateBpm: Double?    // mean respiration rate (breaths/min) during sleep
    // On-device daily activity totals (v11 columns, APPROXIMATE estimates). Both nullable, so
    // imported/cloud rows that never carry them stay nil and old call sites are unaffected.
    public let steps: Int?             // daily step total from the cumulative @57 counter
    public let activeKcalEst: Double?  // whole-day HR-only calorie estimate (kcal)
    public init(day: String, totalSleepMin: Double?, efficiency: Double?, deepMin: Double?,
                remMin: Double?, lightMin: Double?, disturbances: Int?, restingHr: Int?,
                avgHrv: Double?, recovery: Double?, strain: Double?, exerciseCount: Int?,
                spo2Pct: Double? = nil, skinTempDevC: Double? = nil, respRateBpm: Double? = nil,
                steps: Int? = nil, activeKcalEst: Double? = nil) {
        self.day = day; self.totalSleepMin = totalSleepMin; self.efficiency = efficiency
        self.deepMin = deepMin; self.remMin = remMin; self.lightMin = lightMin
        self.disturbances = disturbances; self.restingHr = restingHr; self.avgHrv = avgHrv
        self.recovery = recovery; self.strain = strain; self.exerciseCount = exerciseCount
        self.spo2Pct = spo2Pct; self.skinTempDevC = skinTempDevC; self.respRateBpm = respRateBpm
        self.steps = steps; self.activeKcalEst = activeKcalEst
    }
}

extension WhoopStore {

    // MARK: - Upserts (idempotent by natural key; latest server value wins on conflict)

    /// Upsert cached sleep sessions. Natural key (deviceId, startTs). Returns rows changed.
    @discardableResult
    public func upsertSleepSessions(_ sessions: [CachedSleepSession], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for s in sessions {
                try db.execute(sql: """
                    INSERT INTO sleepSession
                        (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                         userEdited, startTsAdjusted)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        -- A user-corrected night keeps its hand-set bed/wake times and stage breakdown;
                        -- a recompute/import refresh (this path) updates only the derived vitals. The
                        -- `userEdited` flag is preserved, never cleared here, so a later strap re-sync
                        -- can't revert a correction (the dedicated edit path is `applySleepEdit`).
                        endTs = CASE WHEN sleepSession.userEdited THEN sleepSession.endTs ELSE excluded.endTs END,
                        efficiency = excluded.efficiency,
                        restingHr = excluded.restingHr,
                        avgHrv = excluded.avgHrv,
                        stagesJSON = CASE WHEN sleepSession.userEdited THEN sleepSession.stagesJSON ELSE excluded.stagesJSON END,
                        startTsAdjusted = CASE WHEN sleepSession.userEdited THEN sleepSession.startTsAdjusted ELSE excluded.startTsAdjusted END,
                        userEdited = sleepSession.userEdited
                    """, arguments: [deviceId, s.startTs, s.endTs, s.efficiency,
                                     s.restingHr, s.avgHrv, s.stagesJSON, s.userEdited, s.startTsAdjusted])
                n += db.changesCount
            }
            return n
        }
    }

    /// Hand-correct a sleep session's bed (onset) and/or wake (end) time. Sets `userEdited = 1` so the
    /// next recompute/import `upsertSleepSessions` preserves the corrected bounds instead of overwriting
    /// them with the strap-detected values. Keyed by the stable detected natural key
    /// (deviceId, `detectedStartTs`) — which never moves; the corrected onset is stored in
    /// `startTsAdjusted`. `newStartTs == detectedStartTs` leaves the onset effectively unchanged.
    /// `stagesJSON`, when non-nil, replaces the stored breakdown (the caller re-derives it for the new
    /// window via `SleepStager.stageSession`, falling back to `SleepWindowReclip`); nil keeps the
    /// existing stages. Returns rows changed (0 if no such session).
    @discardableResult
    public func applySleepEdit(deviceId: String, detectedStartTs: Int, newStartTs: Int, newEndTs: Int,
                               stagesJSON: String? = nil) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession
                SET startTsAdjusted = ?, endTs = ?, stagesJSON = COALESCE(?, stagesJSON), userEdited = 1
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [newStartTs, newEndTs, stagesJSON, deviceId, detectedStartTs])
            return db.changesCount
        }
    }

    /// Upsert cached daily metrics. Natural key (deviceId, day). Returns rows changed.
    @discardableResult
    public func upsertDailyMetrics(_ days: [DailyMetric], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for d in days {
                try db.execute(sql: """
                    INSERT INTO dailyMetric
                        (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                         disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                         spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET
                        totalSleepMin = excluded.totalSleepMin,
                        efficiency = excluded.efficiency,
                        deepMin = excluded.deepMin,
                        remMin = excluded.remMin,
                        lightMin = excluded.lightMin,
                        disturbances = excluded.disturbances,
                        restingHr = excluded.restingHr,
                        avgHrv = excluded.avgHrv,
                        recovery = excluded.recovery,
                        strain = excluded.strain,
                        exerciseCount = excluded.exerciseCount,
                        spo2Pct = excluded.spo2Pct,
                        skinTempDevC = excluded.skinTempDevC,
                        respRateBpm = excluded.respRateBpm,
                        steps = excluded.steps,
                        activeKcalEst = excluded.activeKcalEst
                    """, arguments: [deviceId, d.day, d.totalSleepMin, d.efficiency, d.deepMin,
                                     d.remMin, d.lightMin, d.disturbances, d.restingHr, d.avgHrv,
                                     d.recovery, d.strain, d.exerciseCount,
                                     d.spo2Pct, d.skinTempDevC, d.respRateBpm,
                                     d.steps, d.activeKcalEst])
                n += db.changesCount
            }
            return n
        }
    }

    /// Delete a source's cached daily rows whose day-key is in [from, to] (inclusive, yyyy-MM-dd
    /// lexicographic = chronological). The #277 local-day re-bucketing migration uses this to drop
    /// the computed ("-noop") UTC-keyed rows across the recompute window before re-upserting the
    /// LOCAL-keyed rows, so a UTC/local duplicate day can't linger. Source-scoped, so imported
    /// "my-whoop" rows are never touched. Returns rows deleted. Mirrors Android
    /// WhoopDao.deleteComputedDailyInRange.
    @discardableResult
    public func deleteDailyMetrics(deviceId: String, from: String, to: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])
            return db.changesCount
        }
    }

    // MARK: - Reads

    /// Cached sleep sessions overlapping [from, to] (by startTs), oldest first.
    public func sleepSessions(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [CachedSleepSession] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited,
                       startTsAdjusted FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map {
                    CachedSleepSession(startTs: $0["startTs"], endTs: $0["endTs"],
                                       efficiency: $0["efficiency"], restingHr: $0["restingHr"],
                                       avgHrv: $0["avgHrv"], stagesJSON: $0["stagesJSON"],
                                       userEdited: $0["userEdited"], startTsAdjusted: $0["startTsAdjusted"])
                }
        }
    }

    /// Cached daily metrics for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest first.
    public func dailyMetrics(deviceId: String, from: String, to: String) async throws -> [DailyMetric] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
                       restingHr, avgHrv, recovery, strain, exerciseCount,
                       spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to])
                .map {
                    DailyMetric(day: $0["day"], totalSleepMin: $0["totalSleepMin"],
                                efficiency: $0["efficiency"], deepMin: $0["deepMin"],
                                remMin: $0["remMin"], lightMin: $0["lightMin"],
                                disturbances: $0["disturbances"], restingHr: $0["restingHr"],
                                avgHrv: $0["avgHrv"], recovery: $0["recovery"],
                                strain: $0["strain"], exerciseCount: $0["exerciseCount"],
                                spo2Pct: $0["spo2Pct"], skinTempDevC: $0["skinTempDevC"],
                                respRateBpm: $0["respRateBpm"],
                                steps: $0["steps"], activeKcalEst: $0["activeKcalEst"])
                }
        }
    }
}
