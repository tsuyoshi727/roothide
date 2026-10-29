// Independent iOS 18 badge color helper. Does not load or require the old Tinge core.
#import <Foundation/Foundation.h>
#ifdef TAB_HOST_TEST
#import "tests/HostUIKit.h"
#else
#import <UIKit/UIKit.h>
#import <substrate.h>
#import "../TingePaths.h"
#endif
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <os/log.h>
#import "RuntimeContract.h"
#import "Palette.h"
#import "LayerSnapshot.h"
#import "FolderSelection.h"

static Class TABBadgeClass, TABIconClass;
static NSHashTable *TABBadges;
static BOOL TABEnabled;
static BOOL TABPreferencesKnown;
static unsigned TABLogCount;
static char TABStateKey;
static NSCache *TABLeafColors;
static BOOL TABFolderRefreshScheduled;
static BOOL TABFolderRefreshRunning;
static void TABApply(UIView *badge);

// Bounded evidence collection. No app identifiers, images or preference values
// other than Tinge's enable/background-mode switches are recorded.
static NSMutableDictionary *TABReport;
#ifndef TAB_HOST_TEST
static BOOL TABReportScheduled;
static unsigned TABReportWrites;
#endif
static void TABRecord(NSString *key, id value) {
    if (![NSThread isMainThread]) return;
    @try {
        if (!TABReport) TABReport = [NSMutableDictionary dictionary];
        if (TABReport[key]) return;
        if (TABReport.count >= 200) return;
        TABReport[key] = value ?: @"nil";
#ifndef TAB_HOST_TEST
        if (TABReportScheduled || TABReportWrites >= 24) return;
        TABReportScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            TABReportScheduled = NO;
            ++TABReportWrites;
            @try {
                NSString *path = TingePath(@"/var/mobile/Library/Logs/TingeAdaptiveBridge-report.plist");
                [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                         withIntermediateDirectories:YES attributes:nil error:NULL];
                if (![TABReport writeToFile:path atomically:YES])
                    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[TingeAdaptiveBridge] report write failed");
            } @catch (NSException *e) {
                os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[TingeAdaptiveBridge] report exception");
            }
        });
#endif
    } @catch (NSException *e) { /* Diagnostics must not interrupt SpringBoard. */ }
}
static NSString *TABEncoding(Class cls, const char *name) {
    Method m = cls ? class_getInstanceMethod(cls, sel_registerName(name)) : NULL;
    const char *encoding = m ? method_getTypeEncoding(m) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"MISSING";
}


@interface TABBadgeState : NSObject
@property(nonatomic, strong) id icon;
@property(nonatomic, weak) UIView *provider;
@property(nonatomic, strong) UIImage *sampledImage;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic, strong) UIImage *layerImage;
@property(nonatomic) CFTimeInterval lastLayerCapture;
@property(nonatomic) BOOL captureAttempted;
@property(nonatomic) unsigned retries;
@property(nonatomic) BOOL retryScheduled;
@property(nonatomic, strong) id selectedChild;
@property(nonatomic, weak) UIView *paintedView;
@property(nonatomic, strong) UIColor *previousBackground;
@property(nonatomic, strong) UIColor *previousTint;
@property(nonatomic, strong) UIColor *appliedColor;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL failed;
@end
@implementation TABBadgeState
@end

static void TABLog(NSString *message) {
    if (TABLogCount++ < 48) os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
                                          "[TingeAdaptiveBridge] %{public}@", message);
}

static TABBadgeState *TABState(UIView *badge) {
    return objc_getAssociatedObject(badge, &TABStateKey);
}

