//
//  DylibHideHelper.swift
//  AIReverse
//
//  根据「iOS 注入攻击检测原理」文档设计的逆向优化模块
//
//  检测原理与绕过策略：
//  - 原理 1：_dyld_image_count + _dyld_get_image_name → 可绕过（hook dyld 函数）
//  - 原理 2：_dyld_register_func_for_add_image + dladdr → 可绕过（拦截回调）
//  - 原理 3：Mach task_info(TASK_DYLD_INFO) → 不可绕过（内核级）
//  - 原理 4：地址范围 0x18~0x20 → 部分可绕过
//
//  本模块提供：
//  1. 注册 dyld 回调，监控新 dylib 加载（用于自检）
//  2. 获取当前进程所有加载的 dylib 信息
//  3. 判断 dylib 是否在共享缓存范围内
//  4. 判断进程是否被注入 dylib
//
//  注意：真正的 dyld 函数 hook 需要在 C/Objective-C 层实现
//        或使用 DYLD_INTERPOSE 注入 dylib 到目标进程
//

import Foundation
import MachO

// MARK: - dyld 函数类型定义

typealias DyldImageCountFn = @convention(c) () -> UInt32
typealias DyldGetImageNameFn = @convention(c) (UInt32) -> UnsafePointer<CChar>?
typealias DyldGetImageAddressFn = @convention(c) (UInt32) -> UnsafeRawPointer?
typealias DyldRegisterFuncFn = @convention(c) (@convention(c) (Int32, UnsafeRawPointer?) -> Void) -> Void
typealias DladdrFn = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<dl_info>) -> Int32

// 回调使用文件级全局状态，避免闭包捕获上下文（C 函数指针要求无捕获）
private var dylibHideCallbackNameFn: DyldGetImageNameFn?
private var dylibHideCallbackHandler: ((String) -> Void)?

// MARK: - dyld 共享缓存地址范围

/// 共享缓存地址范围（根据文档）
public struct SharedCacheRange {
    public static let base: UInt64 = 0x180000000
    public static let end: UInt64 = 0x200000000
    public static let size: UInt64 = end - base
    
    /// 判断地址是否在共享缓存范围内
    public static func contains(_ address: UInt64) -> Bool {
        return address >= base && address < end
    }
}

// MARK: - dylib 信息

public struct DylibInfo: CustomStringConvertible {
    public let name: String
    public let address: UInt64
    public let inSharedCache: Bool
    public let isSystem: Bool
    public let isSuspect: Bool
    
    public var description: String {
        let cacheTag = inSharedCache ? "📦" : "📂"
        let systemTag = isSystem ? "✅" : "❓"
        let suspectTag = isSuspect ? "🔴" : "🟢"
        return "\(cacheTag) \(systemTag) \(suspectTag) \(name) @ 0x\(String(address, radix: 16))"
    }
}

// MARK: - 注入检测辅助

/// 根据文档描述的实现检测原理的辅助类
public class DylibHideHelper {
    private static var dyldHandle: UnsafeMutableRawPointer?
    private static var imageCountFn: DyldImageCountFn?
    private static var getImageNameFn: DyldGetImageNameFn?
    private static var getImageAddressFn: DyldGetImageAddressFn?
    private static var registerFuncFn: DyldRegisterFuncFn?
    private static var dladdrFn: DladdrFn?
    private static var registeredCallback: Bool = false
    public static var onDylibLoaded: ((String) -> Void)?
    
    // MARK: - 初始化
    
    private static func ensureDyldLoaded() -> Bool {
        if dyldHandle != nil { return true }
        // 使用 RTLD_DEFAULT 获取当前进程所有已加载符号
        dyldHandle = dlopen(nil, RTLD_LAZY)
        if dyldHandle == nil {
            dyldHandle = dlopen("/usr/lib/libSystem.dylib", RTLD_LAZY)
            guard let handle = dyldHandle else { return false }
            
            imageCountFn = unsafeBitCast(
                dlsym(handle, "_dyld_image_count"),
                to: DyldImageCountFn.self
            )
            getImageNameFn = unsafeBitCast(
                dlsym(handle, "_dyld_get_image_name"),
                to: DyldGetImageNameFn.self
            )
            getImageAddressFn = unsafeBitCast(
                dlsym(handle, "_dyld_image_address"),
                to: DyldGetImageAddressFn.self
            )
            registerFuncFn = unsafeBitCast(
                dlsym(handle, "_dyld_register_func_for_add_image"),
                to: DyldRegisterFuncFn.self
            )
            
            let dlHandle = dlopen("libdyld.dylib", RTLD_LAZY) ?? dlopen(nil, RTLD_LAZY)
            if let dlHandle = dlHandle, let sym = dlsym(dlHandle, "dladdr") {
                dladdrFn = unsafeBitCast(sym, to: DladdrFn.self)
            }
            return true
        }
        return false
    }
    
    // MARK: - 方法 1：获取所有加载的 dylib
    
