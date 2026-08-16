import Foundation
import Combine

enum InjectionError: LocalizedError {
    case notRoot
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notRoot: return "当前非 root 权限，请在越狱/TrollStore 环境中确认"
        case .failed(let msg): return "注入失败：\(msg)"
        }
    }
}

struct InjectionRecord: Identifiable {
    let id = UUID()
    let appBundleID: String
    let appName: String
    let dylibName: String
    let appBundlePath: String
    let method: String
    let status: String
    let message: String
    let date = Date()
}

/// 插件注入管理器
/// 模仿 TrollStore 的注入方式，完整流程：
/// 1. 解压 .deb（如果是 deb 格式）提取 .dylib
/// 2. 复制 dylib 到目标 App bundle 内
/// 3. 用 ldid 重签名 dylib
/// 4. 修改目标 App 的 Mach-O 二进制，写入 LC_LOAD_DYLIB
/// 5. 用 ldid 重签名主二进制
/// 6. 清理 CodeSignature
/// 7. uicache 刷新
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()
    @Published var recentInjections: [InjectionRecord] = []
    private let rt = JailbreakRuntime.shared
    private init() {}

    @discardableResult
    func injectDylib(at dylibPath: String, into app: InstalledApp, targetDir: String = "") throws -> String {
        guard rt.isJailbroken else {
            throw InjectionError.failed("未检测到越狱环境")
        }

        let dylibName = (dylibPath as NSString).lastPathComponent
        let appBundle = app.bundlePath
        let binaryName = (appBundle as NSString).lastPathComponent
        let mainBinary = (appBundle as NSString).appendingPathComponent(binaryName)
        let destDylib = (appBundle as NSString).appendingPathComponent(dylibName)
        let infoPlist = (appBundle as NSString).appendingPathComponent("Info.plist")
        let codeSignDir = (appBundle as NSString).appendingPathComponent("_CodeSignature")

        var method = "LC_LOAD_DYLIB"

        // 1. 复制 dylib 到目标 App bundle 内
        let (cpCode, _) = spawn("cp -f \(dylibPath) \(destDylib)")
        guard cpCode == 0 else {
            throw InjectionError.failed("复制 dylib 失败，请确认 TrollStore 中已开启所有权限")
        }
        spawn("chmod 755 \(destDylib)")
        spawn("chown root:wheel \(destDylib)")

        // 2. 用 ldid 重签名 dylib
        let selfEnts = Bundle.main.path(forResource: "AIReverse", ofType: "entitlements") ?? ""
        if !selfEnts.isEmpty { spawn("ldid -S\(selfEnts) \(destDylib)") }
        else { spawn("ldid -S \(destDylib)") }

        // 3. 修改 Mach-O，写入 LC_LOAD_DYLIB
        // 用 jtool 或直接修改二进制
        // 方式 A：用 jtool（如果存在）
        // 方式 B：用 python 脚本修改 Mach-O
        // 方式 C：后备方案，使用 DYLD_INSERT_LIBRARIES

        let dylibInstallPath = "@executable_path/\(dylibName)"
        var machoModified = false

        // 尝试 jtool 方式
        let (jtoolCode, _) = spawn("jtool --inplace --LC_LOAD_DYLIB=\(dylibInstallPath) \(mainBinary) 2>/dev/null")
        if jtoolCode == 0 {
            machoModified = true
            method = "LC_LOAD_DYLIB (jtool)"
        }

        // 如果 jtool 失败，尝试用 python 脚本
        if !machoModified {
            let pythonScript = """
            import struct, sys
            if len(sys.argv) < 3:
                sys.exit(1)
            binary_path = sys.argv[1]
            dylib_path = sys.argv[2]
            try:
                with open(binary_path, 'r+b') as f:
                    data = bytearray(f.read())
                    # 检查 fat header
                    magic = struct.unpack('<I', data[:4])[0]
                    if magic == 0xBEBAFECA:  # FAT
                        arch_count = struct.unpack('<I', data[4:8])[0]
                        offset = 8
                        for i in range(arch_count):
                            cpu = struct.unpack('<I', data[offset:offset+4])[0]
                            sub = struct.unpack('<I', data[offset+4:offset+8])[0]
                            arch_off = struct.unpack('<I', data[offset+8:offset+12])[0]
                            arch_size = struct.unpack('<I', data[offset+12:offset+16])[0]
                            # 处理 arm64
                            if cpu == 0x0100000c:
                                modify_macho(data, arch_off, arch_size, dylib_path)
                            offset += 20
                    elif magic == 0xFEEDFACF:  # ARM64
                        modify_macho(data, 0, len(data), dylib_path)
                    else:
                        sys.exit(2)
                    f.seek(0)
                    f.write(data)
                    sys.exit(0)
            except:
                sys.exit(3)
            def modify_macho(data, base, size, dylib_path):
                header = struct.unpack_from('<IIIIIIII', data, base)
                ncmds = header[4]
                sizeofcmds = header[5]
                cmd_offset = base + 32
                cmd_data = data[cmd_offset:cmd_offset+sizeofcmds]
                # 检查是否已存在 LC_LOAD_DYLIB 指向我们的 dylib
                pos = 0
                while pos < sizeofcmds:
                    cmd = struct.unpack_from('<I', cmd_data, pos)[0]
                    cmdsize = struct.unpack_from('<I', cmd_data, pos+4)[0]
                    if cmd == 0x0C:  # LC_LOAD_DYLIB
                        name_off = struct.unpack_from('<I', cmd_data, pos+8)[0]
                        name = cmd_data[pos+name_off:pos+cmdsize]
                        name = name[:name.index(b'\\x00')].decode()
                        if name == dylib_path:
                            return  # 已存在，跳过
                    pos += cmdsize
                # 构建新的 LC_LOAD_DYLIB
                name_bytes = dylib_path.encode() + b'\\x00'
                cmd_size = 24 + len(name_bytes)
                # 对齐到 8
                if cmd_size % 8 != 0:
                    cmd_size += 8 - (cmd_size % 8)
                new_cmd = bytearray(cmd_size)
                struct.pack_into('<III', new_cmd, 0, 0x0C, cmd_size, 24)
                new_cmd[24:24+len(name_bytes)] = name_bytes
                # 追加到 load commands 末尾
                new_size = sizeofcmds + cmd_size
                # 需要在 header 后插入，同时移动后面的内容
                # 简单方式：在文件末尾追加
                # 更新 header
                remaining = data[cmd_offset+sizeofcmds:base+size]
                # 插入新命令
                data[cmd_offset+sizeofcmds:cmd_offset+sizeofcmds] = new_cmd
                # 更新 header 中的 ncmds 和 sizeofcmds
                import struct
                # 重新计算
                struct.pack_into('<II', data, base+32, ncmds+1, sizeofcmds+cmd_size)
            """
            let scriptPath = "/tmp/macho_inject.py"
            try? pythonScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let (pyCode, _) = spawn("python3 \(scriptPath) \(mainBinary) \(dylibInstallPath)")
            if pyCode == 0 {
                machoModified = true
                method = "LC_LOAD_DYLIB (python)"
            }
            try? FileManager.default.removeItem(atPath: scriptPath)
        }

        // 后备方案：DYLD_INSERT_LIBRARIES
        if !machoModified {
            method = "DYLD_INSERT_LIBRARIES"
            let plistCmd = "/usr/libexec/PlistBuddy -c 'Add :DYLD_INSERT_LIBRARIES string @executable_path/\(dylibName)' \(infoPlist)"
            let (plistCode, _) = spawn(plistCmd)
            if plistCode != 0 {
                let setCmd = "/usr/libexec/PlistBuddy -c 'Set :DYLD_INSERT_LIBRARIES @executable_path/\(dylibName)' \(infoPlist)"
                let (setCode, _) = spawn(setCmd)
                if setCode != 0 {
                    throw InjectionError.failed("修改 Info.plist 失败")
                }
            }
        }

        // 4. 用 ldid 重签名主二进制
        let entFile = (appBundle as NSString).appendingPathComponent(".AIReverse_ent.plist")
        spawn("ldid -e \(mainBinary) > \(entFile)")
        spawn("ldid -S\(entFile) \(mainBinary)")
        spawn("rm -f \(entFile)")

        // 5. 清理旧 CodeSignature
        if FileManager.default.fileExists(atPath: codeSignDir) {
            spawn("rm -rf \(codeSignDir)")
        }

        // 6. uicache 刷新
        spawn("/usr/bin/uicache -p \(appBundle)")

        let record = InjectionRecord(
            appBundleID: app.bundleID,
            appName: app.displayName,
            dylibName: dylibName,
            appBundlePath: appBundle,
            method: method,
            status: "注入成功",
            message: "已通过 \(method) 注入 \(dylibName) 到 \(app.displayName)\n重启应用后生效。"
        )
        recentInjections.insert(record, at: 0)
        return record.message
    }

    @discardableResult
    private func spawn(_ command: String) -> (Int32, String) {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command)]
        argv.append(nil)
        var env: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/var/jb/usr/bin")]
        env.append(nil)
        let result = posix_spawn(&pid, "/bin/sh", nil, nil, argv, env)
        defer { for a in argv { if let a { free(a) } } }
        defer { for e in env { if let e { free(e) } } }
        guard result == 0 else { return (result, "posix_spawn 失败") }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return ((status >> 8) & 0xFF, "")
    }
}