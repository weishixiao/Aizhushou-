//
//  AIReverse-Bridging-Header.h
//  为 Swift 暴露 C 语言 API（ios_mem_toolkit）
//

#ifndef AIReverse_Bridging_Header_h
#define AIReverse_Bridging_Header_h

#import "Services/ios_mem_toolkit.h"

// 获取当前进程的 task port（iOS SDK 的 Swift overlay 不暴露 mach_task_self() 宏，
// 故在 C 侧包装，Swift 中调用 mt_current_task()）
static inline mach_port_t mt_current_task(void) {
    return mach_task_self();
}

#endif /* AIReverse_Bridging_Header_h */