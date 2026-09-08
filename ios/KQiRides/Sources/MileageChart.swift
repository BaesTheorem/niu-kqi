import SwiftUI
import Charts

/// Distance per period. One series, so no legend: the title names it. Bars are
/// square and separated by a surface gap, matching the flat/sharp shape scale
/// used everywhere else rather than the rounded data-ends a default chart draws.
struct MileageChart: View {
    @EnvironmentObject var app: AppState
    @State private var period: Period = .day
    @State private var selected: String?

    enum Period: String, CaseIterable, Identifiable {
        case day, week, month, year
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        /// How many buckets to show. Enough to read a trend, few enough that a
        /// bar stays wide enough to hit with a finger.
        var count: Int {
            switch self {
            case .day: return 14
            case .week: return 12
            case .month: return 12
            case .year: return 5
            }
        }

        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            case .year: return .year
            }
        }

        func start(of date: Date, _ cal: Calendar) -> Date {
            switch self {
            case .day: return cal.startOfDay(for: date)
            case .week: return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            case .month: return cal.dateInterval(of: .month, for: date)?.start ?? date
            case .year: return cal.dateInterval(of: .year, for: date)?.start ?? date
            }
        }

        func label(_ d: Date) -> String {
            let f = DateFormatter()
            switch self {
            case .day: f.dateFormat = "M/d"
            case .week: f.dateFormat = "M/d"
            case .month: f.dateFormat = "MMM"
            case .year: f.dateFormat = "yyyy"
            }
            return f.string(from: d)
        }
    }

    struct Bucket: Identifiable {
        let id: String
        let start: Date
        let km: Double
    }

    /// Every bucket in the window, including the empty ones. Dropping days with
    /// no rides would compress the axis and quietly imply riding on days off.
    private var buckets: [Bucket] {
        let cal = Calendar.current
        let now = Date()
        var out: [Bucket] = []
        for i in stride(from: period.count - 1, through: 0, by: -1) {
            guard let anchor = cal.date(byAdding: period.component, value: -i, to: now) else { continue }
            let start = period.start(of: anchor, cal)
            guard let end = cal.date(byAdding: period.component, value: 1, to: start) else { continue }
            let km = app.actualRides
                .filter { $0.start >= start && $0.start < end }
                .reduce(0) { $0 + $1.km }
            out.append(Bucket(id: period.label(start), start: start, km: km))
        }
        return out
    }

    private var total: Double { buckets.reduce(0) { $0 + $1.km } }
    private var best: Bucket? { buckets.max { $0.km < $1.km } }
    private var selectedBucket: Bucket? { buckets.first { $0.id == selected } }

    /// The period in progress: today, this week, this month, this year. This is
    /// the number the selector is expected to change. The window total is not:
    /// with only days of history every window covers all of it, so summing the
    /// window shows the same figure in all four views and reads as broken.
    private var current: Bucket? { buckets.last }

    private var currentLabel: String {
        switch period {
        case .day: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        case .year: return "This year"
        }
    }

    private var windowLabel: String {
        guard let first = buckets.first?.start else { return "" }
        let f = DateFormatter()
        f.dateFormat = period == .year ? "yyyy" : "MMM d"
        return "since \(f.string(from: first))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            picker
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if total == 0 {
                        Text("No rides in this window.")
                            .font(.system(size: 13)).foregroundStyle(T.onSurfaceVariant)
                            .frame(maxWidth: .infinity, minHeight: 140)
                    } else {
                        chart
                    }
                }
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach(Period.allCases) { p in
                Button { period = p; selected = nil } label: {
                    Text(p.label)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(period == p ? T.onPrimary : T.onSurface)
                        .background(period == p ? T.primary : Color.clear)
                        .overlay(Rectangle().strokeBorder(period == p ? T.primary : T.outlineStrong,
                                                          lineWidth: T.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A hero number that answers the question the chart is asking, and doubles
    /// as the readout for the selected bar.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selectedBucket.map { "\(period.label) of \($0.id)" } ?? currentLabel)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(T.onSurfaceVariant)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(app.units.distanceText(selectedBucket?.km ?? current?.km ?? 0, decimals: 1))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.onSurface)
                Text(app.units.distanceUnit)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(T.onSurfaceVariant)
            }
            // The window total is stated rather than shown as the headline, so
            // seeing the same figure in two views reads as the fact it is, not
            // as a control that failed to respond.
            Text("\(app.units.distanceText(total)) \(app.units.distanceUnit) \(windowLabel)"
                 + (best.map { $0.km > 0 ? "  ·  best \(app.units.distanceText($0.km)) (\($0.id))" : "" } ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(T.onSurfaceVariant)
        }
    }

    private var chart: some View {
        Chart(buckets) { b in
            BarMark(
                x: .value("Period", b.id),
                y: .value("Distance", app.units.distance(b.km)),
                width: .ratio(0.72)      // the gap between bars is the spacer
            )
            .foregroundStyle(barTint(b))
            .cornerRadius(0)             // flat and sharp: no rounded data-ends
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(T.outline)
                AxisValueLabel().font(.system(size: 10)).foregroundStyle(T.onSurfaceVariant)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.system(size: 10)).foregroundStyle(T.onSurfaceVariant)
            }
        }
        .frame(height: 160)
    }

    /// Selection dims the rest rather than recolouring the chosen bar, so the
    /// mark colour keeps meaning one thing.
    private func barTint(_ b: Bucket) -> Color {
        guard let sel = selected, sel != b.id else { return T.chart }
        return T.chart.opacity(0.32)
    }
}
