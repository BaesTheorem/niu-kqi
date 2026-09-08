import SwiftUI

struct RidesView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summary
                MileageChart()
                ForEach(app.days) { day in daySection(day) }
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
                    Text("\(app.actualRides.count) rides")
                        .font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                }
                Divider().overlay(T.outline)
                HStack(spacing: 0) {
                    Stat(value: app.units.distanceText(app.displayOdometerKm, decimals: 0),
                         unit: app.units.distanceUnit, caption: "Total mileage")
                    Rectangle().fill(T.outline).frame(width: T.hairline, height: 34)
                    Stat(value: app.units.distanceText(app.thisWeekKm),
                         unit: app.units.distanceUnit, caption: "This week")
                        .padding(.leading, 14)
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
                Spacer()
                Text("\(app.units.distanceText(day.km)) \(app.units.distanceUnit)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.onSurfaceVariant)
            }
            .padding(.top, 6)
            ForEach(day.rides) { ride in
                if ride.isChargingSession {
                    ChargeCard(ride: ride)
                } else {
                    RideCard(ride: ride, units: app.units)
                }
            }
        }
    }

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
    let units: Units

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(units.distanceText(ride.km, decimals: 2))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(T.onSurface)
                        Text(units.distanceUnit)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(T.onSurfaceVariant)
                    }
                    Spacer()
                    Text("\(clock(ride.start)) – \(clock(ride.end))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(T.onSurfaceVariant)
                }
                HStack(spacing: 0) {
                    metric("schedule", duration(ride.ridingtime), "Time")
                    metric("speed", units.speedText(ride.avespeed), "Avg \(units.speedUnit)")
                    if let p = ride.powerConsumption { metric("battery_horiz_050", "\(p)%", "Used") }
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
    private func duration(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The scooter logs a charge as a track. Shown as what it is rather than as a
/// 74-minute ride that somehow gained battery, and left out of distance totals.
struct ChargeCard: View {
    let ride: Ride
    var body: some View {
        Panel(padding: 14) {
            HStack(spacing: 10) {
                Icon("battery_charging_full", size: 20).foregroundStyle(T.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Charging").font(.system(size: 14, weight: .semibold)).foregroundStyle(T.onSurface)
                    Text("\(clock(ride.start)) \u{2013} \(clock(ride.end))  \u{00B7}  +\(abs(ride.powerConsumption ?? 0))%")
                        .font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                }
                Spacer()
            }
        }
    }
    private func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }
}
