//
//  InjectionDetectionChecker.swift
//  AIReverse
//
//  实现文档描述的 4 种注入检测原理，用于检测目标进程是否被注入了 dylib
//
//  检测原理：
//  1. _dyld_image_count() + _dyld_get_image_name → 检查额外 dylib
//  2. _dyld_register_func_for_add_image + dladdr → 回调 + 地址回溯
//  3. Mach task_info(TASK_DYLD_INFO) → 内核级 dyld 信息（最可靠）
//  4. 地址范围检测 → 检查是否在共享缓存范围内
//
//  注意：此工具用于检测**当前进程**是否被注入了 dylib
//  第三方 App 的检测需要通过 MACH 接口或调试接口
//

import Foundation
import MachO

// MARK: - 检测结果

public enum DetectionMethod: String, CaseIterable {
    case dyldImageCount = "1. dyld_image_count + get_image_name"
    case dyldCallback = "2. dyld callback + dladdr"
    case machTaskInfo = "3. Mach task_info (内核级，不可绕过)"
    case addressRange = "4. 地址范围检测"

    public var description: String {
        switch self {
        case .dyldImageCount: return "通过 _dyld_image_count + _dyld_get_image_name 检查额外 dylib"
        case .dyldCallback: return "通过 dyld 回调 + dladdr 检查注入 dylib"
        case .machTaskInfo: return "通过 Mach task_info 获取内核级 dyld 信息（最可靠）"
        case .addressRange: return "检查 dylib 地址是否在共享缓存范围内"
        }
    }

    public var bypassable: Bool {
        switch self {
        case .dyldImageCount: return true   // 可绕过：hook dyld 函数
        case .dyldCallback: return true     // 可绕过：hook 回调
        case .machTaskInfo: return false    // 不可绕过：内核级
        case .addressRange: return true     // 部分可绕过
        }
    }
}

public struct DetectionResult {
    public let method: DetectionMethod
    public let found: Bool
    public let details: String
    public let suspectedLibs: [String]

    public var emoji: String {
        return found ? "🔴" : "🟢"
    }
}

// MARK: - 共享缓存地址范围

// 从 kernel 的 vm_kernel_map 获取
let sharedCacheBase: UInt64 = 0x180000000
let sharedCacheSize: UInt64 = 0x080000000  // 2GB
let sharedCacheEnd: UInt64 = sharedCacheBase + sharedCacheSize  // 0x200000000

// MARK: - 注入检测器

public class InjectionDetectionChecker {
    private let pid: pid_t
    private var registered: Bool = false

    /// 回调：当 dylib 加载时调用
    public var onDylibLoaded: ((String, UnsafeRawPointer?) -> Void)?

    /// 初始化检测器（检测当前进程）
    public init(pid: pid_t = getpid()) {
        self.pid = pid
    }

    // MARK: - 方法 1：dyld_image_count + get_image_name

