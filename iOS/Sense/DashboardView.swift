import Charts
import SwiftUI
import UIKit

enum SenseStyle {
    static let cyan = accent(0.10, 0.74, 1)
    static let mint = accent(0.10, 0.96, 0.68)
    static let violet = accent(0.72, 0.48, 1)
    static let blue = accent(0.38, 0.60, 1)
    static let coral = accent(1, 0.36, 0.43)
    private static func accent(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Color {
        let base = UIColor(red: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let light = UIColor(hue: hue, saturation: max(0.85, saturation), brightness: 0.53, alpha: 1)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? base : light })
    }
}

struct SenseMark: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * (1 - y)) }
        var path = Path()
        path.move(to: p(0.76, 0.77))
        path.addCurve(to: p(0.26, 0.69), control1: p(0.57, 0.97), control2: p(0.26, 0.89))
        path.addCurve(to: p(0.50, 0.50), control1: p(0.26, 0.53), control2: p(0.34, 0.52))
        path.addCurve(to: p(0.74, 0.31), control1: p(0.66, 0.48), control2: p(0.74, 0.47))
        path.addCurve(to: p(0.24, 0.23), control1: p(0.74, 0.11), control2: p(0.43, 0.03))
        return path
    }
}

struct DashboardView: View {
    @EnvironmentObject private var monitor: DeviceMonitor
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme
    @AppStorage("historyRange") private var range = 120.0
    @State private var settings = false

    private var samples: [HistorySample] { MetricFormat.trimHistory(monitor.history, now: Date(), seconds: range) }
    private var storageFraction: Double? { MetricFormat.usedFraction(total: monitor.storageTotal, free: monitor.storageFree) }
    private var thermalColor: Color { monitor.thermal == .nominal ? SenseStyle.cyan : monitor.thermal == .fair ? .orange : SenseStyle.coral }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    HStack {
                        Label(monitor.deviceName, systemImage: "iphone").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("2 minutes") { range = 120 }
                            Button("15 minutes") { range = 900 }
                        } label: {
                            HStack(spacing: 4) { Text(range == 900 ? "15 min history" : "2 min history"); Image(systemName: "chevron.down").font(.system(size: 9)) }
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        }.accessibilityLabel("Chart history range")
                    }.padding(.top, 4).padding(.bottom, 2)
                    if DeviceMonitor.isSimulator {
                        Label("Simulator · available hardware readings reflect this Mac.", systemImage: "desktopcomputer")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    networkCard
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        batteryCard
                        thermalCard
                        storageCard
                        ramCard
                    }
                    memoryCard
                    deviceDetails
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 5) {
                            Circle().fill(monitor.running ? SenseStyle.mint : .secondary).frame(width: 5, height: 5)
                            Text(monitor.running ? "LIVE · EVERY \(Int(monitor.effectiveInterval)) SECOND\(monitor.effectiveInterval == 1 ? "" : "S")" : "PAUSED")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2)
                            Spacer()
                            Image(systemName: "lock.shield").font(.system(size: 11))
                            Text("On your device").font(.system(size: 10))
                        }
                        Text("History collects while Sense is open.").font(.system(size: 10))
                    }.foregroundStyle(.secondary).padding(.top, 5).padding(.bottom, 16)
                }
                .padding(20).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
            .background(scheme == .dark ? Color(red: 0.065, green: 0.072, blue: 0.085) : Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) { SettingsView().environmentObject(monitor) }
            .onAppear { monitor.start() }
            .onChange(of: phase) { _, value in if value == .active { monitor.start() } else { monitor.stop() } }
        }
        .tint(SenseStyle.cyan)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            SenseMark().stroke(LinearGradient(colors: [SenseStyle.cyan, SenseStyle.mint], startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: 4.2, lineCap: .round))
                .frame(width: 38, height: 43).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sense").font(.system(size: 33, weight: .bold, design: .rounded)).tracking(-1.4)
                Text("Your \(monitor.deviceName), at a glance").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                    .frame(width: 42, height: 42).background(Color.secondary.opacity(0.08), in: Circle())
            }.accessibilityLabel("Settings")
        }.padding(.top, 8).padding(.bottom, 8)
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeading("Network", icon: "globe", color: SenseStyle.cyan, badge: monitor.connection)
            HStack(alignment: .top, spacing: 18) {
                rateValue(monitor.traffic.download, title: "Download", icon: "arrow.down", color: SenseStyle.cyan)
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1, height: 50)
                rateValue(monitor.traffic.upload, title: "Upload", icon: "arrow.up", color: SenseStyle.mint)
            }
            if samples.count > 1 && monitor.trafficAvailable {
                Chart(samples) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Download", sample.download), series: .value("Direction", "Download"))
                        .foregroundStyle(SenseStyle.cyan).lineStyle(StrokeStyle(lineWidth: 1.7)).interpolationMethod(.linear)
                    LineMark(x: .value("Time", sample.date), y: .value("Upload", sample.upload), series: .value("Direction", "Upload"))
                        .foregroundStyle(SenseStyle.mint).lineStyle(StrokeStyle(lineWidth: 1.7)).interpolationMethod(.linear)
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden).frame(height: 42)
                    .accessibilityLabel("Live interface traffic history")
            } else {
                Text(monitor.trafficAvailable ? "Collecting live history…" : monitor.history.count > 1 ? "Interface counters unavailable on this device" : "Waiting for interface counters…")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 26)
            }
            Text("Wi-Fi + cellular interface traffic · not a speed test").font(.system(size: 10)).foregroundStyle(.secondary)
        }.senseCard()
    }

    private func rateValue(_ value: Double, title: String, icon: String, color: Color) -> some View {
        let formatted = MetricFormat.rate(value)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(monitor.trafficAvailable ? formatted.value : "—").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-1)
                if monitor.trafficAvailable { Text(formatted.unit).font(.system(size: 12, weight: .medium)) }
            }.foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeading("Battery", icon: "battery.75percent", color: SenseStyle.mint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(monitor.battery.map { String(Int(($0 * 100).rounded())) } ?? "—").font(.system(size: 32, weight: .semibold, design: .rounded))
                if monitor.battery != nil { Text("%").font(.system(size: 14)) }
            }.foregroundStyle(SenseStyle.mint).monospacedDigit()
            meter(monitor.battery.map(Double.init), color: SenseStyle.mint)
            Text(monitor.lowPower ? "Low Power Mode" : monitor.batteryDescription).font(.system(size: 10)).foregroundStyle(.secondary)
        }.senseCard()
    }

    private var thermalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeading("Thermal", icon: "thermometer.medium", color: thermalColor)
            Text(monitor.thermalName).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(thermalColor).lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 38, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<4) { index in Capsule().fill(index <= monitor.thermal.rawValue ? thermalColor : Color.secondary.opacity(0.16)).frame(height: 5) }
            }
            Text("System thermal pressure").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.senseCard()
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeading("Free space", icon: "internaldrive", color: SenseStyle.blue)
            Text(MetricFormat.bytes(monitor.storageFree)).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(SenseStyle.blue)
                .lineLimit(1).minimumScaleFactor(0.6).frame(height: 38)
            meter(storageFraction.map { 1 - $0 }, color: SenseStyle.blue)
            Text("of \(MetricFormat.bytes(monitor.storageTotal)) total").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.senseCard()
    }

    private var ramCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeading("Memory", icon: "memorychip", color: SenseStyle.violet)
            Text(MetricFormat.bytes(monitor.totalRAM)).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(SenseStyle.violet)
                .lineLimit(1).minimumScaleFactor(0.6).frame(height: 38)
            HStack(spacing: 3) { ForEach(0..<12) { _ in RoundedRectangle(cornerRadius: 1).fill(SenseStyle.violet.opacity(0.55)).frame(height: 5) } }.accessibilityHidden(true)
            Text(DeviceMonitor.isSimulator ? "Simulator host RAM" : "Physical RAM capacity").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.senseCard()
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeading("Sense memory", icon: "waveform.path", color: SenseStyle.coral, badge: MetricFormat.bytes(monitor.appMemory))
            if samples.contains(where: { $0.appMemory != nil }) {
                Chart(samples) { sample in
                    if let memory = sample.appMemory {
                        AreaMark(x: .value("Time", sample.date), y: .value("Memory", Double(memory) / 1_000_000))
                            .foregroundStyle(LinearGradient(colors: [SenseStyle.coral.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", sample.date), y: .value("Memory", Double(memory) / 1_000_000))
                            .foregroundStyle(SenseStyle.coral).lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 46).accessibilityLabel("Sense app memory footprint history")
            }
            Text("Memory used by this app, not the whole iPhone.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.senseCard()
    }

    private var deviceDetails: some View {
        DisclosureGroup {
            VStack(spacing: 13) {
                infoRow("System", value: monitor.osVersion)
                infoRow("Processor cores", value: String(monitor.cores))
                infoRow("Connection", value: monitor.connection)
                infoRow("Low Data Mode", value: monitor.constrained ? "On" : "Off")
                infoRow("Metered connection", value: monitor.expensive ? "Yes" : "No")
                infoRow("IPv6 support", value: monitor.ipv6 ? "Available" : "Unavailable")
            }.padding(.top, 14)
        } label: { Label("Device details", systemImage: "iphone").font(.system(size: 13, weight: .medium)).foregroundStyle(.primary) }
            .senseCard()
    }

    private func cardHeading(_ title: String, icon: String, color: Color, badge: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 11, weight: .medium))
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
            Spacer(minLength: 1)
            if let badge {
                Text(badge).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
    }

    private func meter(_ fraction: Double?, color: Color) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color.secondary.opacity(0.15))
                .overlay(alignment: .leading) { if let fraction { Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction))) } }
        }.frame(height: 5).accessibilityHidden(true)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.system(size: 11))
    }
}

