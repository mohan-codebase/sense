import AppKit
import IOKit
import UserNotifications

@_silgen_name("IOHIDEventSystemClientCreate") func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") func IOHIDEventSystemClientSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") func IOHIDEventSystemClientCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent") func IOHIDServiceClientCopyEvent(_ s: AnyObject, _ t: Int64, _ m: Int32, _ o: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyProperty") func IOHIDServiceClientCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func IOHIDEventGetFloatValue(_ e: AnyObject, _ f: Int32) -> Double

/// Hottest die temperature in °C, or nil if sensors are unavailable.
func readTemperature() -> Double? { readSensors().die }

/// Die (CPU/SoC) max, plus battery and SSD temperatures in °C.
func readSensors() -> (die: Double?, battery: Double?, ssd: Double?) {
    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return (nil, nil, nil) }
    let match: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
    _ = IOHIDEventSystemClientSetMatching(client, match as CFDictionary)
    guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return (nil, nil, nil) }
    var die: [Double] = [], all: [Double] = [], batt: [Double] = [], ssd: [Double] = []
    for svc in services {
        guard let ev = IOHIDServiceClientCopyEvent(svc, 15, 0, 0)?.takeRetainedValue() else { continue }
        let t = IOHIDEventGetFloatValue(ev, 15 << 16)
        guard t > 0, t < 130 else { continue }
        all.append(t)
        let name = IOHIDServiceClientCopyProperty(svc, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
        if name.contains("tdie") { die.append(t) }
        if name.contains("battery") { batt.append(t) }
        if name.contains("NAND") { ssd.append(t) }
    }
    return ((die.isEmpty ? all : die).max(), batt.max(), ssd.max())
}

/// Bezier segments (start, control1, control2, end) through `pts`, clamped so they never overshoot neighbours.
func smoothSegments(_ pts: [NSPoint]) -> [(NSPoint, NSPoint, NSPoint, NSPoint)] {
    guard pts.count > 1 else { return [] }
    return (0..<pts.count - 1).map { i in
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        let lo = min(p1.y, p2.y), hi = max(p1.y, p2.y)
        var c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        var c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        c1.y = min(max(c1.y, lo), hi)
        c2.y = min(max(c2.y, lo), hi)
        return (p1, c1, c2, p2)
    }
}

/// Extends `path` (already at pts[0]) through all points with smooth curves.
func addSmoothCurve(to path: NSBezierPath, through pts: [NSPoint]) {
    for seg in smoothSegments(pts) { path.curve(to: seg.3, controlPoint1: seg.1, controlPoint2: seg.2) }
}

/// Strokes the smooth curve through `pts` with a colour that eases from `from` to `to` along its length.
func strokeGradient(through pts: [NSPoint], from: NSColor, to: NSColor, width: CGFloat) {
    let segments = smoothSegments(pts)
    for (i, seg) in segments.enumerated() {
        let path = NSBezierPath()
        path.move(to: seg.0)
        path.curve(to: seg.3, controlPoint1: seg.1, controlPoint2: seg.2)
        path.lineWidth = width
        path.lineCapStyle = .round
        (from.blended(withFraction: CGFloat(i) / CGFloat(max(segments.count - 1, 1)), of: to) ?? from).setStroke()
        path.stroke()
    }
}

typealias CPUTicks = (busy: UInt64, total: UInt64)

/// Mach returns unsigned counters in an array whose element type is signed.
func cpuTickValue(_ value: Int32) -> UInt64 {
    UInt64(UInt32(bitPattern: value))
}

/// Cumulative (busy, total) CPU ticks across all cores.
func cpuTicks() -> CPUTicks? {
    var cores: natural_t = 0
    var info: processor_info_array_t?
    var count: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count) == KERN_SUCCESS, let info else { return nil }
    defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
    guard cores > 0, Int(cores) <= Int(count) / Int(CPU_STATE_MAX) else { return nil }
    var busy: UInt64 = 0, idle: UInt64 = 0
    for c in 0..<Int(cores) {
        let b = c * Int(CPU_STATE_MAX)
        busy += cpuTickValue(info[b + Int(CPU_STATE_USER)]) + cpuTickValue(info[b + Int(CPU_STATE_SYSTEM)]) + cpuTickValue(info[b + Int(CPU_STATE_NICE)])
        idle += cpuTickValue(info[b + Int(CPU_STATE_IDLE)])
    }
    return (busy, busy + idle)
}

func cpuLoadFraction(from previous: CPUTicks, to current: CPUTicks) -> Double? {
    guard current.total > previous.total, current.busy >= previous.busy else { return nil }
    let totalDelta = current.total - previous.total
    let busyDelta = current.busy - previous.busy
    guard busyDelta <= totalDelta else { return nil }
    return Double(busyDelta) / Double(totalDelta)
}

struct MemStats {
    var total = 0.0, used = 0.0, cached = 0.0, swap = 0.0
    var app = 0.0, wired = 0.0, compressed = 0.0
    var pressure = 0.0   // 0...1, share of memory under pressure
    var level = 1        // 1 normal, 2 warning, 4 critical
    var pressureAvailable = false
}

/// Memory figures counted the way Activity Monitor's memory panel does.
func memoryStats() -> MemStats? {
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let ok = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard ok == KERN_SUCCESS else { return nil }
    let page = Double(sysconf(_SC_PAGESIZE))
    var m = MemStats()
    m.total = Double(ProcessInfo.processInfo.physicalMemory)
    m.app = (Double(vm.internal_page_count) - Double(vm.purgeable_count)) * page
    m.wired = Double(vm.wire_count) * page
    m.compressed = Double(vm.compressor_page_count) * page
    m.cached = (Double(vm.external_page_count) + Double(vm.purgeable_count)) * page
    // Memory Used = everything that is neither free nor file-backed cache (purgeable memory still counts as used).
    m.used = m.total - (Double(vm.free_count) + Double(vm.external_page_count)) * page
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { m.swap = Double(swap.xsu_used) }
    var free: Int32 = 100, size = MemoryLayout<Int32>.size
    let hasPressure = sysctlbyname("kern.memorystatus_level", &free, &size, nil, 0) == 0
    m.pressure = min(max(1 - Double(free) / 100, 0), 1)
    var level: Int32 = 1
    size = MemoryLayout<Int32>.size
    let hasLevel = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
    m.level = Int(level)
    m.pressureAvailable = hasPressure && hasLevel
    return m
}

/// Replica of Activity Monitor's memory panel: pressure graph, totals, and breakdown in one row.
final class MemoryPanel: NSView {
    var stats = MemStats()
    var history: [Double] = []
    var levels: [Int] = []
    var sampleTimes: [TimeInterval] = []
    var windowEnd: TimeInterval = 0
    static var windowDuration: TimeInterval { Preferences.shared.range }
    override var isFlipped: Bool { true }
    private var graphRect = NSRect.zero
    private var hovering = false
    private var hoverX: CGFloat = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverX = p.x
        hovering = graphRect.insetBy(dx: -6, dy: -6).contains(p)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    /// Rendering trails sampling by one second, so the latest edge can move along
    /// the line between two measured values instead of jumping on each timer tick.
    func advanceTimeline(to now: TimeInterval) {
        windowEnd = now - 1
        let region = NSRect(x: 16, y: 32, width: max(bounds.width - 32, 0), height: 62)
        setNeedsDisplay(region)
    }

    private var tint: NSColor { Self.palette(stats.level).stroke }

    /// Pressure bands retain the status recorded for each sample.
    static func palette(_ level: Int) -> (top: NSColor, bottom: NSColor, stroke: NSColor) {
        let status = HealthState.memoryPressure(level)
        return (status.fill.withAlphaComponent(0.75), status.fill.withAlphaComponent(0.34), status.chartInk)
    }

