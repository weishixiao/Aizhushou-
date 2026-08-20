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
#include <sys/proc_info.h>
#include <dlfcn.h>

#ifndef PAGE_SIZE
#define PAGE_SIZE 16384
#endif

// libproc declarations (not always in public iOS SDK)
#ifndef PROC_LISTALLPIDS_DECLARED
#define PROC_LISTALLPIDS_DECLARED
#include <libproc.h>
#endif

// Fallback declarations if libproc.h is not available
#ifndef _LIBPROC_H_
#include <sys/sysctl.h>
#include <sys/proc_info.h>

#if !defined(MAXPATHLEN)
#define MAXPATHLEN 1024
#endif

#if !defined(PROC_PIDPATHINFO_MAXSIZE)
#define PROC_PIDPATHINFO_MAXSIZE 512
#endif

#if !defined(PROC_PIDPATHINFO_SIZE)
#define PROC_PIDPATHINFO_SIZE 512
#endif

#endif /* !_LIBPROC_H_ */

#endif /* AIReverse_Bridging_Header_h */