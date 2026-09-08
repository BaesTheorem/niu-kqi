import SwiftUI

/// Everything the CLI can do that has no place on a product screen: the whole
/// field table, arbitrary reads and writes, raw frames, and the live push monitor.
struct AdvancedView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var showAll = false
    @State private var result: String?

    private var matches: [(String, FieldSpec)] {
        let pool = showAll ? NIUFields.all : NIUFields.kconfig
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return pool
            .filter { q.isEmpty || $0.key.lowercased().contains(q) || $0.value.code.lowercased().contains(q) }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink { RawFrameView() } label: { rowLabel("terminal", "Send a raw frame") }
                NavigationLink { MonitorView() } label: { rowLabel("monitor_heart", "Live push monitor") }
                NavigationLink { TrafficView() } label: { rowLabel("receipt_long", "Frame log") }
                NavigationLink { DangerView() } label: { rowLabel("warning", "Danger zone") }
            }
            .listRowBackground(T.surfaceContainer)

            Section {
                Toggle("Include the 255 shared NIU fields", isOn: $showAll)
                    .font(.system(size: 13)).tint(T.primary)
                if let r = result {
                    Text(r).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.onSurfaceVariant)
                }
            } header: {
                Text("\(matches.count) fields")
            }
            .listRowBackground(T.surfaceContainer)

            Section {
                ForEach(matches, id: \.0) { name, spec in
                    NavigationLink { FieldView(name: name, spec: spec) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(T.onSurface)
                                Text("\(spec.code)  \(spec.type)  \(spec.len)B")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(T.onSurfaceVariant)
                            }
                            Spacer()
                            if let v = app.live[name] {
                                Text(v.display).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(T.primary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listRowBackground(T.surfaceContainer)
        }
        .listStyle(.plain)
        .background(T.surface)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search fields")
        .navigationTitle("Advanced")
    }

    private func rowLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Icon(icon, size: 18).foregroundStyle(T.onSurfaceVariant)
            Text(title).font(.system(size: 14)).foregroundStyle(T.onSurface)
        }
    }
}