    static func drawPressureArea(through curve: [NSPoint], levels lv: [Int], in g: NSRect) {
        // The newest sample may lie just beyond the visible edge. Clipping the
        // measured line gives smooth movement without adding synthetic samples.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: g).addClip()
        func band(_ level: Int) -> Int { level >= 4 ? 4 : level >= 2 ? 2 : 1 }
        var start = 0
        while start < curve.count {
            var end = start
            while end + 1 < curve.count, band(lv[end + 1]) == band(lv[start]) { end += 1 }
            let last = min(end + 1, curve.count - 1)   // overlap one point so runs meet without a gap
            let colours = palette(lv[start])
            let poly = NSBezierPath()
            poly.move(to: NSPoint(x: curve[start].x, y: g.maxY))
            for k in start...last { poly.line(to: curve[k]) }
            poly.line(to: NSPoint(x: curve[last].x, y: g.maxY))
            poly.close()
            NSGraphicsContext.saveGraphicsState()
            poly.addClip()
            NSGradient(colors: [colours.top, colours.bottom])?.draw(from: NSPoint(x: 0, y: g.minY), to: NSPoint(x: 0, y: g.maxY), options: [])
            NSGraphicsContext.restoreGraphicsState()
            // Bright outline: the top line and bottom edge of this run. The ends of the whole chart are closed,
            // but there is no vertical line where one colour hands over to the next.
            colours.stroke.setStroke()
            let top = NSBezierPath()
            top.move(to: curve[start])
            for k in start...last { top.line(to: curve[k]) }
            top.lineWidth = 1
            top.stroke()
            let bottom = NSBezierPath()
            bottom.move(to: NSPoint(x: curve[start].x, y: g.maxY - 0.5))
            bottom.line(to: NSPoint(x: curve[last].x, y: g.maxY - 0.5))
            bottom.lineWidth = 1
            bottom.stroke()
            if start == 0 {
                let side = NSBezierPath()
                side.move(to: NSPoint(x: curve[0].x, y: g.maxY - 0.5))
                side.line(to: curve[0])
                side.lineWidth = 1
                side.stroke()
            }
            if last == curve.count - 1 {
                let side = NSBezierPath()
                side.move(to: NSPoint(x: curve[last].x, y: g.maxY - 0.5))
                side.line(to: curve[last])
                side.lineWidth = 1
                side.stroke()
            }
            start = end + 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func gb(_ b: Double) -> String { String(format: "%.2f GB", b / 1_073_741_824) }
    private func swap(_ b: Double) -> String { b >= 1_073_741_824 ? gb(b) : String(format: "%.1f MB", b / 1_048_576) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 12, dy: 4)

        drawCard(r, radius: 11)

        // Top: pressure graph across the full width
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSAttributedString(string: "MEMORY PRESSURE · LIVE (\(Preferences.shared.rangeLabel.uppercased()))", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
                           .foregroundColor: NSColor.cardSecondary, .paragraphStyle: style])
            .draw(in: NSRect(x: r.minX, y: r.minY + 8, width: r.width, height: 13))
        line(NSPoint(x: r.minX + 14, y: r.minY + 25), NSPoint(x: r.maxX - 14, y: r.minY + 25))
        let g = NSRect(x: r.minX + 10, y: r.minY + 30, width: r.width - 20, height: 56)
        graphRect = g
        let pts = history.isEmpty && stats.pressureAvailable ? [stats.pressure] : history
        let lv = levels.count == pts.count ? levels : [Int](repeating: stats.level, count: pts.count)
        let curve: [NSPoint] = pts.enumerated().map { i, v in
            let fraction = sampleTimes.count == pts.count
                ? 1 - (windowEnd - sampleTimes[i]) / Self.windowDuration
                : (pts.count == 1 ? 1 : Double(i) / Double(pts.count - 1))
            return NSPoint(x: g.minX + g.width * CGFloat(fraction),
                           y: g.maxY - max(g.height * CGFloat(v), 3))
        }
        Self.drawPressureArea(through: curve, levels: lv, in: g)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: g).addClip()
        if let latest = curve.last {
            Self.palette(lv.last ?? stats.level).stroke.setFill()
            NSBezierPath(ovalIn: NSRect(x: latest.x - 1.5, y: latest.y - 1.5, width: 3, height: 3)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if hovering, curve.count > 1 {
            let k = curve.indices.min { abs(curve[$0].x - hoverX) < abs(curve[$1].x - hoverX) } ?? 0
            let pt = curve[k]
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: pt.x, y: g.minY))
            guide.line(to: NSPoint(x: pt.x, y: g.maxY))
            guide.setLineDash([2, 2], count: 2, phase: 0)
            guide.lineWidth = 0.75
            NSColor.tertiaryLabelColor.setStroke()
            guide.stroke()
            tint.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)).fill()
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)).fill()
            let label = NSAttributedString(string: String(format: "Pressure %.0f%%", pts[k] * 100), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.cardLabel])
            let w = label.size().width + 12
            let pill = NSRect(x: min(max(pt.x - w / 2, g.minX), g.maxX - w), y: r.minY + 6, width: w, height: 16)
            NSColor.cardSurface.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2))
        }
        let top = g.maxY + 8
        line(NSPoint(x: r.minX, y: top), NSPoint(x: r.maxX, y: top))

        // Animation invalidates only the graph; skip formatting the table on those frames.
        guard dirtyRect.maxY >= top else { return }
        // Below: one table, top to bottom
        let rows: [(String, String)] = [
            ("Physical Memory:", gb(stats.total)), ("Memory Used:", gb(stats.used)),
            ("Cached Files:", gb(stats.cached)), ("Swap Used:", swap(stats.swap)),
            ("App Memory:", gb(stats.app)), ("Wired Memory:", gb(stats.wired)), ("Compressed:", gb(stats.compressed))]
        let rowH = (r.maxY - top - 4) / CGFloat(rows.count)
        for (i, row) in rows.enumerated() {
            let y = top + 2 + rowH * CGFloat(i)
            let cell = NSRect(x: r.minX + 14, y: y, width: r.width - 28, height: rowH)
            text(row.0, in: cell, align: .left, color: i == 0 || i >= 4 ? .cardLabel : .cardSecondary)
            text(row.1, in: cell, align: .right, color: i == 0 ? .cardLabel : .cardSecondary)
            if i < rows.count - 1 { line(NSPoint(x: r.minX + 10, y: y + rowH), NSPoint(x: r.maxX - 10, y: y + rowH)) }
        }
    }

    private func line(_ a: NSPoint, _ b: NSPoint) {
        let p = NSBezierPath()
        p.move(to: a); p.line(to: b)
        NSColor.cardSeparator.setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    private func text(_ s: String, in cell: NSRect, align: NSTextAlignment, color: NSColor, font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let str = NSAttributedString(string: s, attributes: [.font: font,
                                                              .foregroundColor: color, .paragraphStyle: style])
        let h = str.size().height
        str.draw(in: NSRect(x: cell.minX, y: cell.minY + (cell.height - h) / 2, width: cell.width, height: h))
    }

    private func centered(_ s: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]).draw(in: rect)
    }
}

/// GPU busy fraction (0...1) from the accelerator's performance statistics.
func gpuUtilization() -> Double? {
    guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(it) }
    var best: Double?
    while true {
        let svc = IOIteratorNext(it)
        if svc == 0 { break }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any],
              let perf = d["PerformanceStatistics"] as? [String: Any],
              let util = perf["Device Utilization %"] as? Int, (0...100).contains(util) else { continue }
        best = max(best ?? 0, Double(util) / 100)
    }
    return best
}

typealias NetworkCounters = [String: (rx: UInt32, tx: UInt32)]

/// Cumulative bytes received and sent, keyed by Ethernet or Wi-Fi interface.
func netBytes() -> NetworkCounters {
    var counters: NetworkCounters = [:]
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return counters }
    defer { freeifaddrs(head) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = p {
        let name = String(cString: ifa.pointee.ifa_name)
        if name.hasPrefix("en"), ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = ifa.pointee.ifa_data {
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        p = ifa.pointee.ifa_next
    }
    return counters
}

struct NetworkSampler {
    private var previous: (counters: NetworkCounters, time: TimeInterval)?
    private var rates: (down: Double, up: Double) = (0, 0)

    mutating func sample(_ counters: NetworkCounters, at time: TimeInterval) -> (down: Double, up: Double) {
        guard !counters.isEmpty else {
            previous = nil
            rates = (0, 0)
            return rates
        }
        guard let previous else {
            self.previous = (counters: counters, time: time)
            rates = (0, 0)
            return rates
        }
        let elapsed = time - previous.time
        guard elapsed >= 0.1 else { return rates }
        self.previous = (counters: counters, time: time)
        var received: UInt64 = 0, sent: UInt64 = 0
        for (name, current) in counters {
            guard let last = previous.counters[name] else { continue }
            // A decrease can be a reset or rollover. Rebaseline that direction.
            if current.rx >= last.rx { received += UInt64(current.rx - last.rx) }
            if current.tx >= last.tx { sent += UInt64(current.tx - last.tx) }
        }
        rates = (Double(received) / elapsed, Double(sent) / elapsed)
        return rates
    }
}

func diskSpace() -> (free: Double, total: Double)? {
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
          let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
    return (Double(free), Double(total))
}

/// The chip of the Mac this runs on, as a short label for the menu bar: "M4", "M2 Pro", "M3 Max", "i7"…
func chipName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return shortChipName(from: String(cString: buf))
}

/// Turns a CPU brand string into a short label. Kept separate so it can be tested with other Macs' strings.
func shortChipName(from brand: String) -> String {
    let b = brand.trimmingCharacters(in: .whitespaces)
    // Apple silicon: "Apple M4", "Apple M2 Pro", "Apple M3 Max", "Apple M2 Ultra" (and future generations)
    if b.hasPrefix("Apple ") {
        let rest = String(b.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.lowercased().contains("processor") || rest.lowercased().contains("virtual") ? "Apple" : rest
    }
    // Intel Macs: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", "Intel(R) Xeon(R) W-3245 CPU @ 3.20GHz"
    if b.contains("Intel") {
        if let r = b.range(of: #"\bi[3579]\b"#, options: .regularExpression) ?? b.range(of: #"\bi[3579](?=-)"#, options: .regularExpression) {
            return String(b[r])
        }
        if b.contains("Xeon") { return "Xeon" }
        if b.contains("Core") && b.contains("m3") { return "Core m" }
        return "Intel"
    }
    return b.isEmpty ? "Mac" : String(b.prefix(8))
}

func rate(_ bytesPerSec: Double) -> (String, String) {
    if bytesPerSec >= 1_000_000 { return (String(format: "%.1f", bytesPerSec / 1_000_000), "MB/s") }
    if bytesPerSec >= 1000 { return (String(format: "%.0f", bytesPerSec / 1000), "KB/s") }
    return (String(format: "%.0f", bytesPerSec), "B/s")
}

private func rgbColor(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

private func appearanceColor(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
        rgbColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    }
}

private func neutralColor(light: UInt8, dark: UInt8) -> NSColor {
    appearanceColor(light: UInt32(light) * 0x010101, dark: UInt32(dark) * 0x010101)
}

/// Neutral dashboard surfaces, text, and chart tones.
extension NSColor {
    static let cardSurface = neutralColor(light: 0xFF, dark: 0x2D)
    static let badgeSurface = neutralColor(light: 0xF0, dark: 0x39)
    static let cardSeparator = neutralColor(light: 0xDE, dark: 0x42)
    static let cardLabel = neutralColor(light: 0x20, dark: 0xF4)
    static let cardSecondary = neutralColor(light: 0x45, dark: 0xB8)
    static let chartInk = neutralColor(light: 0x65, dark: 0xAE)
    static let emphasisInk = neutralColor(light: 0x40, dark: 0xD6)
}

func loadInk(_ load: Double) -> NSColor {
    switch HealthState.utilization(load) {
    case .normal: .chartInk
    case .warning: .emphasisInk
    case .critical: .cardLabel
    }
}

enum HealthState: Equatable {
    case normal, warning, critical

    private static let greenChart = appearanceColor(light: 0x55BC7F, dark: 0x8DDAA9)
    fileprivate static let orangeChart = appearanceColor(light: 0xF2A15F, dark: 0xFFC08D)
    private static let redChart = appearanceColor(light: 0xEC8191, dark: 0xFFA0AE)

    var fill: NSColor {
        switch self {
        case .normal: rgbColor(0xC3EECC)
        case .warning: rgbColor(0xFFE0BC)
        case .critical: rgbColor(0xFFCCD1)
        }
    }

    var chartInk: NSColor {
        switch self {
        case .normal: Self.greenChart
        case .warning: Self.orangeChart
        case .critical: Self.redChart
        }
    }

    static func memoryPressure(_ level: Int) -> Self {
        if level >= 4 { return .critical }
        return level >= 2 ? .warning : .normal
    }

    static func utilization(_ load: Double) -> Self {
        if load >= 0.88 { return .critical }
        return load >= 0.70 ? .warning : .normal
    }

    var pressureLabel: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

func drawCard(_ rect: NSRect, radius: CGFloat = 13) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.60
    NSColor.cardSurface.withAlphaComponent(opacity).setFill()
    path.fill()
    NSColor.cardSeparator.setStroke()
    path.lineWidth = 0.5
    path.stroke()
}

/// Averages a history into at most the requested number of buckets.
func downsample(_ a: [Double], to n: Int) -> [Double] {
    downsample(a, to: n) { $0.reduce(0, +) / Double($0.count) }
}

func downsample<T>(_ a: [T], to n: Int, reduce: (ArraySlice<T>) -> T) -> [T] {
    guard a.count > n else { return a }
    let size = Double(a.count) / Double(n)
    return (0..<n).map { i in
        let lo = Int(Double(i) * size), hi = max(Int(Double(i + 1) * size), lo + 1)
        return reduce(a[lo..<min(hi, a.count)])
    }
}

/// "12 min ago" for point `k` of `n` drawn points that stand for `total` samples taken `every` seconds apart.
/// Per-bucket maximum, so a brief warning is not averaged away when a long history is shrunk to fit.
func downsampleLevels(_ a: [Int], to n: Int) -> [Int] {
    guard a.count > n else { return a }
    let size = Double(a.count) / Double(n)
    return (0..<n).map { i in
        let lo = Int(Double(i) * size), hi = max(Int(Double(i + 1) * size), lo + 1)
        return a[lo..<min(hi, a.count)].max() ?? 1
    }
}

func ago(_ k: Int, of n: Int, total: Int, every: Double = 5) -> String {
    let secs = Double(n - 1 - k) * Double(total) / Double(max(n, 1)) * every
    if secs < 5 { return "now" }
    if secs < 90 { return String(format: "%.0f s ago", secs) }
    if secs < 5400 { return String(format: "%.0f min ago", secs / 60) }
    return String(format: "%.1f h ago", secs / 3600)
}

struct PressureSample: Codable {
    var time: TimeInterval
    var value: Double
    var level: Int
}

/// Histories saved between launches (about an hour at one sample per 5 seconds).
struct SavedHistory: Codable {
    var saved = Date()
    var cpu: [Double] = []
    var gpu: [Double?] = []
    var mem: [Double] = [], down: [Double] = [], up: [Double] = [], pressure: [Double] = []
    var levels: [Int]?   // memory pressure level (1 normal, 2 warning, 4 critical) for each pressure sample
    var recentPressure: [PressureSample]? // timestamped, unaveraged live graph samples

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Sense")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        // Carry history over from the app's former names.
        if !FileManager.default.fileExists(atPath: file.path) {
            for former in ["Isa", "Kelvora", "Kelvin", "ThermalBar"] {
                let old = support.appendingPathComponent("\(former)/history.json")
                if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.copyItem(at: old, to: file); break }
            }
        }
        return file
    }
    static func load() -> SavedHistory? {
        guard let data = try? Data(contentsOf: url), let h = try? JSONDecoder().decode(SavedHistory.self, from: data),
              Date().timeIntervalSince(h.saved) < 3600 else { return nil }
        return h
    }
    func write() {
        var copy = self
        copy.saved = Date()
        if let data = try? JSONEncoder().encode(copy) { try? data.write(to: Self.url, options: .atomic) }
    }
}

