import SwiftUI

@main
struct KQiRidesApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(T.primary)
                .onAppear { app.restore() }
                .onChange(of: phase) { _, new in
                    // Coming back from the background is the same situation as a
                    // cold open: the link is gone and the scooter may be in range.
                    if new == .active { Task { await app.autoConnect() } }
                    // Keep the intent, stop the radio work.
                    else { app.pauseScanning() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if !app.isLoggedIn {
            LoginView()
        } else {
            TabView {
                NavigationStack { DashboardView() }
                    .tabItem { Label { Text("Scooter") } icon: { IconImage.of("electric_scooter") } }
                NavigationStack { RidesView() }
                    .tabItem { Label { Text("Rides") } icon: { IconImage.of("timeline") } }
                NavigationStack { SettingsView() }
                    .tabItem { Label { Text("Settings") } icon: { IconImage.of("tune") } }
                NavigationStack { AccountView() }
                    .tabItem { Label { Text("Account") } icon: { IconImage.of("account_circle") } }
            }
            .task { await app.autoConnect() }
        }
    }
}

struct AccountView: View {
    @EnvironmentObject var app: AppState
    @State private var firmware: [[String: Any]] = []
    @State private var loadingFw = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Account")
                        Text(app.session?.account ?? "--")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(T.onSurface)
                        if let s = app.scooter {
                            Divider().overlay(T.outline)
                            HStack {
                                Text(s.scooterName ?? "Scooter").font(.system(size: 13)).foregroundStyle(T.onSurface)
                                Spacer()
                                Text(s.skuName ?? "").font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                            }
                            Text(s.snId).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.onSurfaceVariant)
                        }
                    }
                }

                NavigationLink { AdvancedView() } label: {
                    Panel {
                        HStack(spacing: 10) {
                            Icon("build", size: 18).foregroundStyle(T.onSurfaceVariant)
                            Text("Advanced").font(.system(size: 14)).foregroundStyle(T.onSurface)
                            Spacer()
                            Icon("chevron_right", size: 18).foregroundStyle(T.onSurfaceVariant)
                        }
                    }
                }
                .buttonStyle(.plain)

                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Firmware")
                        if firmware.isEmpty {
                            OutlineButton(title: loadingFw ? "Checking…" : "Check for updates",
                                          icon: "system_update", enabled: !loadingFw) {
                                loadingFw = true
                                Task {
                                    if let t = app.session?.token, let sn = app.scooter?.snId {
                                        firmware = (try? await NIUCloud.shared.firmware(token: t, sn: sn)) ?? []
                                    }
                                    loadingFw = false
                                }
                            }
                        }
                        ForEach(Array(firmware.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text((item["devicetype"] as? String) ?? "?")
                                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(T.onSurface)
                                Spacer()
                                Text((item["cur_version"] as? String) ?? (item["version"] as? String) ?? "--")
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(T.onSurfaceVariant)
                            }
                        }
                    }
                }

                OutlineButton(title: "Sign out", icon: "logout", tint: T.error) { app.logOut() }
                Color.clear.frame(height: 8)
            }
            .padding(12)
        }
        .background(T.surface)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.large)
    }
}
