import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workspace: WorkspaceManager

    var body: some View {
        NavigationView {
            CodingChatView(workspace: workspace)
        }
    }
}