struct BatteryInfo {
    var charge = 0, cycles = 0, designCycles = 1000
    var designMAh = 0, fullMAh = 0, remainingMAh = 0
    var charging = false, plugged = false
    var voltage = 0.0, watts = 0.0
    var minutes: Int?
    var adapter = ""
}

func batteryChargePercent(current: Int, maximum: Int) -> Int? {
    guard current >= 0, maximum > 0 else { return nil }
    return Int((Double(min(current, maximum)) / Double(maximum) * 100).rounded())
}

func batteryInfo() -> BatteryInfo? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = props?.takeRetainedValue() as? [String: Any],
          let current = (d["CurrentCapacity"] as? NSNumber)?.intValue,
          let maximum = (d["MaxCapacity"] as? NSNumber)?.intValue,
          let charge = batteryChargePercent(current: current, maximum: maximum) else { return nil }
    let data = d["BatteryData"] as? [String: Any] ?? [:]
    func int(_ dict: [String: Any], _ k: String) -> Int { (dict[k] as? NSNumber)?.intValue ?? 0 }
    var b = BatteryInfo()
    b.charge = charge
    b.cycles = int(d, "CycleCount")
    b.designCycles = max(int(d, "DesignCycleCount9C"), 1)
    b.designMAh = int(data, "DesignCapacity")
    b.fullMAh = int(data, "NominalChargeCapacity")
    b.remainingMAh = int(data, "RemainingCapacity")
    b.charging = (d["IsCharging"] as? Bool) ?? false
    b.plugged = (d["ExternalConnected"] as? Bool) ?? false
    b.voltage = Double(int(d, "Voltage")) / 1000
    let amps = Int64(truncatingIfNeeded: (d["Amperage"] as? NSNumber)?.uint64Value ?? 0)
    b.watts = b.voltage * Double(amps.magnitude) / 1000
    let t = int(d, "TimeRemaining")
    b.minutes = t > 0 && t < 65535 ? t : nil
    b.adapter = ((d["AdapterDetails"] as? [String: Any])?["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    return b
}

/// Apple's own health figures (what System Settings shows), read from System Profiler.
final class BatteryProfile {
    private(set) var maxCapacity = "–", condition = "–"
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPPowerDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            guard (try? p.run()) != nil else { return }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
                  let items = json["SPPowerDataType"] as? [[String: Any]] else { return }
            for item in items {
                guard let h = item["sppower_battery_health_info"] as? [String: Any] else { continue }
                let cap = h["sppower_battery_health_maximum_capacity"] as? String ?? "–"
                let cond = h["sppower_battery_health"] as? String ?? "–"
                DispatchQueue.main.async { self.maxCapacity = cap; self.condition = cond }
            }
        }
    }
}

struct Tile {
    enum Visual { case bars([Double]), spark([Double?]), dual([Double], [Double]), bar(Double) }
    var symbol: String
    var title: String
    var badge: String
    var value: String
    var unit: String
    var visual: Visual
    var footer: String
    var tint: NSColor
    var status: HealthState? = nil
    var chartState: HealthState? = nil
    var readouts: [String] = []   // text per sample, shown while hovering
    var value2 = "", unit2 = ""   // second reading for dual tiles (upload)
    var readouts2: [String] = []
    var wide = false              // spans both columns
    var chartTint: NSColor { (status ?? chartState)?.chartInk ?? tint }
}

/// Two-column grid of rounded dashboard tiles. Hovering a tile's graph shows a marker and the value at the cursor.
final class TileGrid: NSView {
    var tiles: [Tile] = [] {
        didSet {
            if tiles.map(\.title) != oldValue.map(\.title) || tiles.map(\.wide) != oldValue.map(\.wide) {
                updateHover(nil)
                needsLayout = true
            }
            surfaces.forEach { $0.content.needsDisplay = true }
        }
    }
    override var isFlipped: Bool { true }
    static let tileHeight: CGFloat = 104, gap: CGFloat = 8, pad: CGFloat = 12
    private static let cornerRadius: CGFloat = 13
    private var surfaces: [(material: NSView, content: TileContentView)] = []

    private var hover: Int?
    private var hoverX: CGFloat = 0
    private func rect(_ i: Int) -> NSRect {
        let w = (bounds.width - 2 * Self.pad - Self.gap) / 2
        var col = 0, row = 0
        for (n, t) in tiles.enumerated() {
            if t.wide, col == 1 { col = 0; row += 1 }
            let y = 6 + CGFloat(row) * (Self.tileHeight + Self.gap)
            let r = t.wide ? NSRect(x: Self.pad, y: y, width: bounds.width - 2 * Self.pad, height: Self.tileHeight)
                           : NSRect(x: Self.pad + CGFloat(col) * (w + Self.gap), y: y, width: w, height: Self.tileHeight)
            if n == i { return r }
            if t.wide { col = 0; row += 1 } else { col += 1; if col == 2 { col = 0; row += 1 } }
        }
        return .zero
    }

    var requiredHeight: CGFloat { tiles.indices.last.map { rect($0).maxY + 6 } ?? 12 }

