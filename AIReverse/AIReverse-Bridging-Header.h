//
//  AIReverse-Bridging-Header.h
//  AIReverse
//
//  iOS SDK 不包含 libproc.h / sys/proc_info.h，
//  因此所有 libproc 函数通过 extern 手动声明。
//

#ifndef AIReverse_Bridging_Header_h
#define AIReverse_Bridging_Header_h

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include <mach/vm_statistics.h>
#include <mach/mach_error.h>
#include <mach-o/dyld.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <dlfcn.h>

// MARK: - Mach VM 扩展
extern kern_return_t vm_read_overwrite(
    mach_port_name_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    void *dataout,
    mach_vm_size_t *outsize
);

extern kern_return_t vm_read(
    mach_port_name_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    vm_offset_t *dataout,
    mach_vm_size_t *size_out
);

// MARK: - libproc 函数声明（iOS SDK 不含 libproc.h）
// 进程列表
extern int proc_listpids(
    int type,
    uint32_t typeinfo,
    void *buffer,
    int buffersize
);

// 进程 PID 信息
extern int proc_pidinfo(
    int pid,
    int flavor,
    uint64_t arg,
    void *buffer,
    int buffersize
);

// 进程路径
extern int proc_pidpath(
    int pid,
    void *buffer,
    uint32_t buffersize
);

// MARK: - 常量回退
#ifndef PAGE_SIZE
#define PAGE_SIZE 16384
#endif

#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 512
#endif

#ifndef PROC_PIDPATHINFO_SIZE
#define PROC_PIDPATHINFO_SIZE 512
#endif

#ifndef PROC_PIDTASKINFO_SIZE
#define PROC_PIDTASKINFO_SIZE 408
#endif

#ifndef PROC_PIDTHREADINFO_SIZE
#define PROC_PIDTHREADINFO_SIZE 408
#endif

#ifndef PROC_PIDLISTTASKS_SIZE
#define PROC_PIDLISTTASKS_SIZE 408
#endif

#ifndef PROC_PIDLISTFD_SIZE
#define PROC_PIDLISTFD_SIZE 408
#endif

#ifndef PROC_ALLPIDS
#define PROC_ALLPIDS 1
#endif

#endif /* AIReverse_Bridging_Header_h */
