import Foundation

/// Assembles the Test Centre export bundle: gathers report.txt, meta.json, raw-capture and last-crash,
/// runs the redaction pass over EVERY file, applies the 20 MB cap, and hands the entries to
/// FileExport.exportBundle. This is the orchestrator behind the Report button.
///
/// The CRITICAL fix (spec section 5.3): today only the append(log:) sink scrubs (LiveState.swift:308),
/// so a serial embedded in raw-capture console text would ship unredacted. We re-run LiveState.redactPii
/// over every entry's text here, the single scrub point, and stamp meta.redaction = "v2" so a maintainer
/// can trust the scrub. Redaction stays the only scrub point; we just guarantee it covers the whole bundle.
enum TestBundleAssembler {

    /// The redaction stamp written into meta.json so a maintainer knows the whole-bundle scrub ran.
    static let redactionVersion = "v2"

    /// Re-run the redaction sink over every entry. Text entries are decoded as UTF-8, scrubbed via the same
    /// LiveState.redactPii used by the live sink, and re-encoded. A non-UTF-8 entry (none today) passes
    /// through untouched rather than risk corrupting binary. meta.json and report.txt have no PII shapes so
    /// they pass through byte-identical; raw-capture is where the embedded serials live.
    static func redactEntries(_ entries: [FileExport.BundleEntry]) -> [FileExport.BundleEntry] {
        entries.map { entry in
            guard let text = String(data: entry.data, encoding: .utf8) else { return entry }
            let scrubbed = LiveState.redactPii(text)
            return FileExport.BundleEntry(name: entry.name, data: Data(scrubbed.utf8))
        }
    }

    /// Hard cap the bundle at `capBytes` (20 MB default, under GitHub's 25 MB; spec section 5.4). The
    /// strap-log tail is already bounded, so only raw-capture can exceed. We keep the MOST-RECENT tail of
    /// raw-capture.jsonl (newest data is the most diagnostic) and trim from the front. Returns the capped
    /// entries plus whether any truncation happened, which the caller writes to meta.truncated.
    static func capEntries(_ entries: [FileExport.BundleEntry],
                           capBytes: Int = 20 * 1024 * 1024) -> (entries: [FileExport.BundleEntry], truncated: Bool) {
        let total = entries.reduce(0) { $0 + $1.data.count }
        guard total > capBytes else { return (entries, false) }
        // Budget for everything that is NOT raw-capture (kept whole), then give raw-capture the remainder.
        let rawName = "raw-capture.jsonl"
        let nonRaw = entries.filter { $0.name != rawName }.reduce(0) { $0 + $1.data.count }
        let budget = max(0, capBytes - nonRaw)
        var truncated = false
        let capped = entries.map { entry -> FileExport.BundleEntry in
            guard entry.name == rawName, entry.data.count > budget else { return entry }
            truncated = true
            // Keep the tail (most recent): the last `budget` bytes.
            let tail = entry.data.suffix(budget)
            return FileExport.BundleEntry(name: entry.name, data: Data(tail))
        }
        return (capped, truncated)
    }
}