    override func layout() {
        super.layout()
        while surfaces.count > tiles.count {
            surfaces.removeLast().material.removeFromSuperview()
        }
        while surfaces.count < tiles.count {
            let content = TileContentView(grid: self, index: surfaces.count)
            let material: NSView
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = Self.cornerRadius
                glass.contentView = content
                material = glass
            } else {
                let frost = NSVisualEffectView()
                frost.material = .popover
                frost.blendingMode = .withinWindow
                frost.state = .active
                frost.wantsLayer = true
                frost.layer?.cornerRadius = Self.cornerRadius
                frost.layer?.masksToBounds = true
                content.frame = frost.bounds
                content.autoresizingMask = [.width, .height]
                frost.addSubview(content)
                material = frost
            }
            addSubview(material)
            surfaces.append((material, content))
        }
        for (index, surface) in surfaces.enumerated() {
            let frame = rect(index)
            if surface.material.frame != frame { surface.material.frame = frame }
        }
    }

    // The material views are decorative. Keep graph events with the grid.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverX = p.x
        let now = tiles.indices.first { i in
            let r = rect(i)
            return NSRect(x: r.minX + 8, y: r.minY + 56, width: r.width - 16, height: 38).contains(p)
        }
        updateHover(now)
    }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    private func updateHover(_ index: Int?) {
        let previous = hover
        hover = index
        if let previous, previous != index, surfaces.indices.contains(previous) {
            surfaces[previous].content.needsDisplay = true
        }
        if let index, surfaces.indices.contains(index) {
            surfaces[index].content.needsDisplay = true
        }
    }

    // MARK: drawing

    private func tinted(_ symbol: String, _ color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) else { return nil }
        return NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    /// Two side-by-side readings (download / upload), each with its own value and graph.
    private func drawDual(_ t: Tile, _ down: [Double], _ up: [Double], hoverX: CGFloat?, in r: NSRect) {
        let inset: CGFloat = 12, gutter: CGFloat = 16
        let half = (r.width - 2 * inset - gutter) / 2
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: r.midX, y: r.minY + 32))
        divider.line(to: NSPoint(x: r.midX, y: r.maxY - 11))
        NSColor.cardSeparator.setStroke()
        divider.lineWidth = 0.5
        divider.stroke()

        let sides: [(String, String, String, [Double], [String], NSColor, String)] = [
            (t.value, t.unit, "↓ Download", down, t.readouts, t.chartTint, "↓"),
            (t.value2, t.unit2, "↑ Upload", up, t.readouts2, HealthState.orangeChart, "↑")]
        for (k, side) in sides.enumerated() {
            let x0 = r.minX + inset + CGFloat(k) * (half + gutter)
            let big = NSAttributedString(string: side.0, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.cardLabel])
            big.draw(at: NSPoint(x: x0, y: r.minY + 30))
            NSAttributedString(string: side.1, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.cardSecondary])
                .draw(at: NSPoint(x: x0 + big.size().width + 3, y: r.minY + 40))

            let v = NSRect(x: x0, y: r.minY + 65, width: half, height: 15)
            let pts: [NSPoint] = side.3.enumerated().map { i, f in
                NSPoint(x: v.minX + v.width * CGFloat(side.3.count < 2 ? 1 : Double(i) / Double(side.3.count - 1)),
                        y: v.maxY - max(v.height * CGFloat(min(f, 1)), 1))
            }
            if let first = pts.first {
                let line = NSBezierPath()
                line.move(to: first)
                addSmoothCurve(to: line, through: pts)
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: pts.last!.x, y: v.maxY))
                area.line(to: NSPoint(x: first.x, y: v.maxY))
                area.close()
                side.5.withAlphaComponent(0.26).setFill()
                area.fill()
                strokeGradient(through: pts, from: side.5, to: side.5, width: 2.0)
            }
            var footer = side.2
            if let hoverX, hoverX >= x0 - gutter / 2, hoverX < x0 + half + gutter / 2, pts.count > 1 {
                let idx = min(max(Int(((hoverX - v.minX) / v.width * CGFloat(pts.count - 1)).rounded()), 0), pts.count - 1)
                let p = pts[idx]
                let guide = NSBezierPath()
                guide.move(to: NSPoint(x: p.x, y: v.minY - 2))
                guide.line(to: NSPoint(x: p.x, y: v.maxY))
                guide.setLineDash([2, 2], count: 2, phase: 0)
                guide.lineWidth = 0.75
                NSColor.tertiaryLabelColor.setStroke()
                guide.stroke()
                side.5.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
                side.5.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
                if idx < side.4.count { footer = "\(side.6) at cursor · " + side.4[idx] }
            }
            NSAttributedString(string: footer, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.cardSecondary])
                .draw(at: NSPoint(x: x0, y: r.minY + 86))
        }
    }

    fileprivate func drawTile(at index: Int, in r: NSRect) {
        guard tiles.indices.contains(index) else { return }
        let t = tiles[index]
        let localHoverX = hover == index ? hoverX - rect(index).minX : nil
        let chartTint = t.chartTint
        let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.22
        NSColor.cardSurface.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: r, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()

        func text(_ s: String, _ font: NSFont, _ color: NSColor, left: CGFloat? = nil, right: CGFloat? = nil, y: CGFloat) {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            a.draw(at: NSPoint(x: left ?? (right! - a.size().width), y: y))
        }
        let inset: CGFloat = 12
        if let icon = tinted(t.symbol, t.tint) {
            let slot = NSRect(x: r.minX + inset, y: r.minY + 10, width: 15, height: 15)
            let scale = min(slot.width / icon.size.width, slot.height / icon.size.height, 1)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.draw(in: NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2, width: size.width, height: size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        text(t.title, .systemFont(ofSize: 11, weight: .medium), .cardLabel, left: r.minX + inset + 21, y: r.minY + 10)

        let badgeInk = t.status == nil ? NSColor.cardSecondary : NSColor(white: 0.18, alpha: 1)
        let badge = NSAttributedString(string: t.badge, attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: badgeInk])
        let bw = badge.size().width + 12
        let pill = NSRect(x: r.maxX - inset - bw, y: r.minY + 9, width: bw, height: 16)
        (t.status?.fill ?? .badgeSurface).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        badge.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2))

        if case .dual(let down, let up) = t.visual {
            drawDual(t, down, up, hoverX: localHoverX, in: r)
            return
        }
        let big = NSAttributedString(string: t.value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.cardLabel])
        big.draw(at: NSPoint(x: r.minX + inset, y: r.minY + 30))
        text(t.unit, .systemFont(ofSize: 11, weight: .regular), .cardSecondary, left: r.minX + inset + big.size().width + 3, y: r.minY + 40)

        let v = NSRect(x: r.minX + inset, y: r.minY + 65, width: r.width - 2 * inset, height: 15)
        var footer = t.footer
        let idxAt: (Int) -> Int = { n in
            guard let localHoverX, n > 1 else { return -1 }
            return min(max(Int(((localHoverX - v.minX) / v.width * CGFloat(n - 1)).rounded()), 0), n - 1)
        }

        switch t.visual {
        case .bars(let values):
            let n = max(values.count, 1)
            let gapW: CGFloat = 3
            let bw = (v.width - gapW * CGFloat(n - 1)) / CGFloat(n)
            let focus = idxAt(values.count)
            for (i, f) in values.enumerated() {
                let hgt = max(v.height * CGFloat(min(f, 1)), 1.5)
                chartTint.withAlphaComponent(i == focus ? 1 : 0.92 + 0.08 * CGFloat(min(f, 1))).setFill()
                NSBezierPath(roundedRect: NSRect(x: v.minX + CGFloat(i) * (bw + gapW), y: v.maxY - hgt, width: bw, height: hgt), xRadius: 1.5, yRadius: 1.5).fill()
            }
            if focus >= 0, focus < t.readouts.count, !t.readouts[focus].isEmpty { footer = "at cursor · " + t.readouts[focus] }
        case .spark(let values):
            let pts: [NSPoint?] = values.enumerated().map { i, value in
                value.map { fraction in
                    NSPoint(x: v.minX + v.width * CGFloat(values.count < 2 ? 1 : Double(i) / Double(values.count - 1)),
                            y: v.maxY - max(v.height * CGFloat(min(fraction, 1)), 1))
                }
            }
            for segment in pts.split(whereSeparator: { $0 == nil }) {
                let points = segment.compactMap { $0 }
                guard let first = points.first, let last = points.last else { continue }
                let fill = NSBezierPath()
                fill.move(to: first)
                addSmoothCurve(to: fill, through: points)
                fill.line(to: NSPoint(x: last.x, y: v.maxY))
                fill.line(to: NSPoint(x: first.x, y: v.maxY))
                fill.close()
                chartTint.withAlphaComponent(0.26).setFill()
                fill.fill()
                strokeGradient(through: points, from: chartTint, to: chartTint, width: 2.0)
            }
            let k = idxAt(pts.count)
            if k >= 0 {
                guard let p = pts[k] else { break }
                let guide = NSBezierPath()
                guide.move(to: NSPoint(x: p.x, y: v.minY - 2))
                guide.line(to: NSPoint(x: p.x, y: v.maxY))
                guide.setLineDash([2, 2], count: 2, phase: 0)
                guide.lineWidth = 0.75
                NSColor.tertiaryLabelColor.setStroke()
                guide.stroke()
                chartTint.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
                chartTint.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
                if k < t.readouts.count { footer = "at cursor · " + t.readouts[k] }
            }
        case .dual:
            break   // drawn by drawDual
        case .bar(let f):
            let track = NSRect(x: v.minX, y: v.midY - 4, width: v.width, height: 8)
            NSColor.cardSeparator.setFill()
            NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
            var fill = track
            fill.size.width = max(track.width * CGFloat(min(max(f, 0), 1)), 8)
            chartTint.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
        }
        text(footer, .systemFont(ofSize: 10.5), .cardSecondary, left: r.minX + inset, y: r.minY + 86)
    }
}

private final class TileContentView: NSView {
    private weak var grid: TileGrid?
    private let index: Int
    override var isFlipped: Bool { true }

    init(grid: TileGrid, index: Int) {
        self.grid = grid
        self.index = index
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        grid?.drawTile(at: index, in: bounds)
    }
}

/// Clickable section header with a chevron. Clicking toggles its table; the summary shows while collapsed.
final class DisclosureHeader: NSView {
    var title = "" { didSet { setAccessibilityLabel(title) } }
    var summary = "" { didSet { needsDisplay = true; updateAccessibility() } }
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateAccessibility() {
        setAccessibilityValue((expanded ? "Expanded" : "Collapsed") + (summary.isEmpty ? "" : ", " + summary))
        setAccessibilityHelp("Show or hide " + title.lowercased() + " details")
    }
    override func accessibilityPerformPress() -> Bool {
        setExpanded(!expanded)
        onToggle?(expanded)
        return true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    private(set) var expanded = false

    /// Closes or opens the header without firing `onToggle` (used when another section takes over).
    func setExpanded(_ value: Bool) {
        expanded = value
        updateAccessibility()
        needsDisplay = true
    }
    var onToggle: ((Bool) -> Void)?
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        _ = accessibilityPerformPress()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 18, dy: 0)
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
        if let chevron = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                chevron.draw(in: rect)
                NSColor.cardSecondary.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: r.minX, y: bounds.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.cardLabel])
        t.draw(at: NSPoint(x: r.minX + 18, y: bounds.midY - t.size().height / 2))
        if !expanded, !summary.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.cardSecondary]
            let room = r.width - 18 - t.size().width - 14
            var text = summary
            while text.count > 1, NSAttributedString(string: text, attributes: attrs).size().width > room { text.removeLast() }
            if text != summary { text = text.trimmingCharacters(in: .whitespaces) + "…" }
            let a = NSAttributedString(string: text, attributes: attrs)
            a.draw(at: NSPoint(x: r.maxX - a.size().width, y: bounds.midY - a.size().height / 2))
        }
    }
}

/// Plain two-column detail table with dividers.
final class KeyValueTable: NSView {
    var rows: [(String, String)] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 12, dy: 4)
        drawCard(r, radius: 11)
        guard !rows.isEmpty else { return }
        let rowH = (r.height - 8) / CGFloat(rows.count)
        let font = NSFont.systemFont(ofSize: 11.5)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        for (i, row) in rows.enumerated() {
            let y = r.minY + 4 + rowH * CGFloat(i)
            let l = NSAttributedString(string: row.0, attributes: [.font: font, .foregroundColor: NSColor.cardLabel])
            let v = NSAttributedString(string: row.1, attributes: [.font: digits, .foregroundColor: NSColor.cardSecondary])
            l.draw(at: NSPoint(x: r.minX + 14, y: y + (rowH - l.size().height) / 2))
            v.draw(at: NSPoint(x: r.maxX - 14 - v.size().width, y: y + (rowH - v.size().height) / 2))
            if i < rows.count - 1 {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: r.minX + 10, y: y + rowH))
                line.line(to: NSPoint(x: r.maxX - 10, y: y + rowH))
                NSColor.cardSeparator.setStroke()
                line.lineWidth = 1
                line.stroke()
            }
        }
    }
}

struct ProcRow {
    var pid: pid_t
    var name: String
    var bytes: Double   // physical footprint, same measure as Activity Monitor's Memory column
    var cpu: Double     // percent of one core since the previous sample
    var startedAt: UInt64 = 0