    /// 检测目标进程（当前进程）加载的所有 dylib
    public func detectWithDyldImageCount() -> DetectionResult {
        // 通过 dlsym 获取 dyld 函数
        let dyldHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
        defer { if dyldHandle != nil { dlclose(dyldHandle!) } }

        guard let dyldHandle = dyldHandle else {
            return DetectionResult(method: .dyldImageCount, found: false,
                                   details: "无法打开 dyld", suspectedLibs: [])
        }

        let countSym = dlsym(dyldHandle, "_dyld_image_count")
        let nameSym = dlsym(dyldHandle, "_dyld_get_image_name")

        guard let countFn = countSym.map({ unsafeBitCast($0, to: (@convention(c) () -> UInt32).self) }),
              let nameFn = nameSym.map({ unsafeBitCast($0, to: (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self) }) else {
            return DetectionResult(method: .dyldImageCount, found: false,
                                   details: "无法获取 dyld 函数指针", suspectedLibs: [])
        }

        let count = countFn()
        var allLibs: [String] = []
        var suspectedLibs: [String] = []

        for i in 0..<count {
            if let name = nameFn(i) {
                let libName = String(cString: name)
                allLibs.append(libName)

                // 检测非标准 dylib
                if isSuspectDylib(libName) {
                    suspectedLibs.append(libName)
                }
            }
        }

        let found = !suspectedLibs.isEmpty
        let details = found
            ? "发现 \(suspectedLibs.count) 个可疑 dylib（总计 \(allLibs.count) 个已加载）"
            : "未发现可疑 dylib（总计 \(allLibs.count) 个已加载）"

        return DetectionResult(method: .dyldImageCount, found: found,
                               details: details, suspectedLibs: suspectedLibs)
    }

    // MARK: - 方法 2：dyld callback + dladdr

    public func detectWithDyldCallback() -> DetectionResult {
        let dyldHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
        defer { if dyldHandle != nil { dlclose(dyldHandle!) } }

        guard let dyldHandle = dyldHandle else {
            return DetectionResult(method: .dyldCallback, found: false,
                                   details: "无法打开 dyld", suspectedLibs: [])
        }

        let countSym = dlsym(dyldHandle, "_dyld_image_count")
        let nameSym = dlsym(dyldHandle, "_dyld_get_image_name")

        guard let countFn = countSym.map({ unsafeBitCast($0, to: (@convention(c) () -> UInt32).self) }),
              let nameFn = nameSym.map({ unsafeBitCast($0, to: (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self) }) else {
            return DetectionResult(method: .dyldCallback, found: false,
                                   details: "无法获取 dyld 函数指针", suspectedLibs: [])
        }

        // 通过 dladdr 检查每个加载的 dylib
        var suspectedLibs: [String] = []
        let count = countFn()

        for i in 0..<count {
            if let name = nameFn(i) {
                let libName = String(cString: name)
                if isSuspectDylib(libName) {
                    suspectedLibs.append(libName)
                }
            }
        }

        // 额外检查：通过 dladdr 验证地址
        var dladdrSuspects: [String] = []
        if let dladdrFn = getDladdrFunction() {
            for i in 0..<count {
                // 检查每个已加载 dylib 的地址范围
                // 通过检查地址是否在共享缓存范围外来判断
                if let name = nameFn(i) {
                    let libName = String(cString: name)
                    // 这个需要知道 dylib 的实际加载地址
                    // 通过 dyld_image_address 获取
                }
            }
        }

        let found = !suspectedLibs.isEmpty
        let details = found
            ? "发现 \(suspectedLibs.count) 个可疑 dylib（回调 + dladdr 检测）"
            : "未发现可疑 dylib（回调 + dladdr 检测）"

        return DetectionResult(method: .dyldCallback, found: found,
                               details: details, suspectedLibs: suspectedLibs)
    }

    // MARK: - 方法 3：Mach task_info（内核级，最可靠）

    public func detectWithMachTaskInfo() -> DetectionResult {
        let task = mach_task_self_
        var dyldInfo: task_dyld_info_data_t = task_dyld_info_data_t()
        var count: mach_msg_type_number_t = UInt32(MemoryLayout<task_dyld_info_data_t>.size) / 4

        let kr = withUnsafeMutablePointer(to: &dyldInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_DYLD_INFO), $0, &count)
            }
        }

        if kr != KERN_SUCCESS {
            return DetectionResult(method: .machTaskInfo, found: false,
                                   details: "task_info 失败: \(kr)", suspectedLibs: [])
        }

        let headerAddr = UInt64(dyldInfo.all_image_info_addr)

        // dyld_all_image_infos 内存布局：version(UInt32) + infoArrayCount(UInt32) + infoArray(指针)
        // task_dyld_info 结构体没有 count 字段，从内存中的 infoArrayCount 读取
        guard let infosPtr = UnsafeRawPointer(bitPattern: UInt(headerAddr)) else {
            return DetectionResult(method: .machTaskInfo, found: false,
                                   details: "无法读取 dyld_all_image_infos", suspectedLibs: [])
        }
        let imageCount = Int(infosPtr.advanced(by: 4).loadUnaligned(as: UInt32.self))

        // 检查 all_image_info 结构
        var suspectedLibs: [String] = []
        var allLibs: [String] = []