/// Read or write a single field.
struct FieldView: View {
    @EnvironmentObject var app: AppState
    let name: String
    let spec: FieldSpec
    @State private var value = ""
    @State private var out: String?
    @State private var busy = false
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(T.onSurface)
                        Text("code \(spec.code) · \(spec.type) · \(spec.len) bytes")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(T.onSurfaceVariant)
                        if let bits = Cmd.bits[name], let cur = app.live[name]?.intValue {
                            Divider().overlay(T.outline).padding(.vertical, 4)
                            ForEach(bits, id: \.mask) { b in
                                HStack(spacing: 8) {
                                    Icon(cur & b.mask != 0 ? "check_box" : "check_box_outline_blank", size: 15)
                                        .foregroundStyle(cur & b.mask != 0 ? T.primary : T.outlineStrong)
                                    Text(b.label).font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                if let o = out {
                    Panel(tone: T.surfaceContainerHigh) {
                        Text(o).font(.system(size: 13, design: .monospaced)).foregroundStyle(T.onSurface)
                            .textSelection(.enabled)
                    }
                }
                OutlineButton(title: "Read", icon: "download", enabled: !busy && app.ble.state == .ready) {
                    busy = true
                    Task {
                        do {
                            let v = try await app.ble.read([name])
                            for (k, vv) in v { app.live[k] = vv }
                            out = v.map { "\($0.0) = \($0.1.display)  (hex \($0.1.hex))" }.joined(separator: "\n")
                        } catch { out = "error: \(error.localizedDescription)" }
                        busy = false
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Write")
                        TextField("raw value in the field's own unit", text: $value)
                            .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced))
                            .padding(10).background(T.surface)
                            .overlay(Rectangle().strokeBorder(T.outline, lineWidth: T.hairline))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Text("Speeds are km/h times ten; timestamps are unix seconds.")
                            .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                        OutlineButton(title: "Write", icon: "upload", tint: T.error,
                                      enabled: !busy && !value.isEmpty && app.ble.state == .ready) {
                            confirming = true
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(T.surface)
        .navigationTitle("Field")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Write \(name)?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Write", role: .destructive) {
                busy = true
                Task {
                    do { out = "wrote: " + (try await app.ble.write([(name, value)])) }
                    catch { out = "error: \(error.localizedDescription)" }
                    busy = false
                }
            }
        } message: {
            Text("Sets \(name) to \(value) on the scooter.")
        }
    }
}

struct RawFrameView: View {
    @EnvironmentObject var app: AppState
    @State private var hex = ""
    @State private var out: [String] = []
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sends one frame exactly as typed and prints whatever comes back.")
                            .font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
                        TextField("hex", text: $hex)
                            .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced))
                            .padding(10).background(T.surface)
                            .overlay(Rectangle().strokeBorder(T.outline, lineWidth: T.hairline))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        OutlineButton(title: "Send", icon: "send", enabled: !busy && !hex.isEmpty && app.ble.state == .ready) {
                            busy = true
                            Task {
                                do { out = try await app.ble.raw(hex) }
                                catch { out = ["error: \(error.localizedDescription)"] }
                                busy = false
                            }
                        }
                    }
                }
                if !out.isEmpty {
                    Panel(tone: T.surfaceContainerHigh) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(out.enumerated()), id: \.offset) { _, f in
                                Text(f).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(T.surface).navigationTitle("Raw frame")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MonitorView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            if app.ble.pushed.isEmpty {
                Text("Nothing pushed yet. Ride it, or press buttons on the scooter.")
                    .font(.system(size: 13)).foregroundStyle(T.onSurfaceVariant)
            }
            ForEach(Array(app.ble.pushed.enumerated().reversed()), id: \.offset) { _, item in
                HStack {
                    Text(item.0).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.onSurface)
                    Spacer()
                    Text(item.1.display).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.primary)
                }
            }
        }
        .listStyle(.plain).background(T.surface).scrollContentBackground(.hidden)
        .navigationTitle("Live monitor").navigationBarTitleDisplayMode(.inline)
    }
}

struct TrafficView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 0) {
            Toggle("Log every frame", isOn: Binding(get: { app.ble.verbose }, set: { app.ble.verbose = $0 }))
                .font(.system(size: 13)).tint(T.primary).padding(12)
            List {
                ForEach(Array(app.ble.traffic.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.onSurfaceVariant)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
        .background(T.surface).navigationTitle("Frame log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// factory-reset lives behind its own screen and a typed confirmation, because
/// it is the one command in the table that cannot be undone.
struct DangerView: View {
    @EnvironmentObject var app: AppState
    @State private var typed = ""
    @State private var out: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Panel(tone: T.errorContainer, border: T.error) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Factory reset").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(T.onErrorContainer)
                        Text("Sends db_k_cmd 100. This clears the scooter's settings and cannot be undone. Type RESET to enable the button.")
                            .font(.system(size: 12)).foregroundStyle(T.onErrorContainer)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                TextField("type RESET", text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced))
                    .padding(10).background(T.surfaceContainer)
                    .overlay(Rectangle().strokeBorder(T.outline, lineWidth: T.hairline))
                    .autocorrectionDisabled().textInputAutocapitalization(.characters)
                OutlineButton(title: "Factory reset", icon: "restart_alt", tint: T.error,
                              enabled: typed == "RESET" && app.ble.state == .ready) {
                    Task {
                        do { try await app.ble.run("factory-reset"); out = "sent" }
                        catch { out = error.localizedDescription }
                    }
                }
                if let o = out { Text(o).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.onSurfaceVariant) }
            }
            .padding(12)
        }
        .background(T.surface).navigationTitle("Danger zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}
