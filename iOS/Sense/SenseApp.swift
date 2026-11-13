import SwiftUI

@main
struct SenseApp: App {
    @StateObject private var monitor = DeviceMonitor()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            DashboardView().environmentObject(monitor)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}