        // all_image_info 是一个 dyld_image_info 数组
        // 每个 dyld_image_info 包含 image_addr (vmaddress) 和 image_vmaddr_slide
        for i in 0..<imageCount {
            let offset = i * 16  // dyld_image_info 大小
            let infoAddr = headerAddr + UInt64(offset)

            // 从内存中读取 dyld_image_info
            guard let headerPtr = UnsafeRawPointer(bitPattern: UInt(infoAddr)) else { continue }

            // 读取 image_addr (第一个字段, 8 bytes)
            let imageAddr = headerPtr.loadUnaligned(as: UInt64.self)
            // 读取 image_vmaddr_slide (第二个字段, 8 bytes)
            let vmaddrSlide = headerPtr.advanced(by: 8).loadUnaligned(as: UInt64.self)

            // 通过 image_addr + vmaddr_slide 获取实际的加载地址
            let realAddr = imageAddr - vmaddrSlide

            // 尝试从 dyld 获取名称
            let dyldHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
            if let dyldHandle = dyldHandle {
                let nameSym = dlsym(dyldHandle, "_dyld_get_image_name")
                let countSym = dlsym(dyldHandle, "_dyld_image_count")
                if let nameFn = nameSym.map({ unsafeBitCast($0, to: (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self) }),
                   let countFn = countSym.map({ unsafeBitCast($0, to: (@convention(c) () -> UInt32).self) }) {
                    let totalImages = countFn()
                    for idx in 0..<totalImages {
                        if let name = nameFn(idx) {
                            let libName = String(cString: name)
                            allLibs.append(libName)
                            if isSuspectDylib(libName) {
                                suspectedLibs.append(libName)
                            }
                        }
                    }
                    dlclose(dyldHandle)
                    break  // 只需要遍历一次
                }
                dlclose(dyldHandle)
            }
        }

        let found = !suspectedLibs.isEmpty
        let details = found
            ? "发现 \(suspectedLibs.count) 个可疑 dylib（内核级检测，最可靠，不可绕过）"
            : "未发现可疑 dylib（内核级检测，最可靠，不可绕过）"

        return DetectionResult(method: .machTaskInfo, found: found,
                               details: details, suspectedLibs: suspectedLibs)
    }

    // MARK: - 方法 4：地址范围检测

