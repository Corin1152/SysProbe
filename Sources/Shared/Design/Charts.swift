import Charts
import SwiftUI

/// Rolling three-minute view of adapter power against battery power. The area is
/// what comes in; the line is what reaches the cell.
struct LivePowerChart: View {
    let samples: [LiveSample]
    var height: CGFloat = 130

    private var ceiling: Double {
        let peak = samples.flatMap { [$0.inputWatts, $0.batteryWatts] }.filter(\.isFinite).max() ?? 0
        return max(peak * 1.25, 5)
    }

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("Time", sample.date),
                         y: .value("Watts", sample.inputWatts))
                    .foregroundStyle(LinearGradient(colors: [Color.mwAccent.opacity(0.45), Color.mwAccent.opacity(0.02)],
                                                    startPoint: .top,
                                                    endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date),
                         y: .value("Watts", sample.inputWatts),
                         series: .value("Series", String(localized: "From charger")))
                    .foregroundStyle(Color.mwAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date),
                         y: .value("Watts", sample.batteryWatts),
                         series: .value("Series", String(localized: "Into battery")))
                    .foregroundStyle(Color.mwBattery)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let watts = value.as(Double.self) {
                        Text(verbatim: "\(Int(watts))W").mwMono(size: 9).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .clipped()
    }
}

/// Power over the length of a finished session, plotted against elapsed time.
struct SessionPowerChart: View {
    let samples: [ChargeSample]
    var height: CGFloat = 150

    private var ceiling: Double {
        max((samples.map(\.inputWatts).filter(\.isFinite).max() ?? 0) * 1.2, 5)
    }

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("Elapsed", sample.offset),
                         y: .value("Watts", sample.inputWatts))
                    .foregroundStyle(LinearGradient(colors: [Color.mwAccent.opacity(0.4), Color.mwAccent.opacity(0.02)],
                                                    startPoint: .top,
                                                    endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            ForEach(samples) { sample in
                LineMark(x: .value("Elapsed", sample.offset),
                         y: .value("Watts", sample.inputWatts),
                         series: .value("Series", "From charger"))
                    .foregroundStyle(Color.mwAccent)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.monotone)
            }
            ForEach(samples) { sample in
                LineMark(x: .value("Elapsed", sample.offset),
                         y: .value("Watts", sample.batteryWatts),
                         series: .value("Series", "Into battery"))
                    .foregroundStyle(Color.mwBattery)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .interpolationMethod(.monotone)
            }
            // Shade the stretches where iOS was thermally throttling, which is
            // where the curve usually falls off a cliff.
            ForEach(samples.filter(\.throttled)) { sample in
                RectangleMark(x: .value("Elapsed", sample.offset),
                              yStart: .value("Watts", 0),
                              yEnd: .value("Watts", ceiling),
                              width: .fixed(2))
                    .foregroundStyle(Color.mwDanger.opacity(0.12))
            }
        }
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(Formatting.duration(seconds)).mwMono(size: 9).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let watts = value.as(Double.self) {
                        Text(verbatim: "\(Int(watts))W").mwMono(size: 9).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .clipped()
    }
}

/// Battery percentage and temperature over a session, as two panes on one shared
/// time axis.
///
/// They used to share a Y axis as well, which was wrong: the axis was labelled
/// 0–100 for the percentage, so a 38 °C cell was drawn at the "38 %" gridline, and
/// a whole charge's worth of temperature — thirty-something to forty-something —
/// was squeezed into a tenth of the plot and read as a flat line. Two panes cost a
/// little height and let the temperature have a scale it can actually move on.
struct SessionClimateChart: View {
    let samples: [ChargeSample]
    var height: CGFloat = 150

    private var xDomain: ClosedRange<Double> {
        let last = samples.last?.offset ?? 0
        return 0...max(last, 1)
    }

    private var temperatures: [ChargeSample] {
        samples.filter { $0.batteryTemperature != nil }
    }

    private var temperatureDomain: ClosedRange<Double> {
        let values = temperatures.compactMap(\.batteryTemperature)
        guard let low = values.min(), let high = values.max() else { return 20...45 }
        let padding = max((high - low) * 0.2, 1)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart(samples) { sample in
                LineMark(x: .value("Elapsed", sample.offset),
                         y: .value("Percent", Double(sample.percent)))
                    .foregroundStyle(Color.mwWireless)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.mwGrid)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Color.mwGrid)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(verbatim: "\(Int(number))%").mwMono(size: 9).foregroundStyle(Color.mwMuted)
                        }
                    }
                }
            }
            .frame(height: height * 0.55)

            if temperatures.isEmpty {
                EmptyNote(text: "No cell temperature was recorded for this session.")
            } else {
                Chart(temperatures) { sample in
                    LineMark(x: .value("Elapsed", sample.offset),
                             y: .value("Celsius", sample.batteryTemperature ?? 0))
                        .foregroundStyle(Color.mwLoss)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: temperatureDomain)
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.mwGrid)
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(Formatting.duration(seconds)).mwMono(size: 9).foregroundStyle(Color.mwMuted)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.mwGrid)
                        AxisValueLabel {
                            if let celsius = value.as(Double.self) {
                                Text(String(format: "%.0f°", celsius)).mwMono(size: 9).foregroundStyle(Color.mwMuted)
                            }
                        }
                    }
                }
                .frame(height: height * 0.45)
            }
        }
        .chartLegend(.hidden)
        .clipped()
    }
}

/// Compact inline sparkline, used in the session list.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .mwAccent

    /// Points actually drawn. A session holds up to 1,500 samples and this is
    /// 26 points tall in a list row, so nearly all of them would land on the same
    /// pixel column. Peak-preserving: each bucket keeps its largest value, so
    /// thinning cannot hide a spike, which plain striding would.
    private static let resolution = 64

    private var thinned: [Double] {
        guard values.count > Self.resolution else { return values }
        let bucket = Double(values.count) / Double(Self.resolution)
        return (0..<Self.resolution).compactMap { index in
            let start = Int(Double(index) * bucket)
            let end = max(start + 1, Int(Double(index + 1) * bucket))
            return values[start..<min(end, values.count)].max()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let points = thinned
            let peak = max(points.max() ?? 1, 0.001)
            Path { path in
                guard points.count > 1 else { return }
                for (index, value) in points.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(points.count - 1)
                    let y = geometry.size.height * (1 - CGFloat(value / peak))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Rolling three-minute view of the hottest sensor in the phone.
struct LiveTemperatureChart: View {
    let samples: [LiveSample]
    var height: CGFloat = 110

    private var points: [LiveSample] {
        samples.filter { ($0.hottestTemperature ?? .nan).isFinite }
    }

    private var domain: ClosedRange<Double> {
        let values = points.compactMap(\.hottestTemperature)
        guard let low = values.min(), let high = values.max(), low.isFinite, high.isFinite else {
            return 20...50
        }
        let padding = max((high - low) * 0.3, 1.5)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        Chart(points) { sample in
            AreaMark(x: .value("Time", sample.date),
                     y: .value("°C", sample.hottestTemperature ?? 0))
                .foregroundStyle(LinearGradient(colors: [Color.mwLoss.opacity(0.35), Color.mwLoss.opacity(0.02)],
                                                startPoint: .top,
                                                endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", sample.date),
                     y: .value("°C", sample.hottestTemperature ?? 0))
                .foregroundStyle(Color.mwLoss)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let celsius = value.as(Double.self) {
                        Text(String(format: "%.0f°", celsius)).mwMono(size: 9).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .frame(height: height)
        .clipped()
    }
}
