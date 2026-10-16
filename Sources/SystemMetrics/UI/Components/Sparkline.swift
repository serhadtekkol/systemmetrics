import Charts
import SwiftUI

/// Five-minute trend line. Values are fractions `0...1`, oldest first.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    static let height: CGFloat = 28

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...1)
        .chartXScale(domain: 0...max(1, values.count - 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

#Preview("Sparkline") {
    Sparkline(values: (0..<60).map { 0.4 + 0.3 * sin(Double($0) / 6) }, color: Theme.Load.normal)
        .frame(width: 140)
        .padding()
}
