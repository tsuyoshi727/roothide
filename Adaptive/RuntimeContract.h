#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdlib.h>

static const char *TABUnqualifiedType(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) ++type;
    return type;
}

// Check every ABI argument, including self and _cmd. Never trust selector spelling.
static BOOL TABMethodMatches(Method method, char result, unsigned objectArguments) {
    if (!method || method_getNumberOfArguments(method) != objectArguments + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = *TABUnqualifiedType(type) == result;
    free(type);
    for (unsigned i = 0; valid && i < objectArguments + 2; ++i) {
        type = method_copyArgumentType(method, i);
        const char *t = TABUnqualifiedType(type);
        valid = (i == 1) ? (*t == ':') : (*t == '@' && t[1] != '?');
        free(type);
    }
    return valid;
}

static id TABObject(id object, const char *name) {
    if (!object) return nil;
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!TABMethodMatches(method, '@', 0)) return nil;
    return ((id (*)(id, SEL))method_getImplementation(method))(object, selector);
}
