//
//  ios_mem_toolkit.c
//  iOS Memory Toolkit 实现
//

#include "ios_mem_toolkit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include <mach/vm_page_size.h>

// ============================================================
// 平台兼容层：模拟器 SDK 没有 mach_vm_* 函数系列，映射到 vm_* 系列
// 注意：只替换函数名，不替换类型名。mach_vm_address_t / mach_vm_size_t
// 在模拟器 SDK 中有定义，类型本身可用。
// ============================================================

#if TARGET_OS_SIMULATOR || (defined(__x86_64__) && !defined(__arm64__))

    // 模拟器：用 vm_* 系列函数替代 mach_vm_*
    // vm_region_64 签名与 mach_vm_region 一致
    #define mach_vm_region         vm_region_64
    #define mach_vm_read_overwrite vm_read_overwrite
    #define mach_vm_write          vm_write
    #define mach_vm_protect        vm_protect

#endif

// ============================================================
// 内部常量
// ============================================================

#define MT_CHUNK_SIZE   (1024 * 1024)  // 1MB 分块读取
#define MT_RESULT_INIT   10000  // 结果集初始容量

// ============================================================
// 初始化
// ============================================================

bool mt_init(mt_ctx_t *ctx, vm_map_t task) {
    if (!ctx) return false;
    ctx->task = task;
    ctx->page_size = vm_page_size;
    ctx->shared_cache_lo = 0x180000000ULL;
    ctx->shared_cache_hi = 0x200000000ULL;
    return true;
}

static inline bool is_in_shared_cache(const mt_ctx_t *ctx, mach_vm_address_t addr) {
    return addr >= ctx->shared_cache_lo && addr < ctx->shared_cache_hi;
}

static inline bool is_scannable_region(const vm_region_basic_info_data_64_t *info,
                                        mach_vm_address_t addr, const mt_ctx_t *ctx) {
    int prot = info->protection;
    if (!((prot & VM_PROT_READ) && (prot & VM_PROT_WRITE)))
        return false;
    if (is_in_shared_cache(ctx, addr))
        return false;
    return true;
}

// ============================================================
// 结果集管理
// ============================================================

void mt_result_init(mt_result_set_t *rs) {
    if (!rs) return;
    rs->addrs = (mach_vm_address_t *)malloc(sizeof(mach_vm_address_t) * MT_RESULT_INIT);
    rs->count = 0;
    rs->capacity = MT_RESULT_INIT;
}

void mt_result_free(mt_result_set_t *rs) {
    if (!rs) return;
    free(rs->addrs);
    rs->addrs = NULL;
    rs->count = 0;
    rs->capacity = 0;
}

void mt_result_add(mt_result_set_t *rs, mach_vm_address_t addr) {
    if (!rs) return;
    if (rs->count >= rs->capacity) {
        size_t new_cap = rs->capacity * 2;
        mach_vm_address_t *p = (mach_vm_address_t *)realloc(rs->addrs,
            sizeof(mach_vm_address_t) * new_cap);
        if (!p) return;  // OOM，丢弃这条结果
        rs->addrs = p;
        rs->capacity = new_cap;
    }
    rs->addrs[rs->count++] = addr;
}

// ============================================================
// 阶段一：内存扫描
// ============================================================

void mt_enumerate_rw_regions(mt_ctx_t *ctx, mt_region_cb cb, void *user_data) {
    if (!ctx || !cb) return;

    mach_vm_address_t addr = 0;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    while (1) {
        kern_return_t kr = mach_vm_region(
            ctx->task, &addr, &size,
            VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&info, &info_count, &object_name);
        if (kr != KERN_SUCCESS) break;

        if (size == 0) {
            addr += ctx->page_size;
            continue;
        }

        if (is_scannable_region(&info, addr, ctx)) {
            cb(addr, size, user_data);
        }
        addr += size;
    }
}

// ============================================================
// 内部：在单个区域内做 AoB 搜索（修复块边界 bug）
// ============================================================

// 修复点 1：分块读取时，每块尾部保留 (pat_len - 1) 字节与下一块头部重叠，
//           防止跨块边界的 pattern 漏匹配。
// 修复点 2：缓冲区由调用方传入，不在循环内反复 malloc/free。

