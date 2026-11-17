import Foundation
import SQLite3

/// Read-only view of Wispr Flow's dictation history (`flow.sqlite`, table `History`).
///
/// Wispr delivers a transcript by pasting it into the focused field. The same text is also written
/// here, which gives a second way to pick it up when the paste did not reach the question panel.
public struct WisprHistoryRow: Equatable {
    public var id: String
    public var timestamp: String
    /// "formatted", "raw_transcript", "empty", "no_audio", "dismissed", ... or nil while in progress.
    public var status: String?
    public var text: String

    /// Wispr writes the final status once, after it has pasted (or decided there is nothing to
    /// paste). Until then the row has no status, or "processing".
    public var isFinal: Bool { status != nil && status != "processing" }
}

public enum WisprHistory {

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/Wispr Flow/flow.sqlite"
    }

    /// Wispr stores `timestamp` as `2026-11-15 15:39:10.099 +00:00` (UTC), which sorts as text.
    public static func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date) + " +00:00"
    }

    /// Dictations that started at or after `date`, newest first.
    public static func rows(since date: Date, path: String = defaultPath, limit: Int = 5) -> [WisprHistoryRow] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let sql = """
        SELECT transcriptEntityId, timestamp, status, COALESCE(NULLIF(pastedText, ''), NULLIF(formattedText, ''), asrText, '')
        FROM History WHERE timestamp >= ? ORDER BY timestamp DESC LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, timestampString(date), -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var rows: [WisprHistoryRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func column(_ index: Int32) -> String? {
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            }
            rows.append(WisprHistoryRow(id: column(0) ?? "", timestamp: column(1) ?? "", status: column(2),
                                        text: (column(3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return rows
    }
}
