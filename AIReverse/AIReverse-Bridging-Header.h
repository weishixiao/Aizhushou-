//
//  AIReverse-Bridging-Header.h
//  AIReverse
//

#ifndef AIReverse_Bridging_Header_h
#define AIReverse_Bridging_Header_h

#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach-o/dyld.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <dlfcn.h>

#ifndef PAGE_SIZE
#define PAGE_SIZE 16384
#endif

// Mach VM helpers (may be needed by future memory tools)
extern kern_return_t mach_vm_read_overwrite(
    vm_map_t target_task,
    unsigned long long address,
    unsigned long long size,
    unsigned long long dataout,
    unsigned long long *outsize
);

#endif /* AIReverse_Bridging_Header_h */
