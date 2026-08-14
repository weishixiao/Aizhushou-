import Foundation

/// 轻量 ARM64 反汇编器。
/// 覆盖常见指令：RET/BR/BLR、B/BL(±128M)、CBZ/CBNZ/TBZ/TBNZ、LDR/STR(立即数/字面量)、
/// ADRP/ADD、MOV(MOVZ/MOVK/MOVN)、NOP、SVC、STP/LDP、条件分支 B.cond、CMP。
/// 未识别指令回退为 .word 显示原始编码。
final class ARM64Disassembler {

    private let code: Data
    private let baseAddr: UInt64

    init(code: Data, baseAddr: UInt64) {
        self.code = code
        self.baseAddr = baseAddr
    }

    private func readU32(_ index: Int) -> UInt32? {
        let off = index * 4
        guard off >= 0, off + 4 <= code.count else { return nil }
        return UInt32(code[off])
            | (UInt32(code[off + 1]) << 8)
            | (UInt32(code[off + 2]) << 16)
            | (UInt32(code[off + 3]) << 24)
    }

    func disassemble(maxInstructions: Int = 2000) -> [DisasmLine] {
        var lines: [DisasmLine] = []
        let total = code.count / 4
        let n = min(total, maxInstructions)

        for i in 0..<n {
            guard let raw = readU32(i) else { break }
            let addr = baseAddr + UInt64(i * 4)
            let start = i * 4
            let end = min((i + 1) * 4, code.count)
            let bytes = Array(code[start..<end])
            let text = decode(raw, address: addr)
            lines.append(DisasmLine(address: addr, bytes: bytes, text: text))
        }
        return lines
    }

    // MARK: - 解码