static void scan_region_aob_single(vm_map_t task,
                                    mach_vm_address_t region_start,
                                    mach_vm_size_t region_size,
                                    const uint8_t *pattern, const uint8_t *mask,
                                    size_t pat_len,
                                    mach_vm_address_t *out_addr) {
    uint8_t *buf = (uint8_t *)malloc(MT_CHUNK_SIZE);
    if (!buf) return;

    mach_vm_address_t cur = region_start;
    mach_vm_address_t region_end = region_start + region_size;

    while (cur < region_end) {
        mach_vm_size_t to_read = region_end - cur;
        if (to_read > MT_CHUNK_SIZE) to_read = MT_CHUNK_SIZE;

        mach_vm_size_t bytes_read = 0;
        kern_return_t kr = mach_vm_read_overwrite(task, cur, to_read,
                                                   (mach_vm_address_t)buf, &bytes_read);
        if (kr != KERN_SUCCESS || bytes_read < pat_len) {
            cur += to_read;
            continue;
        }

        // 在 buf 中搜索
        size_t search_limit = bytes_read - pat_len;
        for (size_t i = 0; i <= search_limit; i++) {
            bool match = true;
            for (size_t j = 0; j < pat_len; j++) {
                if (mask[j] && buf[i + j] != pattern[j]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                *out_addr = cur + i;
                free(buf);
                return;  // 命中第一个，返回
            }
        }

        // 关键修复：下一块从当前块尾部回退 (pat_len - 1) 字节开始读，
        // 保证跨块边界的 pattern 也能被匹配到
        if (cur + bytes_read < region_end) {
            cur += bytes_read - (pat_len - 1);
        } else {
            cur += bytes_read;
        }
    }
    free(buf);
}

// 多结果版本：收集所有命中到 rs
static void scan_region_aob_multi(vm_map_t task,
                                   mach_vm_address_t region_start,
                                   mach_vm_size_t region_size,
                                   const uint8_t *pattern, const uint8_t *mask,
                                   size_t pat_len,
                                   mt_result_set_t *rs) {
    uint8_t *buf = (uint8_t *)malloc(MT_CHUNK_SIZE);
    if (!buf) return;

    mach_vm_address_t cur = region_start;
    mach_vm_address_t region_end = region_start + region_size;

    while (cur < region_end) {
        mach_vm_size_t to_read = region_end - cur;
        if (to_read > MT_CHUNK_SIZE) to_read = MT_CHUNK_SIZE;

        mach_vm_size_t bytes_read = 0;
        kern_return_t kr = mach_vm_read_overwrite(task, cur, to_read,
                                                   (mach_vm_address_t)buf, &bytes_read);
        if (kr != KERN_SUCCESS || bytes_read < pat_len) {
            cur += to_read;
            continue;
        }

        size_t search_limit = bytes_read - pat_len;
        for (size_t i = 0; i <= search_limit; i++) {
            bool match = true;
            for (size_t j = 0; j < pat_len; j++) {
                if (mask[j] && buf[i + j] != pattern[j]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                mt_result_add(rs, cur + i);
            }
        }

        if (cur + bytes_read < region_end) {
            cur += bytes_read - (pat_len - 1);
        } else {
            cur += bytes_read;
        }
    }
    free(buf);
}

// ============================================================
// 阶段二：特征定位
// ============================================================

// --- 单结果 ---

bool mt_scan_aob(mt_ctx_t *ctx,
                 const uint8_t *pattern, const uint8_t *mask, size_t pat_len,
                 mach_vm_address_t *out_addr) {
    if (!ctx || !pattern || !mask || !out_addr || pat_len == 0) return false;

    mach_vm_address_t addr = 0;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    while (1) {
        kern_return_t kr = mach_vm_region(
            ctx->task, &addr, &size,
            VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&info, &info_count, &object_name);
        if (kr != KERN_SUCCESS) break;

        if (size == 0) { addr += ctx->page_size; continue; }

        if (is_scannable_region(&info, addr, ctx)) {
            mach_vm_address_t found = 0;
            scan_region_aob_single(ctx->task, addr, size,
                                   pattern, mask, pat_len, &found);
            if (found) { *out_addr = found; return true; }
        }
        addr += size;
    }
    return false;
}

bool mt_scan_u8(mt_ctx_t *ctx, uint8_t v, mach_vm_address_t *out) {
    return mt_scan_aob(ctx, &v, (const uint8_t[]){0xFF}, 1, out);
}
bool mt_scan_u16(mt_ctx_t *ctx, uint16_t v, mach_vm_address_t *out) {
    uint8_t m[2] = {0xFF, 0xFF};
    return mt_scan_aob(ctx, (const uint8_t *)&v, m, 2, out);
}
bool mt_scan_u32(mt_ctx_t *ctx, uint32_t v, mach_vm_address_t *out) {
    uint8_t m[4] = {0xFF,0xFF,0xFF,0xFF};
    return mt_scan_aob(ctx, (const uint8_t *)&v, m, 4, out);
}
bool mt_scan_u64(mt_ctx_t *ctx, uint64_t v, mach_vm_address_t *out) {
    uint8_t m[8] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
    return mt_scan_aob(ctx, (const uint8_t *)&v, m, 8, out);
}
bool mt_scan_f32(mt_ctx_t *ctx, float v, mach_vm_address_t *out) {
    uint8_t m[4] = {0xFF,0xFF,0xFF,0xFF};
    return mt_scan_aob(ctx, (const uint8_t *)&v, m, 4, out);
}

// --- 多结果 ---

bool mt_scan_aob_all(mt_ctx_t *ctx,
                     const uint8_t *pattern, const uint8_t *mask, size_t pat_len,
                     mt_result_set_t *rs) {
    if (!ctx || !pattern || !mask || !rs || pat_len == 0) return false;

    mach_vm_address_t addr = 0;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    while (1) {
        kern_return_t kr = mach_vm_region(
            ctx->task, &addr, &size,
            VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&info, &info_count, &object_name);
        if (kr != KERN_SUCCESS) break;

        if (size == 0) { addr += ctx->page_size; continue; }

        if (is_scannable_region(&info, addr, ctx)) {
            scan_region_aob_multi(ctx->task, addr, size,
                                  pattern, mask, pat_len, rs);
        }
        addr += size;
    }
    return rs->count > 0;
}

bool mt_scan_u8_all (mt_ctx_t *ctx, uint8_t  v, mt_result_set_t *rs) {
    return mt_scan_aob_all(ctx, &v, (const uint8_t[]){0xFF}, 1, rs);
}
bool mt_scan_u16_all(mt_ctx_t *ctx, uint16_t v, mt_result_set_t *rs) {
    uint8_t m[2] = {0xFF, 0xFF};
    return mt_scan_aob_all(ctx, (const uint8_t *)&v, m, 2, rs);
}
bool mt_scan_u32_all(mt_ctx_t *ctx, uint32_t v, mt_result_set_t *rs) {
    uint8_t m[4] = {0xFF,0xFF,0xFF,0xFF};
    return mt_scan_aob_all(ctx, (const uint8_t *)&v, m, 4, rs);
}
bool mt_scan_u64_all(mt_ctx_t *ctx, uint64_t v, mt_result_set_t *rs) {
    uint8_t m[8] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
    return mt_scan_aob_all(ctx, (const uint8_t *)&v, m, 8, rs);
}
bool mt_scan_f32_all(mt_ctx_t *ctx, float v, mt_result_set_t *rs) {
    uint8_t m[4] = {0xFF,0xFF,0xFF,0xFF};
    return mt_scan_aob_all(ctx, (const uint8_t *)&v, m, 4, rs);
}

// --- 缩小搜索 ---

size_t mt_narrow_search_u32(mt_ctx_t *ctx, mt_result_set_t *rs, uint32_t new_value) {
    if (!ctx || !rs || rs->count == 0) return 0;

    size_t write_idx = 0;
    for (size_t i = 0; i < rs->count; i++) {
        uint32_t current = 0;
        if (mt_read_u32(ctx, rs->addrs[i], &current) && current == new_value) {
            rs->addrs[write_idx++] = rs->addrs[i];  // 保留
        }
    }
    rs->count = write_idx;
    return write_idx;
}

size_t mt_narrow_search_f32(mt_ctx_t *ctx, mt_result_set_t *rs, float new_value) {
    if (!ctx || !rs || rs->count == 0) return 0;

    size_t write_idx = 0;
    for (size_t i = 0; i < rs->count; i++) {
        float current = 0;
        if (mt_read_f32(ctx, rs->addrs[i], &current) && current == new_value) {
            rs->addrs[write_idx++] = rs->addrs[i];
        }
    }
    rs->count = write_idx;
    return write_idx;
}

bool mt_scan_aob_in_range(mt_ctx_t *ctx,
                          mach_vm_address_t range_start, mach_vm_size_t range_size,
                          const uint8_t *pattern, const uint8_t *mask, size_t pat_len,
                          mach_vm_address_t *out_addr) {
    if (!ctx || !pattern || !mask || !out_addr || pat_len == 0) return false;
    scan_region_aob_single(ctx->task, range_start, range_size,
                           pattern, mask, pat_len, out_addr);
    return *out_addr != 0;
}

// ============================================================
// 指针链追踪
// ============================================================

bool mt_follow_pointer(mt_ctx_t *ctx, mach_vm_address_t base,
                       const uint64_t *offsets, size_t offset_count,
                       mach_vm_address_t *out_addr) {
    if (!ctx || !offsets || offset_count == 0 || !out_addr) return false;

    mach_vm_address_t current = base;
    for (size_t i = 0; i < offset_count; i++) {
        // 读 current + offsets[i] 处的 8 字节指针
        uint64_t next = 0;
        if (!mt_read_u64(ctx, current + offsets[i], &next)) return false;
        current = (mach_vm_address_t)next;
        if (current == 0) return false;  // 空指针
    }
    *out_addr = current;
    return true;
}

// ============================================================
// 阶段三：内存读写
// ============================================================

bool mt_read(mt_ctx_t *ctx, mach_vm_address_t addr, void *buf, size_t len) {
    if (!ctx || !buf || len == 0) return false;
    mach_vm_size_t bytes_read = 0;
    kern_return_t kr = mach_vm_read_overwrite(ctx->task, addr, len,
                                               (mach_vm_address_t)buf, &bytes_read);
    return kr == KERN_SUCCESS && bytes_read == len;
}

bool mt_write(mt_ctx_t *ctx, mach_vm_address_t addr, const void *data, size_t len) {
    if (!ctx || !data || len == 0) return false;
    kern_return_t kr = mach_vm_write(ctx->task, addr,
                                      (vm_offset_t)data, (mach_msg_type_number_t)len);
    return kr == KERN_SUCCESS;
}

bool mt_read_u8 (mt_ctx_t *ctx, mach_vm_address_t a, uint8_t  *o) { return mt_read(ctx,a,o,1); }
bool mt_read_u16(mt_ctx_t *ctx, mach_vm_address_t a, uint16_t *o) { return mt_read(ctx,a,o,2); }
bool mt_read_u32(mt_ctx_t *ctx, mach_vm_address_t a, uint32_t *o) { return mt_read(ctx,a,o,4); }
bool mt_read_u64(mt_ctx_t *ctx, mach_vm_address_t a, uint64_t *o) { return mt_read(ctx,a,o,8); }
bool mt_read_f32(mt_ctx_t *ctx, mach_vm_address_t a, float    *o) { return mt_read(ctx,a,o,4); }

bool mt_write_u8 (mt_ctx_t *ctx, mach_vm_address_t a, uint8_t  v) { return mt_write(ctx,a,&v,1); }
bool mt_write_u16(mt_ctx_t *ctx, mach_vm_address_t a, uint16_t v) { return mt_write(ctx,a,&v,2); }
bool mt_write_u32(mt_ctx_t *ctx, mach_vm_address_t a, uint32_t v) { return mt_write(ctx,a,&v,4); }
bool mt_write_u64(mt_ctx_t *ctx, mach_vm_address_t a, uint64_t v) { return mt_write(ctx,a,&v,8); }
bool mt_write_f32(mt_ctx_t *ctx, mach_vm_address_t a, float    v) { return mt_write(ctx,a,&v,4); }

// ============================================================
// 代码段 Patch
// ============================================================

static mach_vm_address_t page_align_down(mach_vm_address_t addr, size_t page_size) {
    return addr & ~((mach_vm_address_t)page_size - 1);
}

static size_t align_up(size_t v, size_t align) {
    return (v + align - 1) & ~(align - 1);
}

bool mt_make_writable(mt_ctx_t *ctx, mach_vm_address_t addr, size_t len) {
    if (!ctx) return false;
    mach_vm_address_t page = page_align_down(addr, ctx->page_size);
    size_t aligned_len = align_up(len + (addr - page), ctx->page_size);
    kern_return_t kr = mach_vm_protect(ctx->task, page, aligned_len, FALSE,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    return kr == KERN_SUCCESS;
}

bool mt_restore_executable(mt_ctx_t *ctx, mach_vm_address_t addr, size_t len) {
    if (!ctx) return false;
    mach_vm_address_t page = page_align_down(addr, ctx->page_size);
    size_t aligned_len = align_up(len + (addr - page), ctx->page_size);
    kern_return_t kr = mach_vm_protect(ctx->task, page, aligned_len, FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE);
    return kr == KERN_SUCCESS;
}

bool mt_patch_code(mt_ctx_t *ctx, mach_vm_address_t addr,
                   const uint32_t *instructions, size_t count) {
    if (!ctx || !instructions || count == 0) return false;
    size_t patch_len = count * 4;
    if (!mt_make_writable(ctx, addr, patch_len)) return false;
    bool ok = mt_write(ctx, addr, instructions, patch_len);
    mt_restore_executable(ctx, addr, patch_len);
    return ok;
}

bool mt_patch_save(mt_ctx_t *ctx, mach_vm_address_t addr, size_t insn_count,
                   uint32_t *out_saved) {
    if (!ctx || !out_saved || insn_count == 0) return false;
    return mt_read(ctx, addr, out_saved, insn_count * 4);
}

bool mt_patch_restore(mt_ctx_t *ctx, mach_vm_address_t addr,
                      const uint32_t *saved, size_t insn_count) {
    if (!ctx || !saved || insn_count == 0) return false;
    return mt_patch_code(ctx, addr, saved, insn_count);
}

// --- 预置模式 ---

bool mt_patch_return_zero(mt_ctx_t *ctx, mach_vm_address_t func_addr) {
    uint32_t insns[] = { 0xD2800000, 0xD65F03C0 };  // MOV X0,#0; RET
    return mt_patch_code(ctx, func_addr, insns, 2);
}

bool mt_patch_return_one(mt_ctx_t *ctx, mach_vm_address_t func_addr) {
    uint32_t insns[] = { 0xD2800020, 0xD65F03C0 };  // MOV X0,#1; RET
    return mt_patch_code(ctx, func_addr, insns, 2);
}

bool mt_patch_nop(mt_ctx_t *ctx, mach_vm_address_t insn_addr) {
    uint32_t nop = 0xD503201F;
    return mt_patch_code(ctx, insn_addr, &nop, 1);
}

bool mt_patch_cbz_to_b(mt_ctx_t *ctx, mach_vm_address_t insn_addr) {
    uint32_t cbz_insn = 0;
    if (!mt_read_u32(ctx, insn_addr, &cbz_insn)) return false;

    // 验证是 CBZ/CBNZ 64-bit（bits[31:25] = 0110100x / 0110101x）
    uint32_t op = (cbz_insn >> 24) & 0x7F;
    bool is_cbz_64  = (op & 0x7E) == 0x34;
    bool is_cbnz_64 = (op & 0x7E) == 0x35;
    if (!is_cbz_64 && !is_cbnz_64) return false;

    uint32_t imm26 = cbz_insn & 0x03FFFFFF;
    uint32_t b_insn = (0x05u << 26) | imm26;
    return mt_patch_code(ctx, insn_addr, &b_insn, 1);
}
