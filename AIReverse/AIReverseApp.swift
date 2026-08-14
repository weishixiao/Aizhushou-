import SwiftUI

@main
struct AIReverseApp: App {
    @StateObject private var modelStore = ModelStore()
    @StateObject private var workspace = WorkspaceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modelStore)
                .environmentObject(workspace)
        }
    }
}