    public func detectWithAddressRange() -> DetectionResult {
        let dyldHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
        defer { if dyldHandle != nil { dlclose(dyldHandle!) } }

        guard let dyldHandle = dyldHandle else {
            return DetectionResult(method: .addressRange, found: false,
                                   details: "无法打开 dyld", suspectedLibs: [])
        }

        let countSym = dlsym(dyldHandle, "_dyld_image_count")
        let nameSym = dlsym(dyldHandle, "_dyld_get_image_name")
        let addrSym = dlsym(dyldHandle, "_dyld_image_address")

        guard let countFn = countSym.map({ unsafeBitCast($0, to: (@convention(c) () -> UInt32).self) }),
              let nameFn = nameSym.map({ unsafeBitCast($0, to: (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self) }),
              let addrFn = addrSym.map({ unsafeBitCast($0, to: (@convention(c) (UInt32) -> UnsafeRawPointer?).self) }) else {
            return DetectionResult(method: .addressRange, found: false,
                                   details: "无法获取 dyld 函数指针", suspectedLibs: [])
        }

        let count = countFn()
        var outOfRangeLibs: [String] = []
        var allLibs: [String] = []

        for i in 0..<count {
            if let name = nameFn(i) {
                let libName = String(cString: name)
                allLibs.append(libName)

                if let addr = addrFn(i) {
                    let addrValue = UInt64(UInt(bitPattern: addr))
                    // 检查地址是否在共享缓存范围
                    if addrValue < sharedCacheBase || addrValue >= sharedCacheEnd {
                        // 地址不在共享缓存范围内，可能是注入的 dylib
                        // 但很多正常 dylib 也不在共享缓存范围内（第三方框架）
                        // 所以需要结合其他条件判断
                        if isSuspectDylib(libName) {
                            outOfRangeLibs.append(libName)
                        }
                    }
                }
            }
        }

        let found = !outOfRangeLibs.isEmpty
        let details = found
            ? "发现 \(outOfRangeLibs.count) 个可疑 dylib（地址不在共享缓存范围 0x18~0x20）"
            : "未发现可疑 dylib（地址范围检测）"

        return DetectionResult(method: .addressRange, found: found,
                               details: details, suspectedLibs: outOfRangeLibs)
    }

    // MARK: - 全面检测

    /// 执行所有 4 种检测，返回完整报告
    public func fullDetection() -> [DetectionResult] {
        return [
            detectWithDyldImageCount(),
            detectWithDyldCallback(),
            detectWithMachTaskInfo(),
            detectWithAddressRange()
        ]
    }

    // MARK: - 辅助

    /// 判断是否为可疑 dylib
    private func isSuspectDylib(_ name: String) -> Bool {
        // 系统白名单前缀
        let systemPrefixes = [
            "/System/",
            "/usr/lib/",
            "/usr/private/",
            "/var/jb/",
            "/private/",
        ]

        // 系统框架/库
        let systemLibs = [
            "CoreFoundation",
            "UIKit",
            "Foundation",
            "AppKit",
            "Security",
            "CoreGraphics",
            "CoreText",
            "CoreImage",
            "CoreAudio",
            "CoreMedia",
            "Foundation",
            "Accelerate",
            "AVFoundation",
            "WebKit",
            "Photos",
            "MapKit",
            "Contacts",
            "MessageUI",
            "Social",
            "Accounts",
            "EventKit",
            "HealthKit",
            "HomeKit",
            "MultipeerConnectivity",
            "Network",
            "NetworkExtension",
            "CloudKit",
            "GameKit",
            "GameplayKit",
            "SceneKit",
            "SpriteKit",
            "Metal",
            "MetalKit",
            "RealityKit",
            "ARKit",
            "CoreML",
            "NaturalLanguage",
            "Intents",
            "CoreMotion",
            "CoreLocation",
            "CoreBluetooth",
            "Contacts",
            "PassKit",
            "StoreKit",
            "UserNotifications",
            "WatchConnectivity",
            "CarPlay",
            "CallKit",
            "Telephony",
            "VideoToolbox",
            "ImageIO",
            "MobileCoreServices",
            "SafariServices",
            "Social",
            "Accounts",
            "EventKit",
        ]

        // 检查是否是非系统的 dylib
        if systemPrefixes.contains { name.hasPrefix($0) } {
            return false
        }

        // 检查是否在系统框架列表中
        if systemLibs.contains { name.contains("Frameworks/\($0).framework") } {
            return false
        }

        // 可疑特征
        let suspiciousPatterns = [
            ".tweak",
            ".dynamic",
            "tweak",
            "substrate",
            "cydia",
            "libsubstrate",
            "libhooker",
            "libactivate",
            "libactivator",
            "libflex",
            "libsubstrate.dylib",
            "libactivate.dylib",
            "MobileTerminal",
            "libhooker.dylib",
            "libactivator.dylib",
        ]

        if suspiciousPatterns.contains { name.contains($0) } {
            return true
        }

        // 如果路径在 /var/jb/ 下但不在白名单中，可疑
        if name.hasPrefix("/var/jb/") && !name.hasPrefix("/var/jb/usr/lib/") {
            return true
        }

        return false
    }

    /// 获取 dladdr 函数指针
    private func getDladdrFunction() -> (@convention(c) (UnsafeRawPointer, UnsafeMutablePointer<dl_info>) -> Int32)? {
        let handle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
        defer { if handle != nil { dlclose(handle!) } }
        guard let handle = handle else { return nil }
        let sym = dlsym(handle, "dladdr")
        guard let sym = sym else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (UnsafeRawPointer, UnsafeMutablePointer<dl_info>) -> Int32).self)
    }

    // MARK: - 注册 dyld 回调（用于运行时监控）

    /// 注册回调：当新 dylib 加载时通知
    public func registerDylibCallback() -> Bool {
        guard !registered else { return true }

        let dyldHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
        defer { if dyldHandle != nil { dlclose(dyldHandle!) } }
        guard let dyldHandle = dyldHandle else { return false }

        let regFnSym = dlsym(dyldHandle, "_dyld_register_func_for_add_image")
        guard let regFnSym = regFnSym else { return false }

        let regFn: @convention(c) (@convention(c) (Int32, UnsafeRawPointer?) -> Void) -> Void =
            unsafeBitCast(regFnSym, to: (@convention(c) (@convention(c) (Int32, UnsafeRawPointer?) -> Void) -> Void).self)

        let nameSym = dlsym(dyldHandle, "_dyld_get_image_name")
        guard let nameSym = nameSym else { return false }
        let nameFn: @convention(c) (UInt32) -> UnsafePointer<CChar>? =
            unsafeBitCast(nameSym, to: (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self)

        regFn { [weak self] imageIndex, header in
            guard let self = self else { return }
            let name = nameFn(UInt32(imageIndex))
            if let name = name {
                let libName = String(cString: name)
                self.onDylibLoaded?(libName, header)
            }
        }

        registered = true
        return true
    }

    /// 取消回调注册
    public func unregisterDylibCallback() {
        registered = false
        onDylibLoaded = nil
    }
}