    private func decode(_ w: UInt32, address: UInt64) -> String {
        // NOP
        if w == 0xD503201F { return "nop" }

        // UDF #0
        if w == 0x00000000 { return "udf #0" }

        // RET xN: 0xD65F0xxx
        if (w & 0xFFFFFC1F) == 0xD65F0000 {
            let rn = (w >> 5) & 0x1F
            return rn == 30 ? "ret" : "ret  x\(rn)"
        }

        // BR / BLR
        if (w & 0xFFFFFC1F) == 0xD61F0000 {
            let rn = (w >> 5) & 0x1F
            // BLR: opc=01, BR: opc=00（opc 位于 bits 30-29，即 w>>30 的高 2 位）
            let isBlr = ((w >> 30) & 0b11) == 0b01
            return isBlr ? "blr x\(rn)" : "br  x\(rn)"
        }

        // B / BL 无条件分支
        if (w & 0x7C000000) == 0x14000000 {
            let isBl = ((w >> 31) & 1) == 1
            let imm26 = w & 0x03FFFFFF
            let offset = signExtend(imm26, bits: 26) << 2
            let target = UInt64(bitPattern: Int64(bitPattern: address) &+ offset)
            return isBl ? "bl   #0x\(String(target, radix: 16))" : "b    #0x\(String(target, radix: 16))"
        }

        // CBZ / CBNZ
        if (w & 0x7E000000) == 0x34000000 {
            let sf = (w >> 31) & 1
            let op = (w >> 24) & 1
            let imm19 = (w >> 5) & 0x7FFFF
            let offset = signExtend(imm19, bits: 19) << 2
            let target = UInt64(bitPattern: Int64(bitPattern: address) &+ offset)
            let rt = w & 0x1F
            let reg = sf == 1 ? "x\(rt)" : "w\(rt)"
            let name = op == 0 ? "cbz" : "cbnz"
            return "\(name) \(reg), #0x\(String(target, radix: 16))"
        }

        // TBZ / TBNZ
        if (w & 0x7E000000) == 0x36000000 {
            let op = (w >> 24) & 1
            let b5 = (w >> 31) & 1
            let imm14 = (w >> 5) & 0x3FFF
            let bitPos = (b5 << 5) | ((w >> 19) & 0x1F)
            let offset = signExtend(imm14, bits: 14) << 2
            let target = UInt64(bitPattern: Int64(bitPattern: address) &+ offset)
            let rt = w & 0x1F
            let name = op == 0 ? "tbz" : "tbnz"
            return "\(name) x\(rt), #\(bitPos), #0x\(String(target, radix: 16))"
        }

        // B.cond
        if (w & 0xFF000010) == 0x54000000 {
            let imm19 = (w >> 5) & 0x7FFFF
            let offset = signExtend(imm19, bits: 19) << 2
            let target = UInt64(bitPattern: Int64(bitPattern: address) &+ offset)
            let cond = Int(w & 0xF)
            return "b.\(condName(cond)) #0x\(String(target, radix: 16))"
        }

        // SVC
        if (w & 0xFFE0001F) == 0xD4000001 {
            let imm16 = (w >> 5) & 0xFFFF
            return "svc #0x\(String(imm16, radix: 16))"
        }

        // LDR (literal) 32/64 位
        if (w & 0x1F000000) == 0x18000000 {
            let sf = (w >> 31) & 1
            let imm19 = (w >> 5) & 0x7FFFF
            let offset = signExtend(imm19, bits: 19) << 2
            let target = UInt64(bitPattern: Int64(bitPattern: address) &+ offset)
            let rt = w & 0x1F
            let size = sf == 1 ? 8 : 4
            return "ldr x\(rt), #0x\(String(target, radix: 16))  ; *0x\(String(target, radix: 16)) (\(size)B)"
        }

        // ADRP
        if (w & 0x9F000000) == 0x90000000 {
            let immhi = (w >> 5) & 0x7FFFF
            let immlo = (w >> 29) & 0x3
            let imm = signExtend((immhi << 2) | immlo, bits: 21) << 12
            let rd = w & 0x1F
            let pageBase = (address & ~UInt64(0xFFF))
            let target = UInt64(bitPattern: Int64(bitPattern: pageBase) &+ imm)
            return "adrp x\(rd), #0x\(String(target, radix: 16))"
        }

        // ADD (immediate) 64位
        if (w & 0xFF000000) == 0x91000000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rd = w & 0x1F
            return "add x\(rd), x\(rn), #0x\(String(imm12, radix: 16))"
        }
        // ADD (immediate) 32位
        if (w & 0xFF000000) == 0x11000000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rd = w & 0x1F
            return "add w\(rd), w\(rn), #0x\(String(imm12, radix: 16))"
        }

        // SUB (immediate) 64位
        if (w & 0xFF000000) == 0xD1000000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rd = w & 0x1F
            return "sub x\(rd), x\(rn), #0x\(String(imm12, radix: 16))"
        }
        // SUB (immediate) 32位
        if (w & 0xFF000000) == 0x51000000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rd = w & 0x1F
            return "sub w\(rd), w\(rn), #0x\(String(imm12, radix: 16))"
        }

        // CMP (immediate) = SUBS xzr, 64位，要求 rd==31
        if (w & 0xFF000000) == 0xF1000000 && (w & 0x1F) == 0x1F {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            return "cmp x\(rn), #0x\(String(imm12, radix: 16))"
        }

        // MOVZ 64位 / 32位
        if (w & 0xFF800000) == 0xD2800000 {
            let hw = (w >> 21) & 0x3
            let imm16 = (w >> 5) & 0xFFFF
            let rd = w & 0x1F
            if imm16 == 0 && hw == 0 { return "mov x\(rd), #0" }
            return "movz x\(rd), #0x\(String(imm16, radix: 16)), lsl #\(hw * 16)"
        }
        if (w & 0xFF800000) == 0x52800000 {
            let hw = (w >> 21) & 0x3
            let imm16 = (w >> 5) & 0xFFFF
            let rd = w & 0x1F
            if imm16 == 0 && hw == 0 { return "mov w\(rd), #0" }
            return "movz w\(rd), #0x\(String(imm16, radix: 16)), lsl #\(hw * 16)"
        }

        // MOVN 64位
        if (w & 0xFF800000) == 0x92800000 {
            let hw = (w >> 21) & 0x3
            let imm16 = (w >> 5) & 0xFFFF
            let rd = w & 0x1F
            return "movn x\(rd), #0x\(String(imm16, radix: 16)), lsl #\(hw * 16)"
        }

        // MOVK 64位
        if (w & 0xFF800000) == 0xF2800000 {
            let hw = (w >> 21) & 0x3
            let imm16 = (w >> 5) & 0xFFFF
            let rd = w & 0x1F
            return "movk x\(rd), #0x\(String(imm16, radix: 16)), lsl #\(hw * 16)"
        }

        // LDP / STP (immediate, 64位)
        if (w & 0xFFC00000) == 0xA9400000 || (w & 0xFFC00000) == 0xA9000000 {
            let isLoad = ((w >> 22) & 1) == 1
            let imm7 = (w >> 15) & 0x7F
            let offset = signExtend(imm7, bits: 7) << 3
            let rt2 = (w >> 10) & 0x1F
            let rn = (w >> 5) & 0x1F
            let rt = w & 0x1F
            let name = isLoad ? "ldp" : "stp"
            let signed = offset < 0 ? "-0x\(String(-offset, radix: 16))" : "+0x\(String(offset, radix: 16))"
            return "\(name) x\(rt), x\(rt2), [x\(rn), \(signed)]"
        }

        // MOV xd, xm (ORR shifted register 别名)
        if (w & 0x7FE0FFE0) == 0xAA0003E0 {
            let rm = (w >> 16) & 0x1F
            let rd = w & 0x1F
            return "mov x\(rd), x\(rm)"
        }
        // MOV wd, wm
        if (w & 0x7FE0FFE0) == 0x2A0003E0 {
            let rm = (w >> 16) & 0x1F
            let rd = w & 0x1F
            return "mov w\(rd), w\(rm)"
        }

        // STR (immediate) 64位 unsigned offset
        if (w & 0xFFC00000) == 0xF9000000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rt = w & 0x1F
            return "str x\(rt), [x\(rn), #0x\(String(imm12 * 8, radix: 16))]"
        }
        // LDR (immediate) 64位 unsigned offset
        if (w & 0xFFC00000) == 0xF9400000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rt = w & 0x1F
            return "ldr x\(rt), [x\(rn), #0x\(String(imm12 * 8, radix: 16))]"
        }
        // STR (immediate) 32位 unsigned offset
        if (w & 0xFFC00000) == 0xB9000000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rt = w & 0x1F
            return "str w\(rt), [x\(rn), #0x\(String(imm12 * 4, radix: 16))]"
        }
        // LDR (immediate) 32位 unsigned offset
        if (w & 0xFFC00000) == 0xB9400000 {
            let imm12 = (w >> 10) & 0xFFF
            let rn = (w >> 5) & 0x1F
            let rt = w & 0x1F
            return "ldr w\(rt), [x\(rn), #0x\(String(imm12 * 4, radix: 16))]"
        }

        return String(format: ".word 0x%08X", w)
    }

    private func signExtend(_ value: UInt32, bits: Int) -> Int64 {
        let shift = UInt32(64 - bits)
        let shifted = (value << shift) >> shift
        return Int64(bitPattern: UInt64(shifted))
    }

    private func condName(_ c: Int) -> String {
        switch c {
        case 0: return "eq"
        case 1: return "ne"
        case 2: return "hs"
        case 3: return "lo"
        case 4: return "mi"
        case 5: return "pl"
        case 6: return "vs"
        case 7: return "vc"
        case 8: return "hi"
        case 9: return "ls"
        case 10: return "ge"
        case 11: return "lt"
        case 12: return "gt"
        case 13: return "le"
        case 14: return "al"
        default: return "??"
        }
    }
}
