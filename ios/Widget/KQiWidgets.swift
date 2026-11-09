import AppIntents
import SwiftUI
import WidgetKit

// The extension only draws. Every button runs PowerOnScooterIntent, which the
// system performs in the app's process (see Shared/PowerOnIntent.swift).

@main
struct KQiWidgets: WidgetBundle {
    var body: some Widget {
        PowerWidget()
        PowerControl()
    }
}

// MARK: - Lock Screen widget

struct PowerEntry: TimelineEntry {
    let date: Date
    let snap: ScooterSnapshot?
}

struct PowerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PowerEntry { PowerEntry(date: .now, snap: nil) }

    func getSnapshot(in context: Context, completion: @escaping (PowerEntry) -> Void) {
        completion(PowerEntry(date: .now, snap: ScooterShared.load()))
    }

    // No schedule: the app reloads this timeline whenever it learns something.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PowerEntry>) -> Void) {
        completion(Timeline(entries: [PowerEntry(date: .now, snap: ScooterShared.load())], policy: .never))
    }
}

struct PowerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ScooterShared.widgetKind, provider: PowerProvider()) { entry in
            PowerWidgetView(entry: entry)
        }
        .configurationDisplayName("Power on")
        .description("Turns the KQi Air on over Bluetooth.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct PowerWidgetView: View {
    let entry: PowerEntry
    @Environment(\.widgetFamily) private var family

    /// The scooter turns itself off after a while, so a power reading older
    /// than this is not shown as current.
    private static let freshFor: TimeInterval = 10 * 60

    private var recent: ScooterSnapshot? {
        guard let s = entry.snap, entry.date.timeIntervalSince(s.updated) < Self.freshFor else { return nil }
        return s
    }

    private var failed: Bool { recent.map { !$0.ok } ?? false }
    private var isOn: Bool { recent?.ok == true && recent?.poweredOn == true }

    var body: some View {
        Button(intent: PowerOnScooterIntent()) {
            if family == .accessoryRectangular { rectangular } else { circular }
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            if family == .accessoryCircular { AccessoryWidgetBackground() } else { Color.clear }
        }
    }

    private var circular: some View {
        VStack(spacing: 1) {
            Image(systemName: failed ? "exclamationmark.triangle" : "power")
                .font(.system(size: 22, weight: .semibold))
                .widgetAccentable()
            Text(circularLabel)
                .font(.system(size: 11, weight: .semibold))
                .invalidatableContent()
        }
    }

    private var circularLabel: String {
        if isOn { return "ON" }
        if failed { return "RETRY" }
        if let b = entry.snap?.battery { return "\(b)%" }
        return "KQi"
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("KQi Air", systemImage: failed ? "exclamationmark.triangle" : "power")
                .font(.headline)
                .widgetAccentable()
            Group {
                if let s = recent {
                    Text("\(s.message) · \(s.updated, style: .time)")
                } else {
                    Text("Tap to power on")
                }
            }
            .font(.caption)
            .lineLimit(1)
            .invalidatableContent()
            if let b = entry.snap?.battery {
                Text("Battery \(b)%").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lock Screen / Control Center control (also the Action button)

struct PowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ScooterShared.controlKind) {
            ControlWidgetButton(action: PowerOnScooterIntent()) {
                Label("KQi Air on", systemImage: "scooter")
            }
        }
        .displayName("Power on KQi Air")
        .description("Turns the scooter on over Bluetooth.")
    }
}