static void TABReloadPreferences(void) {
    // Match the preserved Test 3 preference file. TingePath uses native
    // jbroot on RootHide and libroot on standard rootless.
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                          TingePath(@"/var/mobile/Library/Preferences/com.p2kdev.tinge.plist")];
    TABRecord(@"preferences.nativeFileReadable", @([prefs isKindOfClass:[NSDictionary class]]));
    TABRecord(@"preferences.nativePath", TingePath(@"/var/mobile/Library/Preferences/com.p2kdev.tinge.plist"));
    TABRecord(@"preferences.rootfsFileExists", @([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences/com.p2kdev.tinge.plist"]));
    TABPreferencesKnown = [prefs isKindOfClass:[NSDictionary class]];
    TABEnabled = NO;
    if (!TABPreferencesKnown) {
        // Standalone builds have no preferences pane: default to adaptive color.
        TABPreferencesKnown = YES;
        TABEnabled = YES;
        TABLog(@"no previous Tinge settings; enabling standalone adaptive color");
        return;
    }
    id enabled = prefs[@"tweakEnabled"], mode = prefs[@"badgeColorType"];
    TABRecord(@"preferences.nativeModeKeyPresent", @(mode != nil));
    TABRecord(@"preferences.nativeEnableKeyPresent", @(enabled != nil));
    if ([mode isKindOfClass:[NSNumber class]] || [mode isKindOfClass:[NSString class]])
        TABRecord(@"preferences.nativeBackgroundMode", mode);
    if (enabled && ![enabled isKindOfClass:[NSNumber class]] &&
        ![enabled isKindOfClass:[NSString class]]) return;
    if (mode && ![mode isKindOfClass:[NSNumber class]] &&
        ![mode isKindOfClass:[NSString class]]) return;
    // Missing keys use the defaults recorded in the supplied preferences plist.
    TABEnabled = (!enabled || [enabled boolValue]) && (!mode || [mode intValue] == 0);
    TABRecord(@"preferences.firstEffectiveAdaptiveEnabled", @(TABEnabled));
    TABLog(TABEnabled ? @"adaptive background enabled" : @"static mode or Tinge disabled; pass-through");
}

static BOOL TABViewMatches(UIView *view, TABBadgeState *state) {
    return view && [view isKindOfClass:TABIconClass] && state.icon &&
           TABObject(view, "icon") == state.icon;
}

static UIView *TABIconView(UIView *badge, TABBadgeState *state) {
    // Prefer the actual owner. This also rejects reused views with a different icon.
    UIView *v = badge.superview;
    for (unsigned depth = 0; v && depth < 12; ++depth, v = v.superview) {
        if ([v isKindOfClass:TABIconClass]) return TABViewMatches(v, state) ? v : nil;
        if (v == badge.window) break;
    }
    UIView *provider = state.provider;
    return TABViewMatches(provider, state) ? provider : nil;
}

static BOOL TABCollectBadgeLayers(UIView *view, NSMutableSet<CALayer *> *excluded,
                                 unsigned depth, NSUInteger *remaining) {
    if (!view) return YES;
    if (!*remaining || depth > 8) return NO;
    --*remaining;
    if ([view isKindOfClass:TABBadgeClass]) { [excluded addObject:view.layer]; return YES; }
    for (UIView *child in view.subviews)
        if (!TABCollectBadgeLayers(child, excluded, depth + 1, remaining)) return NO;
    return YES;
}

static UIImage *TABRenderedImageView(UIView *imageView, UIView *badge, TABBadgeState *state) {
    TABRecord(@"image.imageViewClass", imageView ? NSStringFromClass([imageView class]) : @"nil");
    if (![imageView isKindOfClass:[UIView class]]) return nil;
    NSString *scope = [@"image.byClass." stringByAppendingString:NSStringFromClass([imageView class])];
    TABRecord([scope stringByAppendingString:@".seen"], @YES);
    for (NSString *name in @[@"displayedImage", @"contentsImage", @"image"]) {
        TABRecord([@"image.abi." stringByAppendingString:name], TABEncoding(object_getClass(imageView), name.UTF8String));
        id image = TABObject(imageView, name.UTF8String);
        TABRecord([scope stringByAppendingFormat:@".%@.firstResult", name], image ? NSStringFromClass([image class]) : @"nil");
        TABRecord([@"image.firstResultClass." stringByAppendingString:name], image ? NSStringFromClass([image class]) : @"nil");
        if ([image isKindOfClass:[UIImage class]] && [(UIImage *)image CGImage]) {
            TABRecord(@"image.usableSelector", name);
            TABRecord([scope stringByAppendingString:@".usableSelector"], name);
            TABRecord(@"image.usablePixelSize", @[@(CGImageGetWidth([(UIImage *)image CGImage])), @(CGImageGetHeight([(UIImage *)image CGImage]))]);
            static BOOL reported = NO;
            if (!reported) {
                reported = YES;
                TABLog([NSString stringWithFormat:@"rendered image via %@ on %@", name, NSStringFromClass([imageView class])]);
            }
            return image;
        }
    }
    // Image getters exist but can return nil on the tested device. Copy the
    // rendered icon layer tree while omitting all recognized badge subtrees.
    // Capture at most once/second per configured badge, never on every layout.
    CFTimeInterval now = CACurrentMediaTime();
    if (state.captureAttempted && now - state.lastLayerCapture < 1.0) return state.layerImage;
    state.captureAttempted = YES;
    state.lastLayerCapture = now;
    NSMutableSet<CALayer *> *excluded = [NSMutableSet set];
    if (badge.layer) [excluded addObject:badge.layer];
    NSUInteger remaining = 128;
    if (!TABCollectBadgeLayers(imageView, excluded, 0, &remaining)) {
        TABRecord([scope stringByAppendingString:@".viewBudgetExceeded"], @YES);
        return nil;
    }
    TABRecord([scope stringByAppendingString:@".layerFallbackAttempted"], @YES);
    TABRecord([scope stringByAppendingString:@".excludedBadgeLayers"], @(excluded.count));
    CALayer *sourceLayer = [(UIView *)imageView layer];
    TABRecord([scope stringByAppendingString:@".rootLayerHasContents"], @(sourceLayer.contents != nil));
    TABRecord([scope stringByAppendingString:@".rootLayerHidden"], @(sourceLayer.hidden));
    TABRecord([scope stringByAppendingString:@".rootLayerOpacity"], @(sourceLayer.opacity));
    NSMutableArray *children = [NSMutableArray array];
    for (CALayer *child in sourceLayer.sublayers) {
        if (children.count == 12) break;
        [children addObject:@{@"class": NSStringFromClass([child class]), @"hasContents": @(child.contents != nil)}];
    }
    TABRecord([scope stringByAppendingString:@".firstChildLayers"], children);
#ifndef TAB_HOST_TEST
    TABRecord([scope stringByAppendingString:@".rootBounds"], NSStringFromCGRect(sourceLayer.bounds));
#endif
    NSUInteger visited = 0, opaque = 0;
    CGImageRef snapshot = TABCopyLayerSnapshot(sourceLayer, excluded, &visited, &opaque);
    TABRecord([scope stringByAppendingString:@".firstLayerNodeCount"], @(visited));
    TABRecord([scope stringByAppendingString:@".firstOpaquePixelCount"], @(opaque));
    UIImage *captured = snapshot ? [UIImage imageWithCGImage:snapshot] : nil;
    if (snapshot) CGImageRelease(snapshot);
    state.layerImage = captured;
    if (captured) {
        TABRecord(@"image.layerFallbackProducedImage", @YES);
        TABRecord([scope stringByAppendingString:@".layerFallbackProducedImage"], @YES);
    }
    return captured;
}

// Keep the working Test 10 app acquisition path intact.
static UIImage *TABRenderedImage(UIView *iconView, UIView *badge, TABBadgeState *state) {
    TABRecord(@"image.iconViewClass", NSStringFromClass([iconView class]));
    TABRecord(@"image.getterABI", TABEncoding(object_getClass(iconView), "_iconImageView"));
    // iOS 18 varies the icon-image-view selector across icon subclasses.
    for (NSString *getter in @[@"_iconImageView", @"iconImageView", @"imageView"]) {
        id imageView = TABObject(iconView, getter.UTF8String);
        if ([imageView isKindOfClass:[UIView class]]) {
            UIImage *image = TABRenderedImageView(imageView, badge, state);
            if (image) return image;
        }
    }
    return nil;
}

static UIColor *TABSample(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg || !CGImageGetWidth(cg) || !CGImageGetHeight(cg)) return nil;
    uint8_t pixels[32 * 32 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) return nil;
    CGContextRef ctx = CGBitmapContextCreate(pixels, 32, 32, 8, 32 * 4, space,
                         kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 32, 32), cg);
    CGContextRelease(ctx);
    double rgb[3];
    return TABRepresentativeRGB(pixels, 32 * 32, rgb)
        ? [UIColor colorWithRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1] : nil;
}