    func isSameProcess(as other: ProcRow) -> Bool { pid == other.pid && startedAt == other.startedAt }
}

/// Check the process's start time before acting: macOS can reuse an exited PID.
enum ProcessControl {
    enum Failure: LocalizedError {
        case protectedProcess, noLongerRunning, identityChanged, denied, failed(String)
        var errorDescription: String? {
            switch self {
            case .protectedProcess: return "Use Quit Sense to close Sense. System processes with PID 0 or 1 cannot be ended here."
            case .noLongerRunning: return "This process has already exited."
            case .identityChanged: return "The process has changed since it was selected. Select it again from the refreshed list."
            case .denied: return "macOS does not allow Sense to end this process."
            case .failed(let message): return message
            }
        }
    }
    static func validate(_ row: ProcRow) throws {
        guard row.pid > 1, row.pid != getpid() else { throw Failure.protectedProcess }
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(row.pid, RUSAGE_INFO_CURRENT, $0) }
        }
        guard result == 0 else {
            if errno == EPERM || errno == EACCES { throw Failure.denied }
            throw Failure.noLongerRunning
        }
        guard row.startedAt != 0, info.ri_proc_start_abstime == row.startedAt else { throw Failure.identityChanged }
    }
    static func end(_ row: ProcRow, force: Bool) throws {
        try validate(row)
        if !force, let app = NSRunningApplication(processIdentifier: row.pid), app.activationPolicy == .regular {
            guard app.terminate() else { throw Failure.failed("The app did not accept the quit request. You can select it again and choose Force Quit.") }
            return
        }
        guard kill(row.pid, force ? SIGKILL : SIGTERM) == 0 else {
            if errno == EPERM || errno == EACCES { throw Failure.denied }
            if errno == ESRCH { throw Failure.noLongerRunning }
            throw Failure.failed(String(cString: strerror(errno)))
        }
    }
}

/// Samples per-process memory footprint and CPU time through libproc.
final class ProcessSampler {
    private var prevTicks: [pid_t: UInt64] = [:]
    private var prevTime = Date()
    private var last: [ProcRow] = []
    private var names: [pid_t: (startedAt: UInt64, name: String)] = [:]
    private var timebase = mach_timebase_info_data_t()

    init() { mach_timebase_info(&timebase) }

    func top(_ n: Int) -> [ProcRow] {
        let now = Date()
        let elapsed = now.timeIntervalSince(prevTime)
        if elapsed < 0.4, !last.isEmpty { return last }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return last }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var ticks: [pid_t: UInt64] = [:]
        var rows: [ProcRow] = []
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var info = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
            }
            guard ok == 0 else { continue }
            let t = info.ri_user_time + info.ri_system_time
            ticks[pid] = t
            var cpu = 0.0
            if let p = prevTicks[pid], t >= p, elapsed > 0 {
                cpu = Double(t - p) * Double(timebase.numer) / Double(timebase.denom) / (elapsed * 1e9) * 100
            }
            rows.append(ProcRow(pid: pid, name: "", bytes: Double(info.ri_phys_footprint), cpu: cpu, startedAt: info.ri_proc_start_abstime))
        }
        prevTicks = ticks
        prevTime = now
        var top = Array(rows.sorted { $0.bytes > $1.bytes }.prefix(n))
        for k in top.indices {
            let pid = top[k].pid
            if let cached = names[pid], cached.startedAt == top[k].startedAt { top[k].name = cached.name; continue }
            var buf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buf, 256)
            let raw = NSRunningApplication(processIdentifier: pid)?.localizedName ?? String(cString: buf)
            let clean = raw.filter { !$0.unicodeScalars.contains { $0.properties.generalCategory == .format } }
            names[pid] = (top[k].startedAt, clean)
            top[k].name = clean
        }
        if names.count > 2000 { names = names.filter { ticks[$0.key] != nil } }   // drop entries for exited processes
        last = top
        return top
    }
}

struct SensorRow {
    var name: String
    var value: String
    var status: String
    var health: HealthState?
}

/// Table of temperatures and thermal pressure: name, reading, status.
final class SensorTable: NSView {
    var rows: [SensorRow] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 12, dy: 4)
        drawCard(r, radius: 11)

        let valueRight = r.maxX - 118
        func put(_ s: String, right: CGFloat? = nil, left: CGFloat? = nil, y: CGFloat, font: NSFont, color: NSColor) {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            a.draw(at: NSPoint(x: right.map { $0 - a.size().width } ?? left ?? 0, y: y))
        }
        let head = NSFont.systemFont(ofSize: 11, weight: .semibold)
        put("Sensors", left: r.minX + 14, y: r.minY + 11, font: head, color: .cardSecondary)
        put("Reading", right: valueRight, y: r.minY + 11, font: head, color: .cardLabel)
        put("Status", left: valueRight + 16, y: r.minY + 11, font: head, color: .cardSecondary)

        let rowH: CGFloat = 26
        let name = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for (i, row) in rows.enumerated() {
            let y = r.minY + 36 + rowH * CGFloat(i)
            put(row.name, left: r.minX + 14, y: y, font: name, color: .cardLabel)
            put(row.value, right: valueRight, y: y, font: digits, color: .cardSecondary)
            let dot = NSBezierPath(ovalIn: NSRect(x: valueRight + 16, y: y + 4.5, width: 8, height: 8))
            (row.health?.fill ?? .badgeSurface).setFill()
            dot.fill()
            NSColor.cardSecondary.withAlphaComponent(0.6).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            put(row.status, left: valueRight + 30, y: y, font: .systemFont(ofSize: 12), color: .cardSecondary)
        }
    }
}

private final class ProcessAccessibilityRow: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// "Top Processes" table: select a process to review quit actions.
final class ProcessTable: NSView {
    var rows: [ProcRow] = [] {
        didSet {
            clampOffset()
            if let selectedProcess, !rows.contains(where: { $0.isSameProcess(as: selectedProcess) }) { self.selectedProcess = nil }
            needsDisplay = true
        }
    }
    var onActivate: ((ProcRow) -> Void)?
    private var selectedProcess: ProcRow?
    private var pressedProcess: ProcRow?
    var sortsByCPU = false {
        didSet {
            if oldValue != sortsByCPU { scrollToTop() }
            needsDisplay = true
        }
    }
    func scrollToTop() { offset = 0; needsDisplay = true }
    override var isFlipped: Bool { true }

    private let rowH: CGFloat = 26
    private let visibleRows = 7
    private var offset: CGFloat = 0   // scroll position in points; there is deliberately no scroll bar

    private var maxOffset: CGFloat { max(CGFloat(rows.count - visibleRows) * rowH, 0) }
    private func clampOffset() { offset = min(max(offset, 0), maxOffset) }

    /// Trackpad and wheel scrolling move the list; no scroll bar is drawn.
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        offset -= delta
        clampOffset()
        needsDisplay = true
    }

    private var rowsTop: CGFloat { bounds.minY + 40 }
    private var rowsViewport: NSRect { NSRect(x: 13, y: rowsTop - 2, width: bounds.width - 26, height: rowH * CGFloat(visibleRows) + 2) }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(rowsViewport, cursor: .pointingHand)
    }

    func process(at point: NSPoint) -> ProcRow? {
        guard rowsViewport.contains(point), point.y >= rowsTop else { return nil }
        let index = Int(floor((point.y - rowsTop + offset) / rowH))
        return rows.indices.contains(index) ? rows[index] : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        pressedProcess = process(at: convert(event.locationInWindow, from: nil))
        selectedProcess = pressedProcess
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedProcess = nil }
        guard let pressedProcess, let row = process(at: convert(event.locationInWindow, from: nil)), row.isSameProcess(as: pressedProcess) else { return }
        onActivate?(pressedProcess)
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Processes. Select a process to end it." }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityChildren() -> [Any]? {
        guard let window else { return [] }
        return rows.enumerated().compactMap { index, row -> ProcessAccessibilityRow? in
            let frame = NSRect(x: 13, y: rowsTop + rowH * CGFloat(index) - offset, width: bounds.width - 26, height: rowH).intersection(rowsViewport)
            guard !frame.isEmpty else { return nil }
            let element = ProcessAccessibilityRow()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(row.name), PID \(row.pid), \(mem(row.bytes)), \(String(format: "%.1f", row.cpu)) percent CPU")
            element.setAccessibilityHelp("Show quit and force quit actions")
            element.setAccessibilityFrame(window.convertToScreen(convert(frame, to: nil)))
            element.onPress = { [weak self] in
                self?.selectedProcess = row
                self?.needsDisplay = true
                self?.onActivate?(row)
            }
            return element
        }
    }

    private func mem(_ b: Double) -> String {
        b >= 1_073_741_824 ? String(format: "%.2f GB", b / 1_073_741_824) : String(format: "%.1f MB", b / 1_048_576)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 12, dy: 4)
        drawCard(r, radius: 11)

        let memRight = r.maxX - 66, cpuRight = r.maxX - 14
        func put(_ s: String, right x: CGFloat? = nil, left: CGFloat? = nil, y: CGFloat, font: NSFont, color: NSColor) {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let w = a.size().width
            a.draw(at: NSPoint(x: x.map { $0 - w } ?? left ?? 0, y: y))
        }
        let head = NSFont.systemFont(ofSize: 11, weight: .semibold)
        put("Processes", left: r.minX + 14, y: r.minY + 11, font: head, color: .cardSecondary)
        put(sortsByCPU ? "Memory" : "Memory ↓", right: memRight, y: r.minY + 11, font: head, color: sortsByCPU ? .cardSecondary : .cardLabel)
        put(sortsByCPU ? "% CPU ↓" : "% CPU", right: cpuRight, y: r.minY + 11, font: head, color: sortsByCPU ? .cardLabel : .cardSecondary)

        // Rows scroll inside a viewport under the fixed header.
        let top = rowsTop
        let viewport = rowsViewport
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()
        let name = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let first = max(Int(offset / rowH), 0), last = min(first + visibleRows + 1, rows.count)
        if first < last {
            for i in first..<last {
                let row = rows[i]
                let y = top + rowH * CGFloat(i) - offset
                if selectedProcess?.isSameProcess(as: row) == true {
                    NSColor.badgeSurface.setFill()
                    NSBezierPath(roundedRect: NSRect(x: r.minX + 5, y: y - 3, width: r.width - 10, height: rowH), xRadius: 5, yRadius: 5).fill()
                }
                var title = row.name
                while title.count > 14, NSAttributedString(string: title, attributes: [.font: name]).size().width > memRight - r.minX - 120 { title.removeLast() }
                put(title == row.name ? title : title + "…", left: r.minX + 14, y: y, font: name, color: .cardLabel)
                put(mem(row.bytes), right: memRight, y: y, font: digits, color: .cardSecondary)
                put(String(format: "%.1f", row.cpu), right: cpuRight, y: y, font: digits, color: .cardSecondary)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // Soft edge hints that more rows lie above or below, standing in for a scroll bar.
        let edge = NSColor.white
        if offset > 1 {
            NSGradient(colors: [edge.withAlphaComponent(0.08), edge.withAlphaComponent(0)])?
                .draw(from: NSPoint(x: 0, y: top - 2), to: NSPoint(x: 0, y: top + 14), options: [])
        }
        if offset < maxOffset - 1 {
            NSGradient(colors: [edge.withAlphaComponent(0), edge.withAlphaComponent(0.08)])?
                .draw(from: NSPoint(x: 0, y: viewport.maxY - 16), to: NSPoint(x: 0, y: viewport.maxY), options: [])
        }
    }
}

