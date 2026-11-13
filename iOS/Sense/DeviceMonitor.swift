import Darwin
import Foundation
import Network
import SwiftUI
import UIKit

@MainActor
final class DeviceMonitor: ObservableObject {
    @Published var battery: Float?
    @Published var batteryState = UIDevice.BatteryState.unknown
    @Published var thermal = ProcessInfo.ThermalState.nominal
    @Published var lowPower = false
    @Published var storageTotal: UInt64?
    @Published var storageFree: UInt64?
    @Published var appMemory: UInt64?
    @Published var traffic = TrafficRate()
    @Published var trafficAvailable = false
    @Published var connection = "Checking…"
    @Published var connected = false
    @Published var expensive = false
    @Published var constrained = false
    @Published var ipv6 = false
    @Published var history: [HistorySample] = []
    @Published var lastRead: Date?
    @Published var running = false
    @AppStorage("refreshInterval") var refreshInterval = 1.0
    private var pathMonitor: NWPathMonitor?
    private var task: Task<Void, Never>?
    private var sampler = RateSampler()
    private var lastStorageRead = Date.distantPast

    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()

    var deviceName: String { UIDevice.current.model }
    var osVersion: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }
    var totalRAM: UInt64 { ProcessInfo.processInfo.physicalMemory }
    var cores: Int { ProcessInfo.processInfo.processorCount }
    var effectiveInterval: Double { max(lowPower ? 5 : 1, [1.0, 2, 5].contains(refreshInterval) ? refreshInterval : 1) }
    var thermalName: String {
        switch thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
    var batteryDescription: String {
        switch batteryState {
        case .charging: "Charging"
        case .full: "Fully charged"
        case .unplugged: "On battery"
        case .unknown: "Not available"
        @unknown default: "Not available"
        }
    }

    func start() {
        guard !running else { return }
        running = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        sampler.reset()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let label = path.status != .satisfied ? "Offline" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "Cellular" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : "Connected"
            Task { @MainActor [weak self] in
                self?.connection = label
                self?.connected = path.status == .satisfied
                self?.expensive = path.isExpensive
                self?.constrained = path.isConstrained
                self?.ipv6 = path.supportsIPv6
            }
        }
        monitor.start(queue: DispatchQueue(label: "Sense.network-path", qos: .utility))
        pathMonitor = monitor
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                try? await Task.sleep(for: .seconds(self.effectiveInterval))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        pathMonitor?.cancel(); pathMonitor = nil
        running = false
        UIDevice.current.isBatteryMonitoringEnabled = false
        sampler.reset()
    }

    func clearHistory() { history = []; sampler.reset() }

    private func sample() {
        let now = Date()
        let level = UIDevice.current.batteryLevel
        battery = level >= 0 ? level : nil
        batteryState = UIDevice.current.batteryState
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        appMemory = Self.memoryFootprint()
        if now.timeIntervalSince(lastStorageRead) >= 30 {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
            storageTotal = (attributes?[.systemSize] as? NSNumber)?.uint64Value
            storageFree = (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value
            lastStorageRead = now
        }
        if let counters = Self.networkCounters() {
            trafficAvailable = sampler.previous != nil
            traffic = sampler.sample(TrafficReading(received: counters.0, sent: counters.1, date: now))
        } else { traffic = TrafficRate(); trafficAvailable = false; sampler.reset() }
        history.append(HistorySample(date: now, download: traffic.download, upload: traffic.upload, appMemory: appMemory))
        history = MetricFormat.trimHistory(history, now: now, seconds: 900)
        lastRead = now
    }

    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func networkCounters() -> (UInt64, UInt64)? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var seen = Set<String>()
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            defer { pointer = interface.ifa_next }
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard (name == "en0" || name.hasPrefix("pdp_ip")), seen.insert(name).inserted else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(stats.ifi_ibytes)
            sent += UInt64(stats.ifi_obytes)
        }
        return seen.isEmpty ? nil : (received, sent)
    }
}
