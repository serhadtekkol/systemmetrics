extension Sequence where Element == UInt64 {
    /// Sum that stops at `UInt64.max` instead of trapping. Used wherever the addends come from
    /// outside the process (Docker daemon JSON): a broken or fake daemon must not be able to
    /// crash the app with an arithmetic overflow.
    var saturatingSum: UInt64 {
        reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }
}