/// Compact, full-contrast text for the read-only menu rows (default disabled rows render dim and large).
func menuLine(_ text: String, color: NSColor = .labelColor, size: CGFloat = 11) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
}

final class GlassContentView: NSView {
    private static let backgroundTint = neutralColor(light: 0xFC, dark: 0x1C)

    override func draw(_ dirtyRect: NSRect) {
        // Keep text legible over dark or busy backdrops while letting the glass show through.
        Self.backgroundTint.withAlphaComponent(0.56).setFill()
        dirtyRect.fill()
    }
}

final class PanelDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Borderless panel that can take key status (for Esc and ⌘Q).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hairline divider between sections.
final class DividerRow: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 14, y: bounds.midY))
        line.line(to: NSPoint(x: bounds.maxX - 14, y: bounds.midY))
        NSColor.cardSeparator.setStroke()
        line.lineWidth = 1
        line.stroke()
    }
}

/// "Quit Sense   ⌘Q" row with a hover highlight.
final class QuitRow: NSView {
    var onClick: (() -> Void)?
    private var hovering = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let title = NSAttributedString(string: "Quit Sense", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.cardLabel])
        title.draw(at: NSPoint(x: 18, y: bounds.midY - title.size().height / 2))
        let hint = NSAttributedString(string: "⌘Q", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.cardSecondary])
        hint.draw(at: NSPoint(x: bounds.maxX - 18 - hint.size().width, y: bounds.midY - hint.size().height / 2))
    }
}

