import Testing
import Foundation
@testable import MetricsKit

struct FormattersTests {
    @Test func percentIsNumberThenSign() {
        #expect(Formatters.percent(0.234) == "23%")
        #expect(Formatters.percent(0) == "0%")
        #expect(Formatters.percent(1.2) == "100%")
        #expect(Formatters.percent(-0.5) == "0%")
        #expect(Formatters.percent(.nan) == "0%")
    }
    /// Turkish decimal comma like the byte sizes next to it ("20,2 GB"), number then sign.
    @Test func cpuPercent() {
        #expect(Formatters.cpuPercent(2.54) == "2,5%")
        #expect(Formatters.cpuPercent(5) == "5,0%")
        #expect(Formatters.cpuPercent(42.6) == "43%")
        #expect(Formatters.cpuPercent(250) == "250%")
        #expect(Formatters.cpuPercent(0) == "0,0%")
        #expect(Formatters.cpuPercent(-3) == "0,0%")
        #expect(Formatters.cpuPercent(.nan) == "0,0%")
    }
    /// A broken or hostile Docker daemon can drive the value past `Int.max`; `Int(p.rounded())`
    /// used to trap there.
    @Test func cpuPercentDoesNotTrapOnHugeValues() {
        for v in [9.3e18, 1e300, Double.greatestFiniteMagnitude, .infinity] {
            #expect(Formatters.cpuPercent(v).hasSuffix("%"))
        }
    }
    @Test func uptime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatters.uptime(since: now.addingTimeInterval(-(3 * 86_400 + 4 * 3_600 + 60)), now: now) == "3g 4s")
        #expect(Formatters.uptime(since: now.addingTimeInterval(-(4 * 3_600 + 12 * 60)), now: now) == "4s 12dk")
        #expect(Formatters.uptime(since: now.addingTimeInterval(-(12 * 60)), now: now) == "12dk")
        #expect(Formatters.uptime(since: now.addingTimeInterval(60), now: now) == "0dk")   // boot time in the future
    }
    @Test func rateHasPerSecondSuffix() {
        #expect(Formatters.rate(12_000_000).hasSuffix("/s"))
        #expect(Formatters.rate(-1) == Formatters.rate(0))
    }
    /// Below 1 kB `ByteCountFormatStyle` spells the unit out, and in the app bundle (no tr
    /// localization) it came out English: "0 bytes/s". Sub-kB values use the unit symbol "B"
    /// so they read like the "kB/s", "MB/s" around them and never contain an English word.
    @Test func subKilobyteValuesUseUnitSymbolNotEnglishWord() {
        #expect(Formatters.rate(0) == "0 B/s")
        #expect(Formatters.rate(512.4) == "512 B/s")
        #expect(Formatters.rate(.nan) == "0 B/s")
        #expect(Formatters.bytes(0) == "0 B")
        #expect(Formatters.bytes(1_000) == "1000 B")
        #expect(Formatters.diskBytes(999) == "999 B")
        for s in [Formatters.rate(0), Formatters.bytes(5), Formatters.diskBytes(5)] {
            #expect(!s.contains("byte") && !s.contains("bayt"), "\(s)")
        }
        #expect(Formatters.rate(12_000) == "12 kB/s")
    }
    @Test func bytesUseTurkishDecimalCommaRegardlessOfUserLocale() {
        // 1.5 GiB in memory style (binary) and 1.5 GB in file style (decimal).
        #expect(Formatters.bytes(1_610_612_736).contains("1,5"))
        #expect(Formatters.diskBytes(1_500_000_000).contains("1,5"))
        #expect(Formatters.bytes(1_610_612_736).hasSuffix("GB"))
    }
}
