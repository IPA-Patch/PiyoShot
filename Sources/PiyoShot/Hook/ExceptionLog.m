#import "Internal.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ===========================================================================
// Hook_ExceptionLog — pre-raise diagnostic swizzle for -[NSException raise].
//
// Motivation:
//
//   The pre-existing PSUncaughtExceptionHandler (Tweak.m) never fires on
//   the deterministic iteration-4841 crash because the exception is
//   intercepted by Firebase Crashlytics' `std::set_terminate` handler
//   (FIRCLSTerminateHandler) in the C++ terminate path, not the ObjC
//   NSUncaughtExceptionHandler path. By the time Firebase abort()s,
//   NSSetUncaughtExceptionHandler has never been called.
//
//   To capture the reason string of the raise that leads to the crash
//   we hook one level UP the raise chain: -[NSException raise]. Every
//   NSException — whether constructed via `+raise:format:` (the UIKit
//   "Could not load NIB in bundle ..." path uses this) or via
//   `exceptionWithName:reason:userInfo:` + explicit `-raise` — funnels
//   through `-raise` before it enters the C++ throw path. Log there and
//   we always get the raw name + formatted reason.
//
// Behaviour:
//
//   - Pure diagnostic: chain-forward to the original -raise so control
//     flow is unchanged. Callers still get their exception, upstream
//     @catch handlers still fire, Firebase Crashlytics still reports.
//   - Fires for every NSException raise app-wide — including exceptions
//     that are caught downstream. Runtime cost is a single formatted
//     log write per raise (no callstack symbolication).
//   - Thread-local re-entry guard so IPALog itself accidentally raising
//     can't recurse.
//
// Runtime-only ObjC. No binpatch slot. Safe on JB / jailed / CHINLAN.
// ===========================================================================

typedef void (*raise_imp_t)(id, SEL);
static raise_imp_t orig_nsexception_raise = NULL;

// TLS re-entry guard. `__thread` is available on all Apple platforms
// and doesn't need the ObjC runtime, so it works even if the runtime
// itself is in a wonky state mid-exception.
static __thread int g_in_raise_hook = 0;

__attribute__((noreturn)) static void hookRaise(id self, SEL _cmd) {
    if (!g_in_raise_hook) {
        g_in_raise_hook = 1;
        @try {
            NSException *e = (NSException *)self;
            NSString *name   = e.name   ?: @"(null)";
            NSString *reason = e.reason ?: @"(null)";
            IPALog([NSString stringWithFormat:@"[raise] name=%@ reason=%@",
                                              name, reason]);
            if (e.userInfo.count > 0) {
                IPALog([NSString stringWithFormat:@"[raise] userInfo=%@",
                                                  e.userInfo]);
            }
        } @catch (id ignored) {
            // If the diagnostic itself explodes, swallow it so we still
            // chain to orig below. Termination reporting must not be
            // hijacked by our logging.
        }
        g_in_raise_hook = 0;
    }
    // Chain to Apple's -raise. This never returns (it throws), which is
    // why our hook is marked noreturn.
    orig_nsexception_raise(self, _cmd);
    __builtin_unreachable();
}

void PSInstallExceptionLogHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method m = class_getInstanceMethod([NSException class],
                                           @selector(raise));
        if (!m) {
            IPALog(@"[exlog] -[NSException raise] not found — skipping");
            return;
        }
        orig_nsexception_raise = (raise_imp_t)method_getImplementation(m);
        method_setImplementation(m, (IMP)hookRaise);
        IPALog(@"[exlog] swizzled -[NSException raise]");
    });
}
