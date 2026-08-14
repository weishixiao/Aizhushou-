import SwiftUI

@main
struct AIReverseApp: App {
    @StateObject private var modelStore = ModelStore()
    @StateObject private var workspace = WorkspaceManager()

    init() {
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modelStore)
                .environmentObject(workspace)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        }
    }
}
