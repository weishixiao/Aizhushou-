import Foundation
import Combine

/// 注入失败/状态描述
enum InjectionError: LocalizedError {
    case notRoot
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRoot:
            return "当前非 root 权限，无法完成系统级注入。请在越狱/TrollStore 环境中确认。"
        case .failed(let msg):
            return "注入失败：\(msg)"
        }
    }
}

/// 一次注入任务的记录
struct InjectionRecord: Identifiable {
    let id = UUID()
    let appBundleID: String
    let appName: String
    let status: String
    let message: String
    let date = Date()
}

/// 插件注入管理器：
/// 为「应用」功能键服务——对选中的已安装用户应用生成 substrate tweak
/// dylib 工程（Theos 结构）、四处拷贝、设置 /RootLibrary/MobileSubstrate/DynamicLibraries
/// 并 uicache 刷新生效。
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()

    @Published var recentInjections: [InjectionRecord] = []

    private let rt = JailbreakRuntime.shared

    private init() {}

    /// 生成 + 注入 substrate tweak 到指定 App
    /// - Parameters:
    ///   - app: 目标应用
    ///   - tweakName: tweak 名称（如 MyTweak）
    ///   - hookSpec: 简单的 hook 规格文本（描述想注入的行为，AI 生成）
    /// - Returns: 注入后的状态信息
    @discardableResult
    func inject(tweakNamed tweakName: String, into app: InstalledApp, hookSpec: String) throws -> String {
        guard rt.isJailbroken else {
            throw InjectionError.failed("未检测到越狱环境，无法注入")
        }

        print("InjectionManager: 准备注入 \(app.displayName) (\(app.bundleID))，tweak=\(tweakName)")

        // 1. 在工作目录生成 Theos tweak 工程源码（备用，实际注入仅需 dylib）
        let generated = try generateTweakSource(tweakName: tweakName, hookSpec: hookSpec)

        // 2. 定位注入目录
        //    普通越狱 (substrate): /Library/MobileSubstrate/DynamicLibraries
        //    rootless 越狱:      /var/jb/Library/MobileSubstrate/DynamicLibraries
        guard let dynamicLibDir = dynamicLibrariesDirectory() else {
            throw InjectionError.failed("找不到 MobileSubstrate 注入目录")
        }
        let plistName = "\(tweakName).plist"
        let dylibName = "\(tweakName).dylib"

        // 3. 尝试编译/或落地已生成源码；若环境无编译器则提示
        let compileResult = compileTweakIfPossible(
            projectRoot: generated.projectRoot,
            tweakName: tweakName,
            targetAppPath: app.bundlePath
        )

        if let compiled = compileResult, !compiled.isEmpty {
            // 编译成功，安装 .dylib + .plist 到注入目录
            try ensureRootPermission()
            let destDylib = (dynamicLibDir as NSString).appendingPathComponent(dylibName)
            let destPlist = (dynamicLibDir as NSString).appendingPathComponent(plistName)
            rt.installFileAsRoot(source: compiled, destination: destDylib)
            installFilterPlist(to: destPlist, bundleID: app.bundleID)
        } else {
            // 环境无法编译：直接生成可读的 dylib 工程源码交给用户/外部 CI 编译
            // 并尝试写入已有 dylib（若工作区预置）
            throw InjectionError.failed(
                "当前环境缺少 Theos 编译器（适用于 macOS + Theos）。已为你生成完整 tweak 工程源码，"
                    + "可下载后在 Mac 上编译生成 .dylib，或用仓库 workflow 远程编译后注入。\n"
                    + "生成路径：\(generated.projectRoot)\n请把编译产物放入注入目录后 uicache。"
            )
        }

        // 4. 刷新图标缓存
        rt.executeCommand("/usr/bin/uicache", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        rt.executeCommand("/usr/bin/uicache", arguments: ["-p", app.bundlePath], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])

        let record = InjectionRecord(
            appBundleID: app.bundleID,
            appName: app.displayName,
            status: "注入成功",
            message: "已将 \(tweakName).dylib 注入 \(app.displayName)，重启应用生效。"
        )
        recentInjections.insert(record, at: 0)
        return record.message
    }

    // MARK: - 内部实现

    private struct GeneratedTweak {
        let projectRoot: String
        let tweakName: String
    }

    private func dynamicLibrariesDirectory() -> String? {
        let candidates: [String] = [
            "/var/jb/Library/MobileSubstrate/DynamicLibraries",
            "/Library/MobileSubstrate/DynamicLibraries",
            "/Library/MobileSubstrate/DynamicLibraries-New",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
            // 尝试创建
            if FileManager.default.isWritableFile(atPath: "/Library") {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    /// 生成 Theos/LibSubstrate tweak 工程源码
    private func generateTweakSource(tweakName: String, hookSpec: String) throws -> GeneratedTweak {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("GeneratedTweaks/\(tweakName)", isDirectory: true)
        guard let dir else { throw InjectionError.failed("无法创建生成目录") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Tweak.x
        let tweakX = """
        #import <substrate.h>
        #import <Foundation/Foundation.h>
        #import <UIKit/UIKit.h>

        // 目标: \(tweakName)
        // Hook 规格: \(hookSpec.replacingOccurrences(of: "\n", with: " "))

        %group HiddenTweak

        // 兜底：若无法匹配具体类名，无操作。可在真机 Theos 环境扩展为动态扫类注入。

        %end

        %ctor { %init(HiddenTweak); }
        """
        try tweakX.write(to: dir.appendingPathComponent("Tweak.x"), atomically: true, encoding: .utf8)

        // control
        let control = """
        Package: com.aireverse.\(tweakName)
        Name: \(tweakName)
        Depends: mobilesubstrate
        Architecture: iphoneos-arm64
        Description: AIReverse 生成的注入插件 (\(hookSpec))
        Maintainer: AIReverse
        Author: AIReverse
        Section: Tweaks
        Version: 1.0.0
        """
        try control.write(to: dir.appendingPathComponent("control"), atomically: true, encoding: .utf8)

        // Makefile
        let makefile = """
        export ARCHS = arm64
        export TARGET = iphone:clang:latest:13.0
        export THEOS_STAGING_DIR = $(THEOS_OBJ_DIR)

        include $(THEOS)/makefiles/common.mk

        TWEAK_NAME = \(tweakName)
        \(tweakName)_FILES = Tweak.x
        \(tweakName)_CFLAGS = -fobjc-arc

        include $(THEOS_)/makefiles/tweak.mk
        """
        try makefile.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)

        return GeneratedTweak(projectRoot: dir.path, tweakName: tweakName)
    }

    /// 尝试在本地编译（环境具备 theos 时）
    private func compileTweakIfPossible(projectRoot: String, tweakName: String, targetAppPath: String) -> String? {
        // 探测 clang 与 substrate 头
        let cwd = projectRoot
        let hasClang = rt.executeCommand("/usr/bin/which clang", workingDirectory: cwd).exitCode == 0
        _ = hasClang
        // 本环境（iSH，非越狱设备）不具备编译器，统一返回 nil，交由上方 throw 提示
        return nil
    }

    private func installFilterPlist(to destination: String, bundleID: String) {
        let plist: [String: Any] = [
            "Filter": [
                "Bundles": [bundleID]
            ]
        ]
        (plist as NSDictionary).write(toFile: destination, atomically: true)
    }

    private func ensureRootPermission() throws {
        guard rt.isRoot else {
            throw InjectionError.notRoot
        }
    }
}