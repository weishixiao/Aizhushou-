import SwiftUI

@main
struct AIReverseApp: App {
    @StateObject private var modelStore = ModelStore()
    @StateObject private var analysisStore = AnalysisStore()
    @StateObject private var workspace = WorkspaceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modelStore)
                .environmentObject(analysisStore)
                .environmentObject(workspace)
        }
    }
}
