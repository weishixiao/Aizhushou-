import SwiftUI

@main
struct AIReverseApp: App {
    @StateObject private var analysisStore = AnalysisStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(analysisStore)
        }
    }
}