    /// 获取当前进程所有已加载的 dylib 信息
    public static func allLoadedDylibs() -> [DylibInfo] {
        guard ensureDyldLoaded() else { return [] }
        guard let countFn = imageCountFn, let nameFn = getImageNameFn else { return [] }
        
        let count = countFn()
        var results: [DylibInfo] = []
        
        for i in 0..<count {
            guard let name = nameFn(i) else { continue }
            let libName = String(cString: name)
            let addr = getImageAddressFn?(i)
            let addrValue: UInt64
            if let addr = addr {
                addrValue = UInt64(UInt(bitPattern: addr))
            } else {
                addrValue = 0
            }
            
            let inSharedCache = SharedCacheRange.contains(addrValue)
            let isSystem = isSystemDylib(libName)
            let isSuspect = isSuspectDylib(libName, address: addrValue)
            
            results.append(DylibInfo(
                name: libName,
                address: addrValue,
                inSharedCache: inSharedCache,
                isSystem: isSystem,
                isSuspect: isSuspect
            ))
        }
        return results
    }
    
    // MARK: - 方法 1&2：检测是否被注入
    
    /// 检测当前进程是否被注入了可疑 dylib（结合方法 1、2、4）
    public static func detectInjection() -> (found: Bool, suspects: [String], totalLibs: Int) {
        let libs = allLoadedDylibs()
        let suspects = libs.filter { $0.isSuspect }.map { $0.name }
        return (found: !suspects.isEmpty, suspects: suspects, totalLibs: libs.count)
    }
    
    // MARK: - 方法 2：注册 dyld 回调
    
    /// 注册回调：当新 dylib 加载时通知
    public static func registerDylibCallback() -> Bool {
        guard ensureDyldLoaded(), !registeredCallback else { return true }
        guard let regFn = registerFuncFn, let nameFn = getImageNameFn else { return false }

        dylibHideCallbackNameFn = nameFn
        dylibHideCallbackHandler = onDylibLoaded

        regFn { imageIndex, _ in
            guard let nameFn = dylibHideCallbackNameFn else { return }
            let name = nameFn(UInt32(imageIndex))
            if let name = name {
                dylibHideCallbackHandler?(String(cString: name))
            }
        }
        registeredCallback = true
        return true
    }
    
    // MARK: - 方法 4：地址范围检查
    
    /// 检查指定地址是否在共享缓存范围内
    public static func isInSharedCache(_ address: UInt64) -> Bool {
        return SharedCacheRange.contains(address)
    }
    
    // MARK: - 辅助判断
    
    private static func isSystemDylib(_ name: String) -> Bool {
        let systemPrefixes = [
            "/System/",
            "/usr/lib/",
            "/usr/private/",
            "/private/",
            "/var/jb/usr/lib/",
            "/usr/lib/system/libsystem",
        ]
        return systemPrefixes.contains { name.hasPrefix($0) }
    }
    
    private static func isSuspectDylib(_ name: String, address: UInt64) -> Bool {
        // 系统白名单
        if isSystemDylib(name) {
            return false
        }
        
        // 已知系统库
        let knownSystemLibs = [
            "CoreFoundation", "UIKit", "Foundation", "AppKit",
            "Security", "CoreGraphics", "CoreText", "CoreImage",
            "Accelerate", "AVFoundation", "WebKit", "Photos",
            "MapKit", "Contacts", "MessageUI", "GameKit",
            "GameplayKit", "SceneKit", "SpriteKit", "Metal",
            "MetalKit", "RealityKit", "ARKit", "CoreML",
            "NaturalLanguage", "Intents", "CoreMotion",
            "CoreLocation", "CoreBluetooth", "PassKit",
            "StoreKit", "UserNotifications", "WatchConnectivity",
            "CarPlay", "CallKit", "VideoToolbox", "ImageIO",
            "MobileCoreServices", "SafariServices", "Network",
            "NetworkExtension", "CloudKit", "Social", "Accounts",
            "EventKit", "HealthKit", "HomeKit", "MultipeerConnectivity",
        ]
        
        if knownSystemLibs.contains { name.contains("Frameworks/\($0).framework") } {
            return false
        }
        
        // 可疑特征
        let suspiciousPatterns = [
            ".tweak", "tweak", "substrate", "cydia",
            "libsubstrate", "libhooker", "libactivate",
            "libactivator", "libflex",
            ".dynamic", "MobileTerminal",
            "libsubstrate.dylib", "libactivate.dylib",
            "libhooker.dylib", "libactivator.dylib",
        ]
        
        if suspiciousPatterns.contains { name.contains($0) } {
            return true
        }
        
        // 非系统路径 + 不在共享缓存范围内
        let nonSystemPrefixes = [
            "/var/jb/",
            "/tmp/",
            "/private/var/",
            "/var/mobile/",
            "/var/containers/",
        ]
        
        if nonSystemPrefixes.contains { name.hasPrefix($0) } {
            // 如果路径在越狱目录但不在 /var/jb/usr/lib/ 下，可疑
            if name.hasPrefix("/var/jb/") && !name.hasPrefix("/var/jb/usr/lib/") {
                return true
            }
            // 如果地址不在共享缓存范围内，可疑
            if !SharedCacheRange.contains(address) && !name.contains("Frameworks/") {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - 清理
    
    /// 清理资源
    public static func cleanup() {
        if let handle = dyldHandle {
            dlclose(handle)
        }
        dyldHandle = nil
        imageCountFn = nil
        getImageNameFn = nil
        getImageAddressFn = nil
        registerFuncFn = nil
        dladdrFn = nil
        registeredCallback = false
        onDylibLoaded = nil
    }
}