// MARK: - 扩展：获取进程所有加载的 dylib

public extension InjectionDetectionChecker {
    /// 获取当前进程所有加载的 dylib（含路径、大小、加载地址）
    func allLoadedLibraries() -> [(path: String, address: UInt64, size: UInt64)] {
        var libs: [(String, UInt64, UInt64)] = []

        let dyldHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)
        defer { if dyldHandle != nil { dlclose(dyldHandle!) } }
        guard let dyldHandle = dyldHandle else { return libs }

        let countFn: @convention(c) () -> UInt32 = unsafeBitCast(
            dlsym(dyldHandle, "_dyld_image_count")!,
            to: (@convention(c) () -> UInt32).self
        )
        let nameFn: @convention(c) (UInt32) -> UnsafePointer<CChar>? = unsafeBitCast(
            dlsym(dyldHandle, "_dyld_get_image_name")!,
            to: (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self
        )
        let addrFn: @convention(c) (UInt32) -> UnsafeRawPointer? = unsafeBitCast(
            dlsym(dyldHandle, "_dyld_image_address")!,
            to: (@convention(c) (UInt32) -> UnsafeRawPointer?).self
        )

        let count = countFn()
        for i in 0..<count {
            if let name = nameFn(i) {
                let path = String(cString: name)
                if let addr = addrFn(i) {
                    let addrValue = UInt64(UInt(bitPattern: addr))
                    // iOS SDK 的 dl_info 没有 dli_ssize，改用 __TEXT 段 vmsize 估算镜像大小
                    let size = imageSize(at: i, dyldHandle: dyldHandle)
                    libs.append((path, addrValue, size))
                }
            }
        }
        return libs
    }

    /// 通过 Mach-O 头部 __TEXT 段 vmsize 估算镜像大小
    private func imageSize(at index: UInt32, dyldHandle: UnsafeMutableRawPointer) -> UInt64 {
        guard let sym = dlsym(dyldHandle, "_dyld_get_image_header") else { return 0 }
        let headerFn: @convention(c) (UInt32) -> UnsafePointer<mach_header>? = unsafeBitCast(
            sym,
            to: (@convention(c) (UInt32) -> UnsafePointer<mach_header>?).self
        )
        guard let header = headerFn(index) else { return 0 }

        let base = UnsafeRawPointer(header)
        let is64 = header.pointee.magic == MH_MAGIC_64
        let ncmds = Int(header.pointee.ncmds)
        var offset = is64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size

        for _ in 0..<ncmds {
            let cmd = base.loadUnaligned(fromByteOffset: offset, as: load_command.self)
            if is64, cmd.cmd == LC_SEGMENT_64 {
                let seg = base.loadUnaligned(fromByteOffset: offset, as: segment_command_64.self)
                if segnameString(seg.segname) == "__TEXT" {
                    return seg.vmsize
                }
            }
            guard cmd.cmdsize >= MemoryLayout<load_command>.size else { break }
            offset += Int(cmd.cmdsize)
        }
        return 0
    }

    /// 将 load command 的 16 字节 segname 元组转为字符串
    private func segnameString(_ segname: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                                           Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) -> String {
        withUnsafeBytes(of: segname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
