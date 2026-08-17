//
//  ios_mem_toolkit.h
//  iOS Memory Toolkit — 扫描、定位、修改、缩小搜索四合一
//
//  适用平台：iOS / macOS (arm64)
//  依赖：Mach VM API（libSystem 自带，无需额外链接）
//
//  使用方式：
//    1. mt_init(&ctx, mach_task_self())        // 同进程
//       mt_init(&ctx, task_port)                // 跨进程（需越狱）
//    2. mt_scan_u32_all(&ctx, 1250, &results)   // 首次搜索，收集所有命中
//    3. mt_narrow_search(&ctx, &results, 1180)  // 缩小搜索，在结果集中再筛
//    4. mt_read / mt_write / mt_patch_*         // 读写或 patch
//

#ifndef IOS_MEM_TOOLKIT_H
#define IOS_MEM_TOOLKIT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================
// 数据结构
// ============================================================

typedef struct {
    vm_map_t            task;
    mach_vm_address_t   shared_cache_lo;
    mach_vm_address_t   shared_cache_hi;
    size_t              page_size;
} mt_ctx_t;

// 搜索结果集（动态数组）
typedef struct {
    mach_vm_address_t  *addrs;    // 命中地址数组
    size_t              count;    // 命中数量
    size_t              capacity; // 数组容量
} mt_result_set_t;

// ============================================================
// 初始化 / 清理
// ============================================================

bool mt_init(mt_ctx_t *ctx, vm_map_t task);

// 初始化一个空的结果集
void mt_result_init(mt_result_set_t *rs);
// 释放结果集内存
void mt_result_free(mt_result_set_t *rs);
// 向结果集添加一个地址
void mt_result_add(mt_result_set_t *rs, mach_vm_address_t addr);

// ============================================================
// 阶段一：内存扫描
// ============================================================

// 枚举所有可读写、非 shared cache 的区域
typedef void (*mt_region_cb)(mach_vm_address_t addr, mach_vm_size_t size, void *user_data);
void mt_enumerate_rw_regions(mt_ctx_t *ctx, mt_region_cb cb, void *user_data);

// ============================================================
// 阶段二：特征定位
// ============================================================

// --- 单结果（只返回第一个命中） ---

bool mt_scan_aob(mt_ctx_t *ctx,
                 const uint8_t *pattern, const uint8_t *mask, size_t pat_len,
                 mach_vm_address_t *out_addr);

bool mt_scan_u8 (mt_ctx_t *ctx, uint8_t  value, mach_vm_address_t *out_addr);
bool mt_scan_u16(mt_ctx_t *ctx, uint16_t value, mach_vm_address_t *out_addr);
bool mt_scan_u32(mt_ctx_t *ctx, uint32_t value, mach_vm_address_t *out_addr);
bool mt_scan_u64(mt_ctx_t *ctx, uint64_t value, mach_vm_address_t *out_addr);
bool mt_scan_f32(mt_ctx_t *ctx, float    value, mach_vm_address_t *out_addr);

// --- 多结果（收集所有命中到结果集） ---

// AoB 模式匹配，收集所有命中地址到 rs
bool mt_scan_aob_all(mt_ctx_t *ctx,
                     const uint8_t *pattern, const uint8_t *mask, size_t pat_len,
                     mt_result_set_t *rs);

// 各宽度精确值搜索，收集所有命中
bool mt_scan_u8_all (mt_ctx_t *ctx, uint8_t  value, mt_result_set_t *rs);
bool mt_scan_u16_all(mt_ctx_t *ctx, uint16_t value, mt_result_set_t *rs);
bool mt_scan_u32_all(mt_ctx_t *ctx, uint32_t value, mt_result_set_t *rs);
bool mt_scan_u64_all(mt_ctx_t *ctx, uint64_t value, mt_result_set_t *rs);
bool mt_scan_f32_all(mt_ctx_t *ctx, float    value, mt_result_set_t *rs);

// --- 缩小搜索（在已有结果集中做二次筛选） ---
// 对 rs 中每个地址读当前值，只保留 == new_value 的，其余从 rs 移除
// 返回筛选后的命中数量（rs->count 会被更新）
size_t mt_narrow_search_u32(mt_ctx_t *ctx, mt_result_set_t *rs, uint32_t new_value);
size_t mt_narrow_search_f32(mt_ctx_t *ctx, mt_result_set_t *rs, float new_value);

// 在指定地址范围内做 AoB（缩小搜索范围）
bool mt_scan_aob_in_range(mt_ctx_t *ctx,
                          mach_vm_address_t range_start, mach_vm_size_t range_size,
                          const uint8_t *pattern, const uint8_t *mask, size_t pat_len,
                          mach_vm_address_t *out_addr);

// ============================================================
// 指针链追踪
// ============================================================

// 从 base 地址开始，依次读指针 + offset，得到最终地址
// offsets: 偏移量数组，offset_count: 偏移数量
// 例：base -> [+0x10] -> [+0x24] -> [+0x08] = target
//     mt_follow_pointer(&ctx, base, (uint64_t[]){0x10, 0x24, 0x08}, 3, &target)
bool mt_follow_pointer(mt_ctx_t *ctx, mach_vm_address_t base,
                       const uint64_t *offsets, size_t offset_count,
                       mach_vm_address_t *out_addr);

// ============================================================
// 阶段三：内存读写
// ============================================================

bool mt_read (mt_ctx_t *ctx, mach_vm_address_t addr, void *buf, size_t len);
bool mt_write(mt_ctx_t *ctx, mach_vm_address_t addr, const void *data, size_t len);

bool mt_read_u8 (mt_ctx_t *ctx, mach_vm_address_t addr, uint8_t  *out);
bool mt_read_u16(mt_ctx_t *ctx, mach_vm_address_t addr, uint16_t *out);
bool mt_read_u32(mt_ctx_t *ctx, mach_vm_address_t addr, uint32_t *out);
bool mt_read_u64(mt_ctx_t *ctx, mach_vm_address_t addr, uint64_t *out);
bool mt_read_f32(mt_ctx_t *ctx, mach_vm_address_t addr, float    *out);

bool mt_write_u8 (mt_ctx_t *ctx, mach_vm_address_t addr, uint8_t  value);
bool mt_write_u16(mt_ctx_t *ctx, mach_vm_address_t addr, uint16_t value);
bool mt_write_u32(mt_ctx_t *ctx, mach_vm_address_t addr, uint32_t value);
bool mt_write_u64(mt_ctx_t *ctx, mach_vm_address_t addr, uint64_t value);
bool mt_write_f32(mt_ctx_t *ctx, mach_vm_address_t addr, float    value);

// ============================================================
// 代码段 Patch
// ============================================================

bool mt_make_writable(mt_ctx_t *ctx, mach_vm_address_t addr, size_t len);
bool mt_restore_executable(mt_ctx_t *ctx, mach_vm_address_t addr, size_t len);

// 通用 patch：写入任意 ARM64 指令序列（自动处理页对齐和权限）
bool mt_patch_code(mt_ctx_t *ctx, mach_vm_address_t addr,
                   const uint32_t *instructions, size_t count);

// 预置模式
bool mt_patch_return_zero(mt_ctx_t *ctx, mach_vm_address_t func_addr); // MOV X0,#0; RET
bool mt_patch_return_one (mt_ctx_t *ctx, mach_vm_address_t func_addr); // MOV X0,#1; RET
bool mt_patch_nop        (mt_ctx_t *ctx, mach_vm_address_t insn_addr);  // NOP
bool mt_patch_cbz_to_b   (mt_ctx_t *ctx, mach_vm_address_t insn_addr);  // CBZ → B

// 保存原始指令（patch 前调用），之后可用 mt_patch_restore 恢复
bool mt_patch_save  (mt_ctx_t *ctx, mach_vm_address_t addr, size_t insn_count,
                     uint32_t *out_saved);
bool mt_patch_restore(mt_ctx_t *ctx, mach_vm_address_t addr,
                      const uint32_t *saved, size_t insn_count);

#ifdef __cplusplus
}
#endif

#endif // IOS_MEM_TOOLKIT_H
