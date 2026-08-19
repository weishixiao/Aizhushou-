import SwiftUI
import UIKit

@main
struct AIReverseApp: App {
    @StateObject private var modelStore = ModelStore()
    @StateObject private var workspace = WorkspaceManager()

    init() {
        logLaunchInfo()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modelStore)
                .environmentObject(workspace)
        }
    }

    private func logLaunchInfo() {
        let device = UIDevice.current
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        RuntimeLogger.shared.info(
            "App",
            "启动 AIReverse v\(appVersion)(\(build))，设备 \(device.model)，系统 \(device.systemName) \(device.systemVersion)"
        )
    }
}