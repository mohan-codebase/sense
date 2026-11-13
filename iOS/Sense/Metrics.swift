import Foundation

struct TrafficReading: Equatable {
    var received: UInt64
    var sent: UInt64
    var date: Date
}

struct TrafficRate: Equatable {
    var download: Double = 0
    var upload: Double = 0
}

struct RateSampler {
    private(set) var previous: TrafficReading?
    mutating func sample(_ reading: TrafficReading) -> TrafficRate {
        defer { previous = reading }
        guard let previous else { return TrafficRate() }
        let interval = reading.date.timeIntervalSince(previous.date)
        guard interval > 0, reading.received >= previous.received, reading.sent >= previous.sent else { return TrafficRate() }
        return TrafficRate(download: Double(reading.received - previous.received) / interval,
                           upload: Double(reading.sent - previous.sent) / interval)
    }
    mutating func reset() { previous = nil }
}

struct HistorySample: Identifiable {
    let id = UUID()
    var date: Date
    var download: Double
    var upload: Double
    var appMemory: UInt64?
}

enum MetricFormat {
    static func bytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    static func rate(_ value: Double) -> (value: String, unit: String) {
        guard value.isFinite, value > 0 else { return ("0", "B/s") }
        if value >= 1_000_000 { return (String(format: "%.1f", value / 1_000_000), "MB/s") }
        if value >= 1_000 { return (String(format: "%.0f", value / 1_000), "KB/s") }
        return (String(format: "%.0f", value), "B/s")
    }

    static func usedFraction(total: UInt64?, free: UInt64?) -> Double? {
        guard let total, total > 0, let free else { return nil }
        return min(1, max(0, 1 - Double(free) / Double(total)))
    }

    static func trimHistory(_ samples: [HistorySample], now: Date, seconds: Double) -> [HistorySample] {
        Array(samples.filter { now.timeIntervalSince($0.date) <= seconds }.suffix(900))
    }
}
