import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var busy = false
    @State private var note: String?
    @State private var customMax: Double = 20

    private var status1: Int { app.live["foc_k_function_status1"]?.intValue ?? 0 }
    private var dbStatus: Int { app.live["db_k_function_status"]?.intValue ?? 0 }
    private var ebsLevel: Int {
        (status1 & 256 != 0 ? 1 : 0) + (status1 & 512 != 0 ? 2 : 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if app.ble.state != .ready {
                    Panel {
                        HStack(spacing: 10) {
                            Icon("bluetooth_disabled", size: 20).foregroundStyle(T.onSurfaceVariant)
                            Text("Connect to the scooter to change settings.")
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
                    braking
                    lightsAndSound
                }
                Color.clear.frame(height: 8)
            }
            .padding(12)
        }
        .background(T.surface)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

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
                    toggleRow("Fast lock", "bolt", status1 & 65536 != 0) { on in
                        await send(on ? "fastlock on" : "fastlock off")
                    }
                    Divider().overlay(T.outline)
                    toggleRow("Speed in unit 1", "speed", status1 & 1 != 0) { on in
                        await send(on ? "unit 1" : "unit 0")
                    }
                    Divider().overlay(T.outline)
                    customRow
                }
            }
        }
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Icon("tune", size: 18).foregroundStyle(T.onSurfaceVariant)
                Text("Custom ride mode").font(.system(size: 14)).foregroundStyle(T.onSurface)
                Spacer()
                Text(status1 & 2048 != 0 ? "On" : "Off")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(T.onSurfaceVariant)
            }
            HStack(spacing: 10) {
                Text("\(Int(customMax)) km/h")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.onSurface).frame(width: 74, alignment: .leading)
                Slider(value: $customMax, in: 5...32, step: 1).tint(T.primary)
            }
            HStack(spacing: 8) {
                OutlineButton(title: "Apply", icon: "check", enabled: !busy) {
                    act { try await app.ble.setCustomMode(on: true, maxKmh: customMax) ; return "Custom mode on, max \(Int(customMax)) km/h" }
                }
                OutlineButton(title: "Turn off", enabled: !busy) {
                    act { try await app.ble.setCustomMode(on: false); return "Custom mode off" }
                }
            }
        }
        .padding(16)
    }

    private var braking: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Regenerative braking")
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(0...3, id: \.self) { lvl in
                            Button {
                                act { try await app.ble.setEBS(lvl); return "Regen level \(lvl)" }
                            } label: {
                                Text(lvl == 0 ? "Off" : "\(lvl)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(ebsLevel == lvl ? T.onPrimary : T.onSurface)
                                    .background(ebsLevel == lvl ? T.primary : Color.clear)
                                    .overlay(Rectangle().strokeBorder(ebsLevel == lvl ? T.primary : T.outlineStrong, lineWidth: T.hairline))
                            }
                            .buttonStyle(.plain).disabled(busy)
                        }
                    }
                    Text("Stronger levels recover more charge and slow you harder when you release the throttle.")
                        .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var lightsAndSound: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Lights and sound")
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    toggleRow("Alarm sound", "notifications_active", dbStatus & 2 == 0) { on in
                        await send(on ? "alarm on" : "alarm off")
                    }
                    Divider().overlay(T.outline)
                    HStack {
                        Icon("wb_twilight", size: 18).foregroundStyle(T.onSurfaceVariant)
                        Text("Daytime running light").font(.system(size: 14)).foregroundStyle(T.onSurface)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    HStack(spacing: 8) {
                        OutlineButton(title: "On", enabled: !busy) { Task { await send("daylight on") } }
                        OutlineButton(title: "Off", enabled: !busy) { Task { await send("daylight off") } }
                        OutlineButton(title: "LED", enabled: !busy) { Task { await send("daylight led") } }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 8)
                }
            }
            Text("The headlight has no on/off command in NIU's own app either. Double-tap the physical button for that.")
                .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                .padding(.horizontal, 2)
        }
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

    private func act(_ body: @escaping () async throws -> String) {
        busy = true
        Task {
            do { note = try await body() } catch { note = error.localizedDescription }
            await app.refreshStatus()
            busy = false
        }
    }
}