static id TABColorKey(id icon) {
    id identifier = TABObject(icon, "nodeIdentifier");
    if ([identifier isKindOfClass:[NSString class]] && [identifier length])
        return [@"node:" stringByAppendingString:identifier];
    identifier = TABObject(icon, "uniqueIdentifier");
    if ([identifier isKindOfClass:[NSString class]] && [identifier length])
        return [@"unique:" stringByAppendingString:identifier];
    return icon;
}

static BOOL TABSameIcon(id left, id right) {
    return left && right && (left == right || [TABColorKey(left) isEqual:TABColorKey(right)]);
}

static void TABRefreshFolders(void) {
    if (TABFolderRefreshScheduled || TABFolderRefreshRunning) return;
    TABFolderRefreshScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        TABFolderRefreshScheduled = NO;
        TABFolderRefreshRunning = YES;
        @try {
            for (UIView *badge in TABBadges.allObjects) {
                @try {
                    TABBadgeState *state = TABState(badge);
                    if (state && TABIsFolderIcon(state.icon)) TABApply(badge);
                } @catch (NSException *e) { TABRecord(@"folder.refreshException", e.name); }
            }
        } @finally { TABFolderRefreshRunning = NO; }
    });
}

static void TABCacheLeafColor(id icon, UIColor *color) {
    if (!icon || !color || TABIsFolderIcon(icon)) return;
    id key = TABColorKey(icon);
    if ([[TABLeafColors objectForKey:key] isEqual:color]) return;
    [TABLeafColors setObject:color forKey:key];
    TABRefreshFolders();
}

static UIView *TABFindMemberView(UIView *view, id target, unsigned depth, NSUInteger *remaining) {
    if (!view || !*remaining || depth > 10 || [view isKindOfClass:TABBadgeClass]) return nil;
    --*remaining;
    if (TABSameIcon(TABObject(view, "icon"), target)) return view;
    for (UIView *child in view.subviews) {
        UIView *found = TABFindMemberView(child, target, depth + 1, remaining);
        if (found) return found;
    }
    return nil;
}

static UIColor *TABFolderColor(UIView *badge, UIView *folderView, TABBadgeState *state) {
    TABRecord(@"folder.selectionReached", @YES);
    TABRecord(@"folder.folderGetterABI", TABEncoding(object_getClass(state.icon), "folder"));
    id folderModel = TABObject(state.icon, "folder");
    TABRecord(@"folder.membersGetterABI", TABEncoding(object_getClass(folderModel), "icons"));
    id target = state.icon;
    // For nested folders, apply the same direct-member rule at each level.
    // Bounded recursion prevents cycles or malformed models from hanging SB.
    for (unsigned depth = 0; depth < 4 && TABIsFolderIcon(target); ++depth) {
        long long highest = 0;
        target = TABHighestBadgedMember(target, &highest);
        TABRecord(@"folder.hasPositiveWinner", @(target != nil));
        if (!target) return nil;
    }
    if (TABIsFolderIcon(target)) { TABRecord(@"folder.nestingLimitReached", @YES); return nil; }
    if (!TABSameIcon(state.selectedChild, target)) {
        state.selectedChild = target;
        state.sampledImage = nil;
        state.layerImage = nil;
        state.color = nil;
        state.captureAttempted = NO;
        state.retries = 0;
    }
    // First use the exact color produced by the working app-badge path. This
    // survives closing a folder without sampling its composite preview.
    UIColor *cached = [TABLeafColors objectForKey:TABColorKey(target)];
    if (cached) { TABRecord(@"folder.usedSelectedAppColorCache", @YES); return cached; }
    UIView *source = nil;
    for (UIView *knownBadge in TABBadges.allObjects) {
        TABBadgeState *known = TABState(knownBadge);
        if (known && !known.failed && TABSameIcon(known.icon, target)) {
            source = TABIconView(knownBadge, known);
            if (source) break;
        }
    }
    // Closed-folder previews sometimes expose individual member image views.
    // Only a verified icon identity is accepted; never infer membership by order.
    if (!source) {
        NSUInteger remaining = 256;
        source = TABFindMemberView(folderView, target, 0, &remaining);
    }
    if (!source) {
        TABRecord(@"folder.selectedAppNotRenderedYet", @YES);
        return nil;
    }
    id childImageView = TABObject(source, "_iconImageView");
    UIView *imageView = [childImageView isKindOfClass:[UIView class]] ? childImageView : source;
    UIImage *image = TABRenderedImageView(imageView, badge, state);
    UIColor *color = image ? TABSample(image) : nil;
    if (color) {
        TABRecord(@"folder.sampledSelectedMemberImage", @YES);
        TABCacheLeafColor(target, color);
    }
    return color;
}

static UIView *TABBackground(UIView *badge) {
    Ivar ivar = class_getInstanceVariable(object_getClass(badge), "_backgroundView");
    TABRecord(@"background.ivarPresent", @(ivar != NULL));
    if (!ivar || *TABUnqualifiedType(ivar_getTypeEncoding(ivar)) != '@') {
        // Do not guess among arbitrary badge subviews. Only use an explicitly
        // exposed background UIView when it really belongs to this badge.
        id candidate = TABObject(badge, "backgroundView");
        if ([candidate isKindOfClass:[UIView class]] && [candidate isDescendantOfView:badge])
            return candidate;
        return nil;
    }
    id value = object_getIvar(badge, ivar);
    TABRecord(@"background.class", value ? NSStringFromClass([value class]) : @"nil");
    TABRecord(@"background.isOwnedView", @([value isKindOfClass:[UIView class]] && [value isDescendantOfView:badge]));
    // Restrict the write to the badge's own existing background view.
    return [value isKindOfClass:[UIView class]] && [value isDescendantOfView:badge] ? value : nil;
}

static void TABApply(UIView *badge);

static void TABRestoreOwnedPaint(UIView *badge, TABBadgeState *state) {
    UIView *painted = state.paintedView;
    if (state.appliedColor && painted && [painted isDescendantOfView:badge]) {
        if ([painted.backgroundColor isEqual:state.appliedColor]) painted.backgroundColor = state.previousBackground;
        if ([painted.tintColor isEqual:state.appliedColor]) painted.tintColor = state.previousTint;
    }
    state.appliedColor = nil;
    state.paintedView = nil;
}

static void TABScheduleImageRetry(UIView *badge, TABBadgeState *state) {
#ifndef TAB_HOST_TEST
    if (state.retryScheduled || state.retries >= 2) return;
    state.retryScheduled = YES;
    ++state.retries;
    NSTimeInterval delay = state.retries == 1 ? 0.3 : 1.0;
    __weak UIView *weakBadge = badge;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *current = weakBadge;
        state.retryScheduled = NO;
        if (current && TABState(current) == state) TABApply(current);
    });
#endif
}

static void TABApply(UIView *badge) {
    if (![NSThread isMainThread]) return;
    TABBadgeState *state = TABState(badge);
    if (!state) { TABRecord(@"apply.seenWithoutConfigureState", @YES); return; }
    if (state.busy || state.failed) return;
    TABRecord(@"apply.reachedWithState", @YES);
    state.busy = YES;
    @try {
        if (!TABPreferencesKnown || !TABEnabled) {
            TABRecord(@"apply.skippedByPreferenceGate", @YES);
            // Restore only values still owned by this helper, never overwrite a
            // newer static fill that Test 3 or another tweak already supplied.
            TABRestoreOwnedPaint(badge, state);
            return;
        }
        UIView *iconView = TABIconView(badge, state);
        if (!iconView) {
            TABRecord(@"owner.lookupFailed", @YES);
            NSMutableArray *chain = [NSMutableArray array];
            UIView *v = badge.superview;
            for (unsigned depth = 0; v && depth < 12; ++depth, v = v.superview)
                [chain addObject:NSStringFromClass([v class])];
            TABRecord(@"owner.firstMissingChain", chain);
            TABRecord(@"owner.providerClass", state.provider ? NSStringFromClass([state.provider class]) : @"nil");
            TABRecord(@"owner.iconPresent", @(state.icon != nil));
            TABRecord(@"owner.providerIconMatches", @(TABObject(state.provider, "icon") == state.icon && state.icon != nil));
            return;
        }
        TABRecord(@"owner.resolved", @YES);
        if (TABIsFolderIcon(state.icon)) {
            state.color = TABFolderColor(badge, iconView, state);
            if (!state.color) {
                TABRestoreOwnedPaint(badge, state);
                TABScheduleImageRetry(badge, state);
                return;
            }
        } else {
            UIImage *image = TABRenderedImage(iconView, badge, state);
            if (!image) {
                TABScheduleImageRetry(badge, state);
                static BOOL reported = NO;
                if (!reported) { reported = YES; TABLog(@"no rendered UIImage yet; preserving system badge background"); }
                return;
            }
            if (state.sampledImage.CGImage != image.CGImage) {
                state.color = TABSample(image);
                TABRecord(@"sample.producedColor", @(state.color != nil));
                if (state.color) TABRecord(@"sample.everProducedColor", @YES);
                state.sampledImage = image; // Retains pixels; pointer cannot be recycled.
            }
            TABCacheLeafColor(state.icon, state.color);
        }
        UIColor *color = state.color;
        if (color) TABRecord(@"sample.firstColorDescription", [color description]);
        UIView *background = color ? TABBackground(badge) : nil;
        if (!background) {
            static BOOL reported = NO;
            if (!reported) { reported = YES; TABLog(@"no usable pixels or owned background view; pass-through"); }
            return;
        }
        // Write only the background and tint of the verified badge-owned view.
        // Numbers, text views, border geometry and icon imagery are untouched.
        if (![background.backgroundColor isEqual:color] || ![background.tintColor isEqual:color]) {
            if (background != state.paintedView || ![background.backgroundColor isEqual:state.appliedColor])
                state.previousBackground = background.backgroundColor;
            if (background != state.paintedView || ![background.tintColor isEqual:state.appliedColor])
                state.previousTint = background.tintColor;
            state.paintedView = background;
            state.appliedColor = color;
            [CATransaction begin];
            @try {
                [CATransaction setDisableActions:YES];
                background.backgroundColor = color;
                background.tintColor = color;
            } @finally { [CATransaction commit]; }
        }
        TABRecord(@"apply.backgroundWriteReached", @YES);
        TABRecord(@"apply.backgroundReadbackMatches", @([background.backgroundColor isEqual:color] && [background.tintColor isEqual:color]));
#ifndef TAB_HOST_TEST
        TABRecord(@"background.firstHidden", @(background.hidden));
        TABRecord(@"background.firstAlpha", @(background.alpha));
        TABRecord(@"background.firstLayerOpacity", @(background.layer.opacity));
        TABRecord(@"background.firstBounds", NSStringFromCGRect(background.bounds));
#endif
        static BOOL reported = NO;
        if (!reported) { reported = YES; TABLog(@"applied rendered-icon color to existing badge background"); }
    } @catch (NSException *exception) {
        // This is for Objective-C exceptions, not a promise to recover memory faults.
        state.failed = YES;
        TABRecord(@"apply.exceptionName", exception.name);
        TABLog([NSString stringWithFormat:@"disabled this badge after guarded exception: %@", exception.name]);
    } @finally { state.busy = NO; }
}

static void TABConfigureState(UIView *badge, id icon, id provider) {
    if (![NSThread isMainThread]) return;
    TABBadgeState *state = [TABBadgeState new];
    TABRecord(@"configure.reached", @YES);
    TABRecord(@"configure.badgeClass", NSStringFromClass([badge class]));
    state.icon = icon;
    if ([provider isKindOfClass:[UIView class]]) state.provider = provider;
    objc_setAssociatedObject(badge, &TABStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TABBadges addObject:badge];
}

static void (*TABOrigConfigure)(id, SEL, id, id);
static void TABConfigure(id self, SEL cmd, id icon, id provider) {
    @try { TABConfigureState(self, icon, provider); }
    @catch (NSException *e) { TABLog(@"could not associate badge state"); }
    TABOrigConfigure(self, cmd, icon, provider); // exactly once; no catch/retry of original
    TABApply(self);
}

static void (*TABOrigAnimated)(id, SEL, id, id, id);
static void TABAnimated(id self, SEL cmd, id icon, id provider, id animator) {
    @try { TABConfigureState(self, icon, provider); }
    @catch (NSException *e) { TABLog(@"could not associate animated badge state"); }
    TABOrigAnimated(self, cmd, icon, provider, animator);
    TABApply(self);
}

static void (*TABOrigLayout)(id, SEL);
// On iOS 18 the appearance/update selectors can differ. A successful
// layoutSubviews hook plus owner lookup provides a passive, ABI-checked fallback.
static void TABSeedFromOwner(UIView *badge) {
    if (TABState(badge) || ![NSThread isMainThread]) return;
    UIView *view = badge.superview;
    for (unsigned depth = 0; view && depth < 12; ++depth, view = view.superview) {
        if ([view isKindOfClass:TABIconClass]) {
            id icon = TABObject(view, "icon");
            if (icon) TABConfigureState(badge, icon, view);
            break;
        }
        if (view == badge.window) break;
    }
}
static void TABLayout(id self, SEL cmd) {
    TABOrigLayout(self, cmd);
    TABSeedFromOwner(self);
    TABApply(self);
}

static void (*TABOrigReuse)(id, SEL);
static void TABReuse(id self, SEL cmd) {
    if ([NSThread isMainThread]) {
        objc_setAssociatedObject(self, &TABStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [TABBadges removeObject:self];
    }
    TABOrigReuse(self, cmd);
}

static void (*TABOrigAppearance)(id, SEL);
static void TABAppearance(id self, SEL cmd) {
    TABOrigAppearance(self, cmd);
    if ([NSThread isMainThread]) {
        TABBadgeState *state = TABState(self);
        state.sampledImage = nil;
        state.color = nil;
        state.layerImage = nil;
        state.captureAttempted = NO;
        state.retries = 0;
        if (state.icon && !TABIsFolderIcon(state.icon)) [TABLeafColors removeObjectForKey:TABColorKey(state.icon)];
    }
    TABApply(self);
}

static void TABPreferencesChanged(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // Next main-queue turn lets Test 3's synchronous preference observer finish.
    dispatch_async(dispatch_get_main_queue(), ^{
        TABReloadPreferences();
        [TABLeafColors removeAllObjects];
        for (UIView *badge in TABBadges.allObjects) {
            TABBadgeState *state = TABState(badge);
            state.sampledImage = nil;
            state.color = nil;
            state.layerImage = nil;
            state.captureAttempted = NO;
            state.retries = 0;
            // Layout retries adaptive mode; static changes remain Test 3's job.
            TABApply(badge);
        }
    });
}

static BOOL TABCheck(Class cls, const char *name, unsigned args) {
    return TABMethodMatches(class_getInstanceMethod(cls, sel_registerName(name)), 'v', args);
}

static BOOL TABInstall(void) {
    static BOOL installed = NO;
    if (installed) return YES;
    TABBadgeClass = objc_getClass("SBIconBadgeView");
    TABIconClass = objc_getClass("SBIconView");
    TABRecord(@"init.badgeClassPresent", @(TABBadgeClass != Nil));
    TABRecord(@"init.iconClassPresent", @(TABIconClass != Nil));
    if (!TABBadgeClass || !TABIconClass) return NO;
    // Only one guaranteed ABI-safe entry point is required. Everything else
    // is optional and must independently pass a full method-signature check.
    if (!TABCheck(TABBadgeClass, "layoutSubviews", 0)) return NO;
    TABBadges = [NSHashTable weakObjectsHashTable];
    TABLeafColors = [NSCache new];
    TABLeafColors.countLimit = 256;
    TABReloadPreferences();
    if (TABCheck(TABBadgeClass, "configureForIcon:infoProvider:", 2))
        MSHookMessageEx(TABBadgeClass, sel_registerName("configureForIcon:infoProvider:"),
                        (IMP)TABConfigure, (IMP *)&TABOrigConfigure);
    if (TABCheck(TABBadgeClass, "configureAnimatedForIcon:infoProvider:animator:", 3))
        MSHookMessageEx(TABBadgeClass, sel_registerName("configureAnimatedForIcon:infoProvider:animator:"),
                        (IMP)TABAnimated, (IMP *)&TABOrigAnimated);
    MSHookMessageEx(TABBadgeClass, sel_registerName("layoutSubviews"),
                    (IMP)TABLayout, (IMP *)&TABOrigLayout);
    if (TABCheck(TABBadgeClass, "prepareForReuse", 0))
        MSHookMessageEx(TABBadgeClass, sel_registerName("prepareForReuse"),
                        (IMP)TABReuse, (IMP *)&TABOrigReuse);
    const char *appearance = "_configureBackgroundAfterIconImageAppearanceChange";
    if (!TABCheck(TABBadgeClass, appearance, 0))
        appearance = "_configureAfterIconImageAppearanceChange";
    if (TABCheck(TABBadgeClass, appearance, 0))
        MSHookMessageEx(TABBadgeClass, sel_registerName(appearance),
                        (IMP)TABAppearance, (IMP *)&TABOrigAppearance);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        TABPreferencesChanged, CFSTR("com.p2kdev.tinge.settingschanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    installed = YES;
    TABRecord(@"init.hooksInstalled", @YES);
    TABLog(@"standalone iOS 18 hooks installed after runtime ABI validation");
    return YES;
}

#ifndef TAB_HOST_TEST
__attribute__((constructor)) static void TABStart(void) {
    // Never rely on a ZZ filename for dylib load order. Wait until constructors
    // finish, then permit one bounded retry for delayed injection. No dyld locks.
    // Explicit firmware gate; never inject unknown SpringBoard versions.
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (os.majorVersion != 18) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            TABRecord(@"build", @"0.1-ios18-standalone");
            TABRecord(@"revision", @"coreless-abi-guard");
            TABRecord(@"startedAt", [[NSDate date] description]);
            TABRecord(@"init.mainQueueReached", @YES);
            if (TABInstall()) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                @try { if (!TABInstall()) {
                    TABRecord(@"init.failedAfterRetry", @YES);
                    TABLog(@"Tinge ABI unavailable; helper inactive until next SpringBoard start");
                } }
                @catch (NSException *e) { TABLog(@"initialization exception; helper inactive"); }
            });
        } @catch (NSException *e) { TABLog(@"initialization exception; helper inactive"); }
    });
}
#endif
