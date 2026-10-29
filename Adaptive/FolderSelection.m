#import "FolderSelection.h"
#import "RuntimeContract.h"
#include <limits.h>
#include <errno.h>
#include <stdbool.h>

BOOL TABIsFolderIcon(id icon) {
    if (!icon) return NO;
    Class cls = objc_getClass("SBFolderIcon");
    if (cls && [icon isKindOfClass:cls]) return YES;
    // A leaf may expose its containing folder; that does not make it a folder.
    SEL selector = sel_registerName("isFolderIcon");
    Method m = class_getInstanceMethod(object_getClass(icon), selector);
    if (TABMethodMatches(m, 'B', 0))
        return ((bool (*)(id, SEL))method_getImplementation(m))(icon, selector);
    if (TABMethodMatches(m, 'c', 0))
        return ((signed char (*)(id, SEL))method_getImplementation(m))(icon, selector) != 0;
    return NO;
}

static long long TABPositiveIntegerObject(id value) {
    NSString *text = [value isKindOfClass:[NSNumber class]] ? [value stringValue] : value;
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || text.length > 19) return 0;
    const char *s = text.UTF8String;
    if (!s || !*s) return 0;
    for (const char *p = s; *p; ++p) if (*p < '0' || *p > '9') return 0;
    errno = 0;
    unsigned long long result = strtoull(s, NULL, 10);
    return errno || result > LLONG_MAX ? 0 : (long long)result;
}

long long TABBadgeCount(id icon) {
    if (!icon) return 0;
    SEL selector = sel_registerName("badgeValue");
    Method method = class_getInstanceMethod(object_getClass(icon), selector);
    // badgeValue is scalar in Test 3. Check the actual ABI before every call;
    // older/newer variants may return an object instead.
    if (method) {
        char *raw = method_copyReturnType(method);
        char type = *TABUnqualifiedType(raw);
        free(raw);
        if (TABMethodMatches(method, type, 0)) {
            IMP imp = method_getImplementation(method);
            long long value;
            switch (type) {
                case 'q': value = ((long long (*)(id, SEL))imp)(icon, selector); break;
                case 'i': value = ((int (*)(id, SEL))imp)(icon, selector); break;
                case 'l': value = ((long (*)(id, SEL))imp)(icon, selector); break;
                case 'Q': {
                    unsigned long long u = ((unsigned long long (*)(id, SEL))imp)(icon, selector);
                    return u <= LLONG_MAX ? (long long)u : 0;
                }
                case 'I': return ((unsigned int (*)(id, SEL))imp)(icon, selector);
                case '@': return TABPositiveIntegerObject(TABObject(icon, "badgeValue"));
                default: return TABPositiveIntegerObject(TABObject(icon, "badgeNumberOrString"));
            }
            return value > 0 ? value : 0;
        }
    }
    return TABPositiveIntegerObject(TABObject(icon, "badgeNumberOrString"));
}

static BOOL TABAllowsBadge(id icon) {
    id controller = TABObject((id)objc_getClass("SBIconController"), "sharedInstance");
    SEL selector = sel_registerName("allowsBadgingForIcon:");
    Method m = controller ? class_getInstanceMethod(object_getClass(controller), selector) : NULL;
    if (TABMethodMatches(m, 'B', 1))
        return ((bool (*)(id, SEL, id))method_getImplementation(m))(controller, selector, icon);
    if (TABMethodMatches(m, 'c', 1))
        return ((signed char (*)(id, SEL, id))method_getImplementation(m))(controller, selector, icon) != 0;
    return YES; // No verified optional policy API: use the positive model count.
}

id TABHighestBadgedMember(id folderIcon, long long *count) {
    if (count) *count = 0;
    id folder = TABObject(folderIcon, "folder");
    id members = TABObject(folder, "icons");
    if (!members) members = TABObject(folder, "leafIcons");
    if ([members isKindOfClass:[NSOrderedSet class]]) members = [members array];
    else if ([members isKindOfClass:[NSSet class]]) members = [members allObjects];
    if (![members isKindOfClass:[NSArray class]] || [members count] > 1024) return nil;
    id best = nil;
    long long maximum = 0;
    for (id icon in members) {
        if (!icon || !TABAllowsBadge(icon)) continue;
        long long value = TABBadgeCount(icon);
        if (value > maximum) { maximum = value; best = icon; }
    }
    if (count) *count = maximum;
    return best;
}
