import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelStore: ModelStore
    @EnvironmentObject var workspace: WorkspaceManager

    var body: some View {
        TabView {
            CodingChatView(workspace: workspace)
                .tabItem {
                    Label("编程助手", systemImage: "chevron.left.slash.chevron.right")
                }

            ModelSettingsView()
                .tabItem {
                    Label("模型设置", systemImage: "gearshape")
                }
        }
    }
}
