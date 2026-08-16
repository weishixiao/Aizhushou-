import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workspace: WorkspaceManager
    @State private var showRootAlert = false

    var body: some View {
        NavigationView {
            CodingChatView(workspace: workspace)
        }
        .overlay {
            if showRootAlert {
                rootAlertView
            }
        }
        .onAppear {
            checkRootStatus()
        }
    }

    private func checkRootStatus() {
        let isRoot = geteuid() == 0
        if !isRoot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showRootAlert = true
            }
        }
    }

    private var rootAlertView: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    showRootAlert = false
                }

            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(red: 0.12, green: 0.12, blue: 0.13))
                        .frame(width: 300, height: 200)
                        .shadow(color: .black.opacity(0.3), radius: 10)

                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.orange)

                        Text("非 root 身份运行")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("AIReverse 需要 root 权限才能执行注入、进程枚举等操作。请前往"设置 → 权限设置"配置 LaunchDaemon。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)

                        Button {
                            showRootAlert = false
                        } label: {
                            Text("我知道了，继续")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
    }
}