import Foundation

/// DEBUG-only event log for pack opening latency. Prints each event with the
/// elapsed milliseconds since the trace was reset. The goal is to see exactly
/// where the seconds go between "Rip a Pack" tap and the first card showing,
/// without dragging Instruments into it.
///
/// Read the output top-to-bottom: column 1 is ms-since-reset, column 2 is the
/// event. Gaps between consecutive lines are where time is being spent.
enum PackTiming {
    #if DEBUG
    nonisolated(unsafe) private static var start: Date = .distantPast
    nonisolated(unsafe) private static var lock = NSLock()

    /// Start a fresh trace. Call this when the user taps "Rip a Pack" so
    /// every subsequent `mark` reads as ms-since-tap.
    static func reset(_ label: String = "rip tap") {
        lock.lock()
        start = Date()
        lock.unlock()
        print(String(format: "⏱ ──── %@ ────", label))
        mark("0 reset")
    }

    /// Log an event with elapsed time since the last `reset`.
    static func mark(_ event: String) {
        lock.lock()
        let elapsed = Date().timeIntervalSince(start) * 1000
        lock.unlock()
        print(String(format: "⏱ %6.0fms  %@", elapsed, event))
    }
    #else
    static func reset(_ label: String = "") {}
    static func mark(_ event: String) {}
    #endif
}
