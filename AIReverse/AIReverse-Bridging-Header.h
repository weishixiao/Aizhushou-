//
//  AIReverse-Bridging-Header.h
//  AIReverse
//
//  iOS SDK 26 不包含 mach_vm.h / libproc.h / sys/proc_info.h。
//  所有 Mach VM 和 libproc 函数通过 extern 手动声明。
//

#ifndef AIReverse_Bridging_Header_h
#define AIReverse_Bridging_Header_h

#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach-o/dyld.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <dlfcn.h>

// MARK: - Mach VM 类型
typedef unsigned long long mach_vm_address_t;
typedef unsigned long long mach_vm_offset_t;
typedef unsigned long long mach_vm_size_t;

// MARK: - VM 保护常量
#ifndef VM_PROT_READ
#define VM_PROT_READ 0x01
#endif

#ifndef VM_PROT_WRITE
#define VM_PROT_WRITE 0x02
#endif

#ifndef VM_PROT_EXECUTE
#define VM_PROT_EXECUTE 0x04
#endif

// MARK: - VM 继承常量
#ifndef VM_INHERIT_SHARE
#define VM_INHERIT_SHARE 0x01
#endif

// MARK: - 内存对象常量
#ifndef MEMORY_OBJECT_COPY_NONE
#define MEMORY_OBJECT_COPY_NONE 0
#endif

#ifndef MEMORY_OBJECT_COPY_SHARE
#define MEMORY_OBJECT_COPY_SHARE 1
#endif

#ifndef MEMORY_OBJECT_COPY_PRIVATE
#define MEMORY_OBJECT_COPY_PRIVATE 2
#endif

// MARK: - 常量回退
#ifndef PAGE_SIZE
#define PAGE_SIZE 16384
#endif

#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 512
#endif

// MARK: - VM 区域信息结构
struct vm_region_recurse_info_64 {
    uint32_t protection;
    uint32_t max_protection;
    uint32_t inheritance;
    uint32_t sharing;
    uint32_t is_submap;
    uint32_t is_image;
    uint32_t behavior;
    uint32_t user_wired_count;
};
typedef struct vm_region_recurse_info_64 vm_region_recurse_info_64_t;

// MARK: - Mach VM 函数
extern kern_return_t mach_vm_read(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    vm_offset_t *dataout,
    mach_vm_size_t *size_out
);

extern kern_return_t mach_vm_read_overwrite(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t dataout,
    mach_vm_size_t *outsize
);

extern kern_return_t mach_vm_write(
    vm_map_t target_task,
    mach_vm_address_t address,
    vm_offset_t data,
    mach_msg_type_number_t data_count
);

extern kern_return_t mach_vm_deallocate(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size
);

extern kern_return_t mach_vm_region(
    vm_map_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *info_count,
    mach_port_t *object_name
);

extern kern_return_t mach_vm_region_recurse(
    vm_map_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *info_count,
    mach_port_t *object_name
);

// MARK: - libproc 函数
extern int proc_listpids(int type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#endif /* AIReverse_Bridging_Header_h */
