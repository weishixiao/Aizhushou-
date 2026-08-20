//
//  AIReverse-Bridging-Header.h
//  AIReverse
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

// libproc (可用 libproc.h 直接包含，无需 sys/proc_info.h)
#include <libproc.h>

// PAGE_SIZE 回退定义
#ifndef PAGE_SIZE
#define PAGE_SIZE 16384
#endif

// proc_pidinfo 相关常量回退
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 512
#endif

#ifndef PROC_PIDPATHINFO_SIZE
#define PROC_PIDPATHINFO_SIZE 512
#endif

// 自定义 proc_listpids 包装
// 标准 libproc.h 中的签名可能在 iOS 上不一致
extern int proc_listpids(int type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#endif /* AIReverse_Bridging_Header_h */
