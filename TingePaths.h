#pragma once
#import <Foundation/Foundation.h>

#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
#import <roothide.h>
static inline NSString *TingePath(NSString *path) {
    return jbroot(path);
}
#else
#import <rootless.h>
static inline NSString *TingePath(NSString *path) {
    return ROOT_PATH_NS_VAR(path);
}
#endif
