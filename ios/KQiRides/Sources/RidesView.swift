import SwiftUI

struct RidesView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summary
                if app.misdatedCount > 0 { correctionBanner }
                ForEach(app.days) { day in
                    daySection(day)
                }
                if app.rides.isEmpty && !app.loading {
                    Panel { Text("No rides yet.").foregroundStyle(T.onSurfaceVariant) }
                }
                Color.clear.frame(height: 8)
            }
            .padding(12)
        }
        .background(T.surface)
        .navigationTitle("Riding Data")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await app.refreshRides() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await app.refreshRides() } } label: { Icon("refresh", size: 20) }
                    .foregroundStyle(T.onSurface)
            }
        }
    }

    private var summary: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Icon("electric_scooter", size: 20).foregroundStyle(T.primary)
                    Text(app.scooter?.scooterName ?? "Scooter")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(T.onSurface)
                    Spacer()
                    Text("\(app.rides.count) rides")
                        .font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                }
                Divider().overlay(T.outline)
                HStack(spacing: 0) {
                    Stat(value: fmt(app.odometerKm ?? app.totalTrackedKm), unit: "km", caption: "Total mileage")
                    Rectangle().fill(T.outline).frame(width: T.hairline, height: 34)
                    Stat(value: fmt(app.thisWeekKm), unit: "km", caption: "This week")
                        .padding(.leading, 14)
                }
            }
        }
    }

    private var correctionBanner: some View {
        Panel(tone: T.warnContainer, border: T.warn, padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Icon("edit_calendar", size: 20).foregroundStyle(T.onWarnContainer)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(app.misdatedCount) ride\(app.misdatedCount == 1 ? "" : "s") re-dated")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(T.onWarnContainer)
                    Text("NIU files rides after 11:00 under the next day. These are grouped by when you actually rode.")
                        .font(.system(size: 12))
                        .foregroundStyle(T.onWarnContainer.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func daySection(_ day: RideDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayLabel(day.day))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(T.onSurface)
                if day.correctedCount > 0 {
                    Icon("edit_calendar", size: 13).foregroundStyle(T.warn)
                }
                Spacer()
                Text("\(fmt(day.km)) km")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.onSurfaceVariant)
            }
            .padding(.top, 6)
            ForEach(day.rides) { ride in RideCard(ride: ride) }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: v >= 100 ? "%.0f" : "%.1f", v) }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }
}

struct RideCard: View {
    let ride: Ride

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.2f", ride.km))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(T.onSurface)
                        Text("km").font(.system(size: 13, weight: .medium)).foregroundStyle(T.onSurfaceVariant)
                    }
                    Spacer()
                    Text("\(clock(ride.start)) – \(clock(ride.end))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(T.onSurfaceVariant)
                }
                HStack(spacing: 0) {
                    metric("schedule", duration(ride.ridingtime), "Time")
                    metric("speed", String(format: "%.1f", ride.avespeed), "Avg km/h")
                    if let p = ride.powerConsumption { metric("battery_horiz_050", "\(p)%", "Used") }
                }
                if ride.isMisdated, let s = ride.serverDay {
                    HStack(spacing: 6) {
                        Icon("edit_calendar", size: 13)
                        Text("NIU dated this \(short(s))")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(T.warn)
                }
            }
        }
    }

    private func metric(_ icon: String, _ value: String, _ caption: String) -> some View {
        HStack(spacing: 6) {
            Icon(icon, size: 16).foregroundStyle(T.onSurfaceVariant)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(T.onSurface)
                Text(caption).font(.system(size: 10)).foregroundStyle(T.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }
    private func short(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
    private func duration(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }
}
