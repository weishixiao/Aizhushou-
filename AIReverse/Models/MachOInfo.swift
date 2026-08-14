import Foundation

struct MachOInfo {
    var fileName: String = ""
    var isFat: Bool = false
    var architectures: [ArchInfo] = []
    var header: String = ""
    var loadCommands: [String] = []
    var segments: [SegmentInfo] = []
    var symbolCount: Int = 0
    var symbols: [SymbolEntry] = []
    var objcClassCount: Int = 0
    var strings: [String] = []
    var errorMessage: String?
}

struct ArchInfo {
    var cpuType: String = ""
    var cpuSubtype: String = ""
    var offset: UInt64 = 0
    var size: UInt64 = 0
}

struct SegmentInfo {
    var name: String = ""
    var vmAddr: UInt64 = 0
    var vmSize: UInt64 = 0
    var fileOffset: UInt64 = 0
    var fileSize: UInt64 = 0
}

struct ObjCClassInfo {
    var name: String = ""
    var superclassName: String = ""
    var methods: [ObjCMethod] = []
    var address: UInt64 = 0
}

struct ObjCMethod {
    var selector: String = ""
    var imp: UInt64 = 0
    var typeEncoding: String = ""
}

struct SymbolEntry {
    var name: String = ""
    var address: UInt64 = 0
    var type: String = ""
}