private struct SenseCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.145) : .white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.045), lineWidth: 1))
    }
}

private extension View {
    func senseCard() -> some View { modifier(SenseCard()) }
}

struct SettingsView: View {
    @EnvironmentObject private var monitor: DeviceMonitor
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system"); Text("Dark").tag("dark"); Text("Light").tag("light")
                    }.pickerStyle(.segmented)
                }
                Section {
                    Picker("Live refresh", selection: $monitor.refreshInterval) {
                        Text("1 second").tag(1.0); Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
                    }
                    Button("Clear session history", role: .destructive) { confirmClear = true }
                } header: { Text("Readings") } footer: {
                    Text("Readings pause in the background. Low Power Mode slows refresh to at least 5 seconds. History stays in memory for this session.")
                }
                Section("About these readings") {
                    Label("Battery charge and charging state", systemImage: "battery.75percent")
                    Label("Available storage and physical RAM", systemImage: "internaldrive")
                    Label("Thermal pressure reported by iOS", systemImage: "thermometer.medium")
                    Label("Wi-Fi and cellular interface traffic", systemImage: "network")
                    Text("Sense memory is the footprint of Sense itself. Physical RAM is capacity, not current system-wide usage. iOS does not provide this app with other apps’ process usage, battery health, or exact sensor temperatures.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Sense keeps these readings on your device. No account, analytics, or remote service is used.").font(.footnote).foregroundStyle(.secondary)
                    HStack { Text("Sense for iOS"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear session history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { monitor.clearHistory() }
            }
        }
    }
}
