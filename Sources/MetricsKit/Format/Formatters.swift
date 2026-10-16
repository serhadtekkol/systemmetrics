import Foundation

/// Display strings for the UI. Numbers are always Turkish-formatted (`1,5 GB`, `2,5%`)
/// regardless of the user's system locale, because all UI copy is Turkish; percentages are
/// built by hand as `23%` (number then sign) since the `tr_TR` percent style would print `%23`.
///
/// Byte values below one kilobyte are written as `"512 B"` by hand: for that range
/// `ByteCountFormatStyle` spells the unit out, and the word comes from the *app bundle's*
/// localizations, not from the `locale` passed in — the app has no Turkish `.lproj`, so it
/// printed "0 bytes/s". `B` matches the `kB`/`MB`/`GB` symbols the style uses above 1 kB.
///
/// Every function tolerates NaN, infinity, negative and huge input and never traps.
public enum Formatters {
    private static let locale = Locale(identifier: "tr_TR")
    /// Upper clamp before any `Double` → `Int` conversion; far above any real reading
    /// (1024 CPUs × 100%), far below `Int.max`, where the conversion would trap.
    private static let maxDisplayedValue = 1e12
    private static let memoryStyle = ByteCountFormatStyle(style: .memory, allowedUnits: .all, spellsOutZero: false,
                                                          includesActualByteCount: false, locale: locale)
    private static let fileStyle = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                                        includesActualByteCount: false, locale: locale)

    /// Fraction 0...1 → `"23%"`. Out-of-range values clamp; non-finite values show `0%`.
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// Docker-style percent of one core (may exceed 100) → `"2,5%"` below 10, else `"43%"`.
    /// Turkish decimal comma, like the byte sizes shown next to it. Non-finite and negative
    /// input shows `"0,0%"`; values from a broken daemon are clamped instead of trapping.
    public static func cpuPercent(_ percent: Double) -> String {
        let clamped = percent.isFinite ? min(max(0, percent), maxDisplayedValue) : 0
        // Round to the shown precision first so 9.96 becomes "10%", not "10,0%".
        let p = (clamped * 10).rounded() / 10
        return p < 10 ? p.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "%"
                      : "\(Int(p.rounded()))%"
    }

    /// vCPU count with one Turkish decimal: `0.83` → `"0,8"`, `12.4` → `"12,4"`.
    public static func cores(_ value: Double) -> String {
        let v = value.isFinite ? min(max(0, value), 1e6) : 0
        return v.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// Memory sizes, binary units (`1,5 GB` for 1.5 GiB) like Activity Monitor.
    /// Below 1 KiB: `"512 B"` (the style itself switches to kB at 1023 bytes).
    public static func bytes(_ value: UInt64) -> String {
        value < 1_023 ? "\(value) B" : Int64(clamping: value).formatted(memoryStyle)
    }

    /// Disk sizes, decimal units like Finder. Below 1 kB: `"512 B"`.
    public static func diskBytes(_ value: UInt64) -> String {
        value < 1_000 ? "\(value) B" : Int64(clamping: value).formatted(fileStyle)
    }

    /// Throughput → `"12 MB/s"`, `"0 B/s"` (decimal units). Negative or non-finite input shows as zero.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let v = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        return diskBytes(UInt64(min(v, Double(Int64.max / 2)))) + "/s"
    }

    /// Compact Turkish uptime: `"3g 4s"` (days, hours), `"4s 12dk"` (hours, minutes) or `"12dk"`.
    /// A boot time in the future (clock change) shows `"0dk"`.
    public static func uptime(since boot: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(boot) / 60))
        let d = minutes / 1_440, h = (minutes % 1_440) / 60, m = minutes % 60
        if d > 0 { return "\(d)g \(h)s" }
        if h > 0 { return "\(h)s \(m)dk" }
        return "\(m)dk"
    }
}