/// Alerts once per sustained episode; a full minute of recovery rearms the alert.
struct AlertEpisode {
    var began: Date?
    var recovered: Date?
    var sent = false
    mutating func update(active: Bool, now: Date, delay: TimeInterval = 30) -> Bool {
        if !active {
            began = nil
            if recovered == nil { recovered = now }
            if now.timeIntervalSince(recovered!) >= 60 { sent = false }
            return false
        }
        recovered = nil
        if began == nil { began = now }
        guard !sent, now.timeIntervalSince(began!) >= delay else { return false }
        sent = true
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let storageWarningFraction = 0.9
    private let prefs = Preferences.shared
    private var settingsController: SettingsController?
    private var tileHeightConstraint: NSLayoutConstraint?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sensorTable = SensorTable(frame: NSRect(x: 0, y: 0, width: 340, height: 158))
    private let procTable = ProcessTable(frame: NSRect(x: 0, y: 0, width: 340, height: 236))
    private let sampler = ProcessSampler()
    private let tiles = TileGrid(frame: NSRect(x: 0, y: 0, width: 340, height: 6 + 4 * TileGrid.tileHeight + 3 * TileGrid.gap + 6))
    private var availableTiles: [Tile] = []
    private let emptyTiles = NSTextField(labelWithString: "No tiles shown")
    private var cpuLoad = 0.0
    private var cpuBars: [Double] = []
    private var gpuHist: [Double?] = []
    private var memHist: [Double] = [], netHist: [Double] = [], upHist: [Double] = []
    private var networkSampler = NetworkSampler()
    private var downRate = 0.0, upRate = 0.0
    private let chip = chipName()
    private var lastDie: Double?, lastBody: Double?
    private var lastLabel = "Unknown"
    private var lastThermalStatus: HealthState?
    private var lastMem = MemStats()
    private var lastGPU: Double?
    private let memPanel = MemoryPanel(frame: NSRect(x: 0, y: 0, width: 340, height: 264))
    private let memHeader = DisclosureHeader(frame: NSRect(x: 0, y: 0, width: 340, height: 32))
    private let sensorHeader = DisclosureHeader(frame: NSRect(x: 0, y: 0, width: 340, height: 32))
    private let procHeader = DisclosureHeader(frame: NSRect(x: 0, y: 0, width: 340, height: 32))
    private let battTable = KeyValueTable(frame: NSRect(x: 0, y: 0, width: 340, height: 232))
    private let battHeader = DisclosureHeader(frame: NSRect(x: 0, y: 0, width: 340, height: 32))
    private let battProfile = BatteryProfile()
    private var profileTimer: Timer?
    private var pressureHistory: [Double] = []
    private var levelHistory: [Int] = []
    private var recentPressure: [PressureSample] = []
    private var prevTicks = cpuTicks()
    private var alertEpisodes: [String: AlertEpisode] = [:]
    private var batteryHighAlerted = false, batteryLowAlerted = false
    private var batteryPrimed = false
    private var sections: [(DisclosureHeader, NSView)] = []
    private let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let document = PanelDocumentView()
    private var globalClicks: Any?, localKeys: Any?
    private let panelWidth: CGFloat = 380
    private var lastBatt: BatteryInfo?
    private var thermalOverLimit: Bool { lastDie.map { $0 >= prefs.number("temperatureLimit") } ?? false }
    private var diskUsedFraction = 0.0
    private var saveTick = 0
    private let historyCap = 720
    private var graphTimer: Timer?
    private var pressureAnimationTimer: Timer?
    private var openedAt = Date()
    private var lastLive = 0.0
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] note in
            if let key = note.userInfo?["key"] as? String, Preferences.tileVisibilityKeys.contains(key) {
                self?.applyTileLayout()
            } else {
                self?.applyPreferences()
            }
        }
        applyPreferences()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if let h = SavedHistory.load() {
            cpuBars = h.cpu; gpuHist = h.gpu; memHist = h.mem; netHist = h.down; upHist = h.up; pressureHistory = h.pressure
            levelHistory = h.levels ?? [Int](repeating: 1, count: h.pressure.count)
            let now = Date.timeIntervalSinceReferenceDate
            recentPressure = (h.recentPressure ?? []).filter {
                $0.time >= now - 3602 && $0.time <= now
            }
        }
        battProfile.refresh()
        profileTimer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.battProfile.refresh() }
        RunLoop.main.add(profileTimer!, forMode: .common)
        refresh()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: floating panel

    /// Stacks the tiles, collapsible sections and Quit row inside a borderless panel.
    private func buildPanel() {
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        func add(_ view: NSView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
            let height = view.heightAnchor.constraint(equalToConstant: view.frame.height)
            height.isActive = true
            if view === tiles { tileHeightConstraint = height }
            stack.addArrangedSubview(view)
        }
        let heading = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 42))
        let title = NSTextField(labelWithString: "Sense")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.textColor = .cardLabel
        title.frame = NSRect(x: 18, y: 9, width: 120, height: 24)
        let live = NSTextField(labelWithString: "LIVE · " + chip)
        live.font = .systemFont(ofSize: 10, weight: .medium)
        live.textColor = .cardSecondary
        live.alignment = .right
        live.frame = NSRect(x: panelWidth - 142, y: 13, width: 90, height: 16)
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(openSettings))
        settings.isBordered = false
        settings.contentTintColor = .cardSecondary
        settings.frame = NSRect(x: panelWidth - 44, y: 7, width: 28, height: 28)
        settings.toolTip = "Sense Settings"
        settings.setAccessibilityLabel("Sense Settings")
        [title, live, settings].forEach(heading.addSubview)
        add(heading)
        add(tiles)
        emptyTiles.frame.size.height = 40
        emptyTiles.alignment = .center
        emptyTiles.font = .systemFont(ofSize: 11)
        emptyTiles.textColor = .secondaryLabelColor
        emptyTiles.isHidden = true
        add(emptyTiles)
        add(DividerRow(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 9)))

        // Collapsible sections, closed by default. Opening one closes the others.
        func section(_ title: String, header: DisclosureHeader, body: NSView) {
            header.title = title
            body.isHidden = true
            sections.append((header, body))
            header.onToggle = { [weak self, weak header] open in
                guard let self, let header else { return }
                if open {
                    if header === self.procHeader {
                        self.procTable.scrollToTop()
                        self.updateProcesses()
                    }
                    // The old section fades out completely and is hidden before the new one appears.
                    let closing = self.sections.filter { $0.0 !== header && $0.0.expanded }
                    let reveal = { [weak header] in
                        guard header?.expanded == true else { return }   // the user closed it again meanwhile
                        body.isHidden = false
                        body.alphaValue = 0
                        self.relayoutPanel()
                        self.fade(body, to: 1)
                    }
                    if closing.isEmpty { reveal() }
                    for (n, other) in closing.enumerated() {
                        other.0.setExpanded(false)
                        self.fade(other.1, to: 0) {
                            other.1.isHidden = true
                            other.1.alphaValue = 1
                            self.relayoutPanel()
                            if n == closing.count - 1 { reveal() }
                        }
                    }
                } else {
                    self.fade(body, to: 0) { body.isHidden = true; body.alphaValue = 1; self.relayoutPanel() }
                }
            }
            add(header)
            add(body)
        }
        section("Memory", header: memHeader, body: memPanel)
        section("Sensors", header: sensorHeader, body: sensorTable)
        section("Battery", header: battHeader, body: battTable)
        procTable.toolTip = "Click a process to quit or force quit it."
        procTable.onActivate = { [weak self] row in self?.confirmEndProcess(row) }
        section("Top Processes", header: procHeader, body: procTable)
        add(DividerRow(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 9)))
        let quit = QuitRow(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 32))
        quit.onClick = { NSApp.terminate(nil) }
        add(quit)

        // Clip the whole effect, including the scrolling content, to the window's rounded shape.
        let cornerRadius: CGFloat = 18
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = cornerRadius
        surface.layer?.masksToBounds = true
        let material: NSView
        let content: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            content = GlassContentView()
            glass.contentView = content
            material = glass
        } else {
            let frost = NSVisualEffectView()
            frost.material = .menu
            frost.blendingMode = .behindWindow
            frost.state = .active
            content = frost
            material = frost
        }
        material.frame = surface.bounds
        material.autoresizingMask = [.width, .height]
        surface.addSubview(material)
        panel.contentView = surface
        panel.hasShadow = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.addSubview(scroll)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: panelWidth)])

        panel.title = "Sense"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // A plain click action, so macOS has no menu to highlight.
        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.isBordered = false
        item.button?.image = SenseMark.menuBarIcon()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Sense"
        item.button?.setAccessibilityLabel("Sense")
    }

    private var panelHeight: CGFloat {
        stack.layoutSubtreeIfNeeded()
        let contentHeight = stack.fittingSize.height
        document.setFrameSize(NSSize(width: panelWidth, height: contentHeight))
        let screen = item.button?.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 16
        return min(contentHeight + 12, available)
    }

    /// Resizes the panel to fit what is currently visible, keeping its top edge where it is.
    private func relayoutPanel() {
        guard panel.isVisible else { return }
        let h = panelHeight
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - h, width: panelWidth, height: h), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = item.button, let window = button.window else { return }
        let h = panelHeight
        let anchor = window.frame
        let screen = window.screen ?? NSScreen.main
        var x = anchor.midX - panelWidth / 2
        if let visible = screen?.visibleFrame { x = min(max(x, visible.minX + 8), visible.maxX - panelWidth - 8) }
        panel.setFrame(NSRect(x: x, y: anchor.minY - h - 6, width: panelWidth, height: h), display: true)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        procTable.scrollToTop()
        panel.makeKey()

        // Live updates while open.
        graphTimer?.invalidate()
        lastLive = 0
        openedAt = Date()
        updateLive(sampleHistory: false)
        graphTimer = Timer(timeInterval: prefs.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateLive(sampleHistory: false)
            self.lastLive += self.prefs.interval
            if self.lastLive >= 2 { self.updateProcesses(); self.lastLive = 0 }
        }
        RunLoop.main.add(graphTimer!, forMode: .common)
        pressureAnimationTimer?.invalidate()
        pressureAnimationTimer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.memPanel.isHiddenOrHasHiddenAncestor else { return }
            self.memPanel.advanceTimeline(to: Date.timeIntervalSinceReferenceDate)
        }
        RunLoop.main.add(pressureAnimationTimer!, forMode: .common)
        updateProcesses()

        // Close on a click anywhere else, on Esc, and handle ⌘Q.
        globalClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown, let button = self.item.button, let window = button.window {
                let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
                let click = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
                // Give the button's action sole ownership of the toggle.
                if buttonFrame.contains(click) { return }
            }
            self.hidePanel()
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hidePanel(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            return event
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        graphTimer?.invalidate()
        graphTimer = nil
        pressureAnimationTimer?.invalidate()
        pressureAnimationTimer = nil
        if let g = globalClicks { NSEvent.removeMonitor(g); globalClicks = nil }
        if let k = localKeys { NSEvent.removeMonitor(k); localKeys = nil }
    }

    private func notify(_ key: String, _ title: String, _ body: String, cooldown: TimeInterval = 1800) {
        let now = Date()
        let stamp = "alertLastSent." + key
        if let last = prefs.defaults.object(forKey: stamp) as? Date, now.timeIntervalSince(last) < cooldown { return }
        prefs.defaults.set(now, forKey: stamp)
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = prefs.bool("sound") ? .default : nil
        c.threadIdentifier = "sense-health"
        let center = UNUserNotificationCenter.current()
        let identifier = "sense-" + key
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: c, trigger: nil))
    }

    private func episode(_ key: String, active: Bool, delay: TimeInterval = 30) -> Bool {
        var state = alertEpisodes[key] ?? AlertEpisode()
        let fire = state.update(active: active, now: Date(), delay: delay)
        alertEpisodes[key] = state
        return fire
    }

    /// Brief spikes stay quiet. Ongoing conditions alert once, then rearm after recovery.
    private func checkAlerts(thermal: ProcessInfo.ThermalState, label: String) {
        let hot = prefs.bool("temperatureAlerts") && (thermalOverLimit || thermal == .serious || thermal == .critical)
        if episode("heat", active: hot) {
            let detail = lastDie.map { "CPU at " + prefs.temperature($0) + ". Give your Mac a moment to cool." } ?? "Give your Mac a moment to cool."
            notify("heat", "Your Mac is running warm", detail)
        }

        if prefs.bool("batteryAlerts"), let b = lastBatt {
            let high = Int(prefs.number("batteryHigh")), low = Int(prefs.number("batteryLow"))
            if !batteryPrimed {   // note the starting state silently; only alert on changes after launch
                batteryPrimed = true
                batteryHighAlerted = b.plugged && b.charge >= high
                batteryLowAlerted = !b.plugged && b.charge <= low
            }
            if b.plugged && b.charge >= high {
                if !batteryHighAlerted {
                    batteryHighAlerted = true
                    notify("battery-high", "Battery at \(b.charge)%", "Charge target reached. You can unplug now.", cooldown: 0)
                }
            } else if b.charge < high - 5 || !b.plugged { batteryHighAlerted = false }
            if !b.plugged && b.charge <= low {
                if !batteryLowAlerted {
                    batteryLowAlerted = true
                    notify("battery-low", "Battery at \(b.charge)%", "Connect your charger when convenient.", cooldown: 0)
                }
            } else if b.plugged || b.charge > low + 5 { batteryLowAlerted = false }
        }

        let memoryHigh = prefs.bool("memoryAlerts") && lastMem.level >= Int(prefs.number("memoryLimit"))
        if episode("memory", active: memoryHigh) {
            notify("memory", "Memory usage is high", "Close an unused app to give your Mac more room.")
        }
        if episode("disk", active: prefs.bool("otherAlerts") && diskUsedFraction > Self.storageWarningFraction, delay: 30) {
            notify("disk", "Storage is getting full", String(format: "%.0f%% used. Clear some space when convenient.", diskUsedFraction * 100), cooldown: 86_400)
        }
        if episode("cpu", active: prefs.bool("otherAlerts") && cpuLoad > 0.85, delay: 300) {
            notify("cpu", "CPU usage is staying high", "Check Top Processes in Sense for details.")
        }
    }

    /// CPU load and memory figures; cheap enough to run every second while the menu is open.
    private func updateLive(sampleHistory: Bool) {
        let currentTicks = cpuTicks()
        if let currentTicks, let prevTicks, let load = cpuLoadFraction(from: prevTicks, to: currentTicks) {
            cpuLoad = load
        }
        prevTicks = currentTicks
        if let m = memoryStats() {
            if sampleHistory && m.pressureAvailable {
                pressureHistory.append(m.pressure)
                levelHistory.append(m.level)
                if pressureHistory.count > 720 { pressureHistory.removeFirst(pressureHistory.count - 720) }
                if levelHistory.count > 720 { levelHistory.removeFirst(levelHistory.count - 720) }
            }
            memPanel.stats = m
            // Keep the live graph separate from the persisted five-second history.
            // Timestamps preserve honest spacing when the panel has been closed.
            let now = Date.timeIntervalSinceReferenceDate
            if m.pressureAvailable {
                if let last = recentPressure.last, Int(last.time) == Int(now) {
                    recentPressure.removeLast() // the background and live timers can share a second
                }
                recentPressure.append(PressureSample(time: now, value: m.pressure, level: m.level))
            }
            recentPressure.removeAll { $0.time < now - 3602 }
            let visiblePressure = recentPressure.filter { $0.time >= now - prefs.range - 2 }
            memPanel.history = visiblePressure.map { $0.value }
            memPanel.levels = visiblePressure.map { $0.level }
            memPanel.sampleTimes = visiblePressure.map { $0.time }
            memPanel.windowEnd = now - 1
            memPanel.needsDisplay = true
            memHeader.summary = String(format: "%.2f / %.0f GB", m.used / 1_073_741_824, m.total / 1_073_741_824)
            lastMem = m
        }
        updateTiles(sample: true, record: sampleHistory)
    }

    @objc private func openSettings() {
        hidePanel()
        settingsController = SettingsController()
        settingsController?.present()
    }
    private func applyPreferences() {
        for (header,body) in sections {
            header.isHidden = prefs.bool("compact")
            body.isHidden = prefs.bool("compact") || !header.expanded
        }
        batteryPrimed = false
        updateLive(sampleHistory:false)
        updateProcesses()
        if panel.isVisible { hidePanel(); showPanel() }
    }
    private func saveHistory() {
        SavedHistory(cpu: cpuBars, gpu: gpuHist, mem: memHist, down: netHist, up: upHist, pressure: pressureHistory, levels: levelHistory, recentPressure: recentPressure).write()
    }

    func applicationWillTerminate(_ notification: Notification) { saveHistory() }

    private func updateTiles(sample: Bool, record: Bool) {
        func push<T>(_ a: inout [T], _ v: T, _ cap: Int) { a.append(v); if a.count > cap { a.removeFirst(a.count - cap) } }
        func state(_ f: Double) -> String { f < 0.08 ? "idle" : f < 0.4 ? "light" : f < 0.75 ? "busy" : "heavy" }
        let memFrac = lastMem.total > 0 ? lastMem.used / lastMem.total : 0
        if sample {
            lastGPU = gpuUtilization()
            (downRate, upRate) = networkSampler.sample(netBytes(), at: ProcessInfo.processInfo.systemUptime)
            if record {
                push(&cpuBars, cpuLoad, historyCap)
                push(&gpuHist, lastGPU, historyCap)
                push(&memHist, memFrac, historyCap)
                push(&netHist, downRate, historyCap)
                push(&upHist, upRate, historyCap)
            }
        }
        let gpu = lastGPU
        let down = rate(downRate), up = rate(upRate)

        let die = lastDie.map { prefs.temperature($0) } ?? "—"
        let recentCPU = Array(cpuBars.suffix(9))
        let bars = Array(repeating: 0.0, count: max(9 - recentCPU.count, 0)) + recentCPU
        let count = Int(prefs.range / 5)
        let gpuD = downsample(Array(gpuHist.suffix(count)), to: 120) { bucket in
            let readings = bucket.compactMap { $0 }
            return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
        }
        let memD = downsample(Array(memHist.suffix(count)), to: 120)
        let memoryStatus = lastMem.pressureAvailable ? HealthState.memoryPressure(lastMem.level) : nil
        let downD = downsample(Array(netHist.suffix(count)), to: 120), upD = downsample(Array(upHist.suffix(count)), to: 120)
        var t: [Tile] = [
            Tile(symbol: "cpu", title: "CPU", badge: die, value: String(format: "%.0f", cpuLoad * 100), unit: "%", visual: .bars(bars),
                 footer: "\(state(cpuLoad)) · \(ProcessInfo.processInfo.activeProcessorCount) cores",
                 tint: loadInk(cpuLoad), chartState: .utilization(cpuLoad)),
            Tile(symbol: "display", title: "GPU", badge: chip,
                 value: gpu.map { String(format: "%.0f", $0 * 100) } ?? "—", unit: gpu == nil ? "" : "%", visual: .spark(gpuD),
                 footer: gpu.map { "\(state($0)) · \(chip)" } ?? "Unavailable",
                 tint: loadInk(gpu ?? 0), chartState: gpu.map(HealthState.utilization)),
            Tile(symbol: "memorychip", title: "MEM", badge: memoryStatus?.pressureLabel ?? "Unavailable",
                 value: String(format: "%.0f", memFrac * 100), unit: "%", visual: .spark(memD.map(Optional.some)),
                 footer: String(format: "%.2f GB / %.0f GB", lastMem.used / 1_073_741_824, lastMem.total / 1_073_741_824),
                 tint: .chartInk, status: memoryStatus)]
        if let d = diskSpace() {
            let used = d.total - d.free
            diskUsedFraction = used / d.total
            let lowSpace = diskUsedFraction > Self.storageWarningFraction
            t.append(Tile(symbol: "internaldrive", title: "Free space", badge: String(format: "%.0f GB", d.total / 1e9),
                          value: String(format: "%.0f", d.free / 1e9), unit: "GB", visual: .bar(diskUsedFraction),
                          footer: lowSpace ? String(format: "Low space · %.0f%% used", diskUsedFraction * 100)
                                           : String(format: "%.0f GB used · %.0f%%", used / 1e9, diskUsedFraction * 100),
                          tint: loadInk(pow(diskUsedFraction, 3)), status: lowSpace ? .warning : nil, chartState: .normal))
        }
        let netScale = max(max(downD.max() ?? 0, upD.max() ?? 0), 10_000)
        var net = Tile(symbol: "network", title: "Network", badge: "Live", value: down.0, unit: down.1,
                       visual: .dual(downD.map { $0 / netScale }, upD.map { $0 / netScale }), footer: "", tint: .emphasisInk, chartState: .normal)
        net.value2 = up.0
        net.unit2 = up.1
        net.wide = true
        t.append(net)
        let temperatureWarning = thermalOverLimit && (lastThermalStatus == nil || lastThermalStatus == .normal)
        t.append(Tile(symbol: "thermometer.medium", title: "Thermal", badge: temperatureWarning ? "Hot" : lastLabel,
                      value: lastDie.map { prefs.temperature($0, unit: false) } ?? "–", unit: prefs.bool("fahrenheit") ? "°F" : "°C", visual: .bar((lastDie ?? 0) / 100),
                      footer: (lastBody.map { "Body " + prefs.temperature($0) } ?? "CPU temperature") + " · \(chip)",
                      tint: loadInk(((lastDie ?? 35) - 30) / 65), status: temperatureWarning ? .warning : lastThermalStatus))
        func pct(_ a: [Double?], total: Int) -> [String] {
            a.enumerated().map { index, value in
                value.map { String(format: "%.0f%% · ", $0 * 100) + ago(index, of: a.count, total: total) } ?? ""
            }
        }
        t[0].readouts = bars.enumerated().map { $1 > 0 ? String(format: "%.0f%% · ", $1 * 100) + ago($0, of: bars.count, total: bars.count) : "" }
        t[1].readouts = pct(gpuD, total: min(gpuHist.count, count))
        t[2].readouts = pct(memD.map(Optional.some), total: min(memHist.count, count))
        if let n = t.firstIndex(where: { $0.title == "Network" }) {
            t[n].readouts = downD.enumerated().map { "\(rate($1).0) \(rate($1).1) · " + ago($0, of: downD.count, total: min(netHist.count, count)) }
            t[n].readouts2 = upD.enumerated().map { "\(rate($1).0) \(rate($1).1) · " + ago($0, of: upD.count, total: min(upHist.count, count)) }
        }
        lastBatt = batteryInfo()
        if let b = lastBatt {
            let lowBattery = !b.plugged && b.charge <= Int(prefs.number("batteryLow"))
            let status = b.charging ? "Charging" : b.plugged ? "Plugged in" : lowBattery ? "Low battery" : "On battery"
            t.append(Tile(symbol: b.charging ? "battery.100.bolt" : "battery.100", title: "Battery", badge: status,
                          value: "\(b.charge)", unit: "%", visual: .bar(Double(b.charge) / 100),
                          footer: battProfile.maxCapacity == "–" ? "\(b.cycles) charge cycles" : "Health \(battProfile.maxCapacity) · \(b.cycles) cycles",
                          tint: b.plugged ? .chartInk : loadInk(pow(1 - Double(b.charge) / 100, 2.2)),
                          status: b.plugged ? .normal : lowBattery ? .warning : nil, chartState: .normal))
            func mah(_ v: Int) -> String { v > 0 ? "\(v.formatted()) mAh" : "–" }
            var time = "–"
            if let m = b.minutes { time = "\(m / 60 > 0 ? "\(m / 60) h " : "")\(m % 60) min " + (b.charging ? "to full" : "left") }
            else if b.plugged && !b.charging { time = "Fully charged" }
            battTable.rows = [
                ("Health (max capacity)", "\(battProfile.maxCapacity) · \(battProfile.condition)"),
                ("Cycle count", "\(b.cycles) of \(b.designCycles)"),
                ("Design capacity", mah(b.designMAh)),
                ("Full charge capacity", mah(b.fullMAh)),
                ("Current charge", "\(b.charge)% · \(mah(b.remainingMAh))"),
                ("Power", String(format: "%@ · %.1f W", status, b.watts)),
                ("Time", time),
                ("Voltage", String(format: "%.2f V", b.voltage)),
                ("Adapter", b.adapter.isEmpty ? "None" : b.adapter)]
            battTable.needsDisplay = true
            battHeader.summary = "\(b.charge)% · health \(battProfile.maxCapacity)"
        }
        let order = prefs.order
        t.sort { (order.firstIndex(of: $0.title) ?? order.count) < (order.firstIndex(of: $1.title) ?? order.count) }
        availableTiles = t
        applyTileLayout()
    }

    private func applyTileLayout() {
        let visible = prefs.visibleTiles
        tiles.tiles = availableTiles.filter { visible.contains($0.title) }
        tiles.isHidden = tiles.tiles.isEmpty
        emptyTiles.isHidden = !tiles.tiles.isEmpty
        tileHeightConstraint?.constant = tiles.requiredHeight
        relayoutPanel()
    }

    /// Eases a view's opacity to `target` over about 0.18 s. Runs in common modes so it also ticks while the menu is open.
    private func fade(_ view: NSView, to target: CGFloat, then done: (() -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.alphaValue = target
            done?()
            return
        }
        let start = view.alphaValue, began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            let p = min(Date().timeIntervalSince(began) / 0.18, 1)
            view.alphaValue = start + (target - start) * CGFloat(1 - pow(1 - p, 3))
            if p >= 1 { t.invalidate(); done?() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func confirmEndProcess(_ row: ProcRow) {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        do {
            try ProcessControl.validate(row)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "End “\(row.name)”?"
            alert.informativeText = "PID \(row.pid). Quit requests an orderly exit. Force Quit stops the process immediately. Unsaved work may be lost."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Process")
            alert.addButton(withTitle: "Force Quit")
            alert.buttons[0].keyEquivalent = "\u{1b}"
            alert.buttons[1].keyEquivalent = ""
            alert.buttons[2].keyEquivalent = ""
            let response = alert.runModal()
            guard response == .alertSecondButtonReturn || response == .alertThirdButtonReturn else { return }
            try ProcessControl.end(row, force: response == .alertThirdButtonReturn)
            updateProcesses()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not end \(row.name)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            updateProcesses()
        }
    }

    private func updateProcesses() {
        procTable.sortsByCPU = prefs.bool("sortCPU")
        procTable.rows = sampler.top(5000).sorted { prefs.bool("sortCPU") ? ($0.cpu == $1.cpu ? $0.bytes > $1.bytes : $0.cpu > $1.cpu) : $0.bytes > $1.bytes }
        procTable.needsDisplay = true
        if let top = procTable.rows.first {
            procHeader.summary = "\(top.name.count > 12 ? String(top.name.prefix(12)) + "…" : top.name) " + (prefs.bool("sortCPU") ? String(format:"%.1f%% CPU", top.cpu) : top.bytes >= 1_073_741_824 ? String(format: "%.2f GB", top.bytes / 1_073_741_824) : String(format: "%.0f MB", top.bytes / 1_048_576))
        }
    }

    private func refresh() {
        let state = ProcessInfo.processInfo.thermalState
        let (label, health, detail): (String, HealthState?, String)
        switch state {
        case .nominal:  (label, health, detail) = ("Nominal", .normal, "Running cool")
        case .fair:     (label, health, detail) = ("Fair", .warning, "Warm")
        case .serious:  (label, health, detail) = ("Serious", .warning, "Slowing down")
        case .critical: (label, health, detail) = ("Critical", .critical, "Throttling")
        @unknown default: (label, health, detail) = ("Unknown", nil, "")
        }
        updateLive(sampleHistory: true)
        updateProcesses()
        let sensors = readSensors()
        lastDie = sensors.die
        lastBody = sensors.battery
        lastLabel = label
        lastThermalStatus = health
        func level(_ v: Double?, _ cuts: [Double]) -> (String, HealthState?) {
            guard let v else { return ("n/a", nil) }
            return v < cuts[0] ? ("Cool", .normal) : v < cuts[1] ? ("Warm", .warning) : v < cuts[2] ? ("Hot", .warning) : ("Very hot", .critical)
        }
        func reading(_ v: Double?) -> String { v.map { prefs.temperature($0) } ?? "n/a" }
        let cpu = level(sensors.die, [70, 85, 95]), body = level(sensors.battery, [40, 45, 50]), ssd = level(sensors.ssd, [60, 70, 85])
        sensorTable.rows = [
            SensorRow(name: "CPU/SoC", value: reading(sensors.die), status: cpu.0, health: cpu.1),
            SensorRow(name: "Body (approx)", value: reading(sensors.battery), status: body.0, health: body.1),
            SensorRow(name: "SSD", value: reading(sensors.ssd), status: ssd.0, health: ssd.1),
            SensorRow(name: "Thermal pressure", value: label, status: detail, health: health)]
        sensorTable.needsDisplay = true
        sensorHeader.summary = "CPU " + reading(sensors.die) + " · " + label
        updateTiles(sample: false, record: false)
        checkAlerts(thermal: state, label: label)
        saveTick += 1
        if saveTick % 12 == 0 { saveHistory() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
