import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var busy = false
    @State private var note: String?
    @State private var customMax: Double = 20
    @State private var assistMax: Double = 6
    @State private var kickStart: Double = 3

    private var status1: Int { app.live["foc_k_function_status1"]?.intValue ?? 0 }
    private var dbStatus: Int { app.live["db_k_function_status"]?.intValue ?? 0 }
    private var ebsLevel: Int { (status1 & 256 != 0 ? 1 : 0) + (status1 & 512 != 0 ? 2 : 0) }
    private var throttleMode: Int { app.live["foc_k_throttle_mode_set"]?.intValue ?? 0 }
    private var u: Units { app.units }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                display
                smartStartSection
                if app.ble.state != .ready {
                    Panel {
                        HStack(spacing: 10) {
                            Icon("bluetooth_disabled", size: 20).foregroundStyle(T.onSurfaceVariant)
                            Text("Connect to change vehicle settings.")
                                .font(.system(size: 13)).foregroundStyle(T.onSurfaceVariant)
                            Spacer()
                            Button("Connect") { Task { await app.connectAndRead() } }
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(T.primary)
                        }
                    }
                } else {
                    if let n = note {
                        Panel(tone: T.primaryContainer, border: T.primary, padding: 12) {
                            Text(n).font(.system(size: 13)).foregroundStyle(T.onPrimaryContainer)
                        }
                    }
                    riding
                    speedLimits
                    braking
                    lights
                    security
                    maintenance
                }
                Color.clear.frame(height: 8)
            }
            .padding(12)
        }
        .background(T.surface)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { syncSliders() }
        .onChange(of: app.live.count) { _, _ in syncSliders() }
    }

    /// A Slider whose bound value sits outside its range still renders that value
    /// as text, so a bad reading shows up as a number rather than as an obviously
    /// broken control. Clamp on the way in.
    private func syncSliders() {
        func take(_ field: String, into target: inout Double, _ range: ClosedRange<Double>) {
            guard let v = app.live[field]?.intValue else { return }
            let shown = u.speed(Double(v) / 10)
            guard shown.isFinite else { return }
            target = min(max(shown, range.lowerBound), range.upperBound)
        }
        take("foc_k_def_max_speed", into: &customMax, customRange)
        take("foc_k_assist_max_speed", into: &assistMax, assistRange)
        take("foc_k_no_zero_start", into: &kickStart, 1...10)
    }

    private var customRange: ClosedRange<Double> { u == .metric ? 5...32 : 3...20 }
    private var assistRange: ClosedRange<Double> { u == .metric ? 3...10 : 2...6 }

    // MARK: - display (works with no scooter connected)

    private var display: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Display")
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Icon("straighten", size: 18).foregroundStyle(T.onSurfaceVariant)
                        Text("Units").font(.system(size: 14)).foregroundStyle(T.onSurface)
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        ForEach(Units.allCases) { unit in
                            Button { app.units = unit; syncSliders() } label: {
                                Text(unit.label)
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(u == unit ? T.onPrimary : T.onSurface)
                                    .background(u == unit ? T.primary : Color.clear)
                                    .overlay(Rectangle().strokeBorder(u == unit ? T.primary : T.outlineStrong,
                                                                      lineWidth: T.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Changes what this app shows. The scooter's own dashboard unit is under Riding.")
                        .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                }
            }
        }
    }

    // MARK: - riding

    private var riding: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Riding")
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    toggleRow("Cruise control", "cruise_control", status1 & 4 != 0) { on in
                        await send(on ? "cruise on" : "cruise off")
                    }
                    Divider().overlay(T.outline)
                    toggleRow("Kick to start", "directions_walk", status1 & 2 != 0) { on in
                        await send(on ? "kickstart on" : "kickstart off")
                    }
                    Divider().overlay(T.outline)
                    sliderRow(title: "Kick speed before the motor engages",
                              value: $kickStart, range: 1...10, unit: u.speedUnit) {
                        try await app.ble.write([("foc_k_no_zero_start", Int((u.toKmh(kickStart) * 10).rounded()))])
                        return "Kick-to-start threshold set"
                    }
                    Divider().overlay(T.outline)
                    throttleRow
                    Divider().overlay(T.outline)
                    toggleRow("Dashboard shows unit 1", "speed", status1 & 1 != 0) { on in
                        await send(on ? "unit 1" : "unit 0")
                    }
                    Divider().overlay(T.outline)
                    toggleRow("Auto power-off when idle", "timer_off",
                              (app.live["foc_k_automatic_shutdown_en"]?.intValue ?? 0) != 0) { on in
                        await act { try await app.ble.write([("foc_k_automatic_shutdown_en", on ? 1 : 0)])
                                    return on ? "Auto power-off on" : "Auto power-off off" }
                    }
                }
            }
        }
    }

    private var throttleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Icon("tune", size: 18).foregroundStyle(T.onSurfaceVariant)
                Text("Throttle response").font(.system(size: 14)).foregroundStyle(T.onSurface)
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach([(1, "Easy"), (2, "Normal")], id: \.0) { value, label in
                    Button {
                        act { try await app.ble.write([("foc_k_throttle_mode_set", value)])
                              return "Throttle response: \(label)" }
                    } label: {
                        Text(label)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(throttleMode == value ? T.onPrimary : T.onSurface)
                            .background(throttleMode == value ? T.primary : Color.clear)
                            .overlay(Rectangle().strokeBorder(throttleMode == value ? T.primary : T.outlineStrong,
                                                              lineWidth: T.hairline))
                    }
                    .buttonStyle(.plain).disabled(busy)
                }
            }
            Text("How hard it pulls away. Easy ramps up gently.")
                .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
        }
        .padding(16)
    }

    // MARK: - Smart Start (proximity unlock)

    private var smartStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Smart Start")
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Unlocks the scooter when your phone is near it.")
                        .font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                    if let cfg = app.smartKey {
                        Divider().overlay(T.outline)
                        Text("Unlock distance").font(.system(size: 14)).foregroundStyle(T.onSurface)
                        HStack(spacing: 6) {
                            ForEach(Array(cfg.ranges.enumerated()), id: \.element) { idx, dbm in
                                Button { act { await app.setUnlockRange(dbm) } } label: {
                                    VStack(spacing: 1) {
                                        Text(rangeLabel(idx, of: cfg.ranges.count))
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("\(dbm) dBm").font(.system(size: 10))
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .foregroundStyle(cfg.smartKeyRange == dbm ? T.onPrimary : T.onSurface)
                                    .background(cfg.smartKeyRange == dbm ? T.primary : Color.clear)
                                    .overlay(Rectangle().strokeBorder(
                                        cfg.smartKeyRange == dbm ? T.primary : T.outlineStrong, lineWidth: T.hairline))
                                }
                                .buttonStyle(.plain).disabled(busy)
                            }
                        }
                        Text("Signal strength, not metres: a more negative number reaches further.")
                            .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Not loaded. Pull to refresh on the Rides tab, or sign in again.")
                            .font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                    }
                }
            }
        }
    }

    private func rangeLabel(_ i: Int, of n: Int) -> String {
        if n <= 1 { return "Set" }
        if i == 0 { return "Near" }
        if i == n - 1 { return "Far" }
        return "Medium"
    }

    // MARK: - speed limits

    private var speedLimits: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Speed limits")
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    sliderRow(title: "Custom mode top speed", value: $customMax,
                              range: customRange, unit: u.speedUnit) {
                        try await app.ble.setCustomMode(on: true, maxKmh: u.toKmh(customMax))
                        return "Custom mode on, top speed \(Int(customMax)) \(u.speedUnit)"
                    }
                    HStack(spacing: 8) {
                        OutlineButton(title: "Turn custom mode off", enabled: !busy) {
                            act { try await app.ble.setCustomMode(on: false); return "Custom mode off" }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                    Divider().overlay(T.outline)
                    sliderRow(title: "Walk assist speed", value: $assistMax,
                              range: assistRange, unit: u.speedUnit) {
                        try await app.ble.write([("foc_k_assist_max_speed", Int((u.toKmh(assistMax) * 10).rounded()))])
                        return "Walk assist set"
                    }
                    if let m = app.live["foc_k_max_speed"]?.intValue {
                        Divider().overlay(T.outline)
                        HStack {
                            Text("Hardware ceiling").font(.system(size: 13)).foregroundStyle(T.onSurfaceVariant)
                            Spacer()
                            Text("\(u.speedText(Double(m) / 10, decimals: 0)) \(u.speedUnit)")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(T.onSurface)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
        }
    }

    // MARK: - braking

    private var braking: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Regenerative braking")
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(0...3, id: \.self) { lvl in
                            Button { act { try await app.ble.setEBS(lvl); return "Regen level \(lvl)" } } label: {
                                Text(lvl == 0 ? "Off" : "\(lvl)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(ebsLevel == lvl ? T.onPrimary : T.onSurface)
                                    .background(ebsLevel == lvl ? T.primary : Color.clear)
                                    .overlay(Rectangle().strokeBorder(ebsLevel == lvl ? T.primary : T.outlineStrong,
                                                                      lineWidth: T.hairline))
                            }
                            .buttonStyle(.plain).disabled(busy)
                        }
                    }
                    Text("Stronger levels recover more charge and slow you harder off the throttle.")
                        .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - lights

    private var lights: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Lights")
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Daytime running light").font(.system(size: 14)).foregroundStyle(T.onSurface)
                    HStack(spacing: 8) {
                        OutlineButton(title: "On", enabled: !busy) { Task { await send("daylight on") } }
                        OutlineButton(title: "Off", enabled: !busy) { Task { await send("daylight off") } }
                        OutlineButton(title: "LED", enabled: !busy) { Task { await send("daylight led") } }
                    }
                    if let mode = app.live["foc_k_decorative_light_mode"]?.intValue {
                        Divider().overlay(T.outline)
                        HStack {
                            Text("Deck light mode").font(.system(size: 13)).foregroundStyle(T.onSurfaceVariant)
                            Spacer()
                            Text("\(mode)").font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(T.onSurface)
                        }
                        HStack(spacing: 6) {
                            ForEach(0...3, id: \.self) { m in
                                Button {
                                    act { try await app.ble.write([("foc_k_decorative_light_mode", m)])
                                          return "Deck light mode \(m)" }
                                } label: {
                                    Text("\(m)").font(.system(size: 13, weight: .semibold))
                                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                                        .foregroundStyle(mode == m ? T.onPrimary : T.onSurface)
                                        .background(mode == m ? T.primary : Color.clear)
                                        .overlay(Rectangle().strokeBorder(mode == m ? T.primary : T.outlineStrong,
                                                                          lineWidth: T.hairline))
                                }
                                .buttonStyle(.plain).disabled(busy)
                            }
                        }
                    }
                    Text("The headlight has no on/off command in NIU's own app either. Double-tap the physical button.")
                        .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - security

    private var security: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Security")
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    toggleRow("Fast lock", "bolt", status1 & 65536 != 0) { on in
                        await send(on ? "fastlock on" : "fastlock off")
                    }
                    Divider().overlay(T.outline)
                    toggleRow("Alarm sound", "notifications_active", dbStatus & 2 == 0) { on in
                        await send(on ? "alarm on" : "alarm off")
                    }
                }
            }
        }
    }

    // MARK: - maintenance

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Maintenance")
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    if let f = app.live["db_k_f_code"]?.intValue {
                        HStack {
                            Icon(f == 0 ? "check_circle" : "error", size: 18)
                                .foregroundStyle(f == 0 ? T.primary : T.error)
                            Text(f == 0 ? "No fault reported" : "Fault code \(f)")
                                .font(.system(size: 14))
                                .foregroundStyle(f == 0 ? T.onSurface : T.error)
                            Spacer()
                        }
                        Divider().overlay(T.outline)
                    }
                    OutlineButton(title: "Sync clock to phone", icon: "schedule", enabled: !busy) {
                        act { try await app.ble.syncClock(); return "Clock synced" }
                    }
                    if let ts = app.live["db_k_timestamp"]?.intValue, ts > 0 {
                        Text("Scooter clock: " + DateFormatter.localizedString(
                            from: Date(timeIntervalSince1970: Double(ts)),
                            dateStyle: .short, timeStyle: .short))
                            .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                    }
                }
            }
        }
    }

    // MARK: - shared rows

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           unit: String, apply: @escaping () async throws -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14)).foregroundStyle(T.onSurface)
            HStack(spacing: 10) {
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.onSurface).frame(width: 78, alignment: .leading)
                Slider(value: value, in: range, step: 1).tint(T.primary).disabled(busy)
                Button("Set") { act(apply) }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(T.primary).disabled(busy)
            }
        }
        .padding(16)
    }

    private func toggleRow(_ title: String, _ icon: String, _ isOn: Bool,
                           _ action: @escaping (Bool) async -> Void) -> some View {
        HStack {
            Icon(icon, size: 18).foregroundStyle(T.onSurfaceVariant)
            Text(title).font(.system(size: 14)).foregroundStyle(T.onSurface)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { v in Task { await action(v) } }))
                .labelsHidden().tint(T.primary).disabled(busy)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func send(_ cmd: String) async {
        busy = true
        do { try await app.ble.run(cmd); note = "Sent \(cmd)" }
        catch { note = error.localizedDescription }
        await app.refreshStatus()
        busy = false
    }

    private func act(_ body: @escaping () async -> String) {
        busy = true
        Task { note = await body(); busy = false }
    }

    private func act(_ body: @escaping () async throws -> String) {
        busy = true
        Task {
            do { note = try await body() } catch { note = error.localizedDescription }
            await app.refreshStatus()
            busy = false
        }
    }
}
