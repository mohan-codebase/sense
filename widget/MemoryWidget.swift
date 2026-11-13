import WidgetKit
import SwiftUI
import Darwin

struct MemoryEntry: TimelineEntry {
    let date: Date
    let used: Double?
    let total: Double
    static func read() -> MemoryEntry {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let used = result == KERN_SUCCESS ? max(0, min(total, total - Double(vm.free_count + vm.external_page_count) * Double(sysconf(_SC_PAGESIZE)))) : nil
        return MemoryEntry(date: Date(), used: used, total: total)
    }
}
struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry { MemoryEntry(date: Date(), used: 8 * 1_073_741_824, total: 16 * 1_073_741_824) }
    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) { completion(context.isPreview ? placeholder(in: context) : .read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        let entry = MemoryEntry.read()
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(15 * 60))))
    }
}
struct MemoryView: View {
    let entry: MemoryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "memorychip"); Text("MEMORY").tracking(1.2); Spacer() }
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let used = entry.used, entry.total > 0 {
                Text("\(Int((used / entry.total * 100).rounded()))%")
                    .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.2))
                        Capsule().fill(.primary).frame(width: geo.size.width * min(1, max(0, used / entry.total)))
                    }
                }.frame(height: 5)
                Text("\(used / 1_073_741_824, specifier: "%.1f") of \(entry.total / 1_073_741_824, specifier: "%.0f") GB used")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Unavailable").font(.headline)
            }
            Text(entry.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding()
    }
}
@main
struct SenseMemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SenseMemoryWidget", provider: MemoryProvider()) { entry in
            if #available(macOS 14.0, *) { MemoryView(entry: entry).containerBackground(.background, for: .widget) }
            else { MemoryView(entry: entry) }
        }.configurationDisplayName("Memory Usage").description("See your Mac’s memory usage.").supportedFamilies([.systemSmall])
    }
}
