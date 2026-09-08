import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @State private var busy: String?
    @State private var toast: String?

    private var battery: Int? { app.live["bms_soc_rt"]?.intValue }
    private var speed: Double? { app.live["foc_k_rt_speed"]?.intValue.map { Double($0) / 10 } }
    private var maxSpeed: Double? { app.live["foc_k_max_speed"]?.intValue.map { Double($0) / 10 } }
    private var range: Double? { app.live["db_k_estimated_mileage"]?.intValue.map { Double($0) / 100 } }
    private var poweredOn: Bool { (app.live["db_k_realtime_status"]?.intValue ?? 0) & 1 != 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                connectionPanel
                if app.ble.state == .ready {
                    batteryPanel
                    quickActions
                    if let t = toast {
                        Panel(tone: T.primaryContainer, border: T.primary, padding: 12) {
                            Text(t).font(.system(size: 13)).foregroundStyle(T.onPrimaryContainer)
                        }
                    }
                    identityPanel
                }
                Color.clear.frame(height: 8)
            }
            .padding(12)
        }
        .background(T.surface)
        .navigationTitle(app.scooter?.scooterName ?? "Scooter")
        .navigationBarTitleDisplayMode(.large)
    }

    private var connectionPanel: some View {
        Panel {
            HStack(spacing: 12) {
                Icon(app.ble.state == .ready ? "bluetooth_connected" : "bluetooth", size: 22)
                    .foregroundStyle(app.ble.state == .ready ? T.primary : T.onSurfaceVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.ble.state.label)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(T.onSurface)
                    if case .failed(let m) = app.ble.state {
                        Text(m).font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let name = app.ble.creds?.bleName {
                        Text(name).font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                    }
                }
                Spacer()
                if app.ble.state.isBusy { ProgressView() }
                else if app.ble.state == .ready {
                    Button("Disconnect") { app.ble.disconnect() }
                        .font(.system(size: 13)).foregroundStyle(T.onSurfaceVariant)
                } else {
                    Button("Connect") { Task { await app.connectAndRead() } }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(T.primary)
                }
            }
        }
    }

    private var batteryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 14) {
                    BatteryGauge(percent: battery ?? 0)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(battery.map(String.init) ?? "--")
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(T.onSurface)
                            Text("%").font(.system(size: 16, weight: .medium)).foregroundStyle(T.onSurfaceVariant)
                        }
                        Text(poweredOn ? "Powered on" : "Standby")
                            .font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                    }
                    Spacer()
                }
                Divider().overlay(T.outline)
                HStack(spacing: 0) {
                    Stat(value: range.map { String(format: "%.1f", $0) } ?? "--", unit: "km", caption: "Est. range")
                    Rectangle().fill(T.outline).frame(width: T.hairline, height: 34)
                    Stat(value: speed.map { String(format: "%.1f", $0) } ?? "--", unit: "km/h", caption: "Speed")
                        .padding(.leading, 14)
                    Rectangle().fill(T.outline).frame(width: T.hairline, height: 34)
                    Stat(value: maxSpeed.map { String(format: "%.0f", $0) } ?? "--", unit: "km/h", caption: "Max")
                        .padding(.leading, 14)
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Quick actions")
            HStack(spacing: 8) {
                OutlineButton(title: "Lock", icon: "lock", enabled: busy == nil) { fire("lock", "Locked") }
                OutlineButton(title: "Unlock", icon: "lock_open", enabled: busy == nil) { fire("unlock", "Unlocked") }
            }
            HStack(spacing: 8) {
                OutlineButton(title: "Dash on", icon: "power_settings_new", enabled: busy == nil) { fire("on", "Dashboard on") }
                OutlineButton(title: "Dash off", icon: "power_off", enabled: busy == nil) { fire("off", "Dashboard off") }
            }
            OutlineButton(title: "Sync clock", icon: "schedule", enabled: busy == nil) {
                busy = "clock"
                Task {
                    do { try await app.ble.syncClock(); toast = "Clock synced" }
                    catch { toast = error.localizedDescription }
                    busy = nil; await app.refreshStatus()
                }
            }
        }
    }

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Identity")
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    row("Dashboard", app.live["db_k_sn"]?.display, app.live["db_k_sw_ver"]?.display)
                    Divider().overlay(T.outline)
                    row("Controller", app.live["foc_k_sn"]?.display, app.live["foc_k_s_ver"]?.display)
                    Divider().overlay(T.outline)
                    row("Serial", app.scooter?.snId, nil)
                }
            }
        }
    }

    private func row(_ label: String, _ a: String?, _ b: String?) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(T.onSurfaceVariant)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(a?.isEmpty == false ? a! : "--")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(T.onSurface)
                if let b, !b.isEmpty {
                    Text(b).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.onSurfaceVariant)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func fire(_ cmd: String, _ ok: String) {
        busy = cmd
        Task {
            do { try await app.ble.run(cmd); toast = ok }
            catch { toast = error.localizedDescription }
            busy = nil
            await app.refreshStatus()
        }
    }
}

/// Flat segmented battery gauge: no gradients, no glow, square segments.
struct BatteryGauge: View {
    let percent: Int
    private var filled: Int { max(0, min(10, Int((Double(percent) / 10).rounded()))) }
    private var tint: Color { percent <= 15 ? T.error : T.primary }

    var body: some View {
        VStack(spacing: 3) {
            ForEach((0..<10).reversed(), id: \.self) { i in
                Rectangle()
                    .fill(i < filled ? tint : T.outline.opacity(0.5))
                    .frame(width: 26, height: 7)
            }
        }
        .padding(4)
        .overlay(Rectangle().strokeBorder(T.outline, lineWidth: T.hairline))
    }
}
