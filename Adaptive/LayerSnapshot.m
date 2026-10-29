#import "LayerSnapshot.h"
#include <math.h>

static CALayer *TABCloneVisualLayer(CALayer *source, NSSet<CALayer *> *excluded,
                                  unsigned depth, NSUInteger *remaining, NSUInteger *visited) {
    if (!source || [excluded containsObject:source]) return nil;
    if (!*remaining || depth > 8) [NSException raise:@"TABLayerBudgetExceeded" format:@"bounded snapshot"];
    --*remaining; ++*visited;
    CALayer *copy;
    if ([source isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *original = (CAShapeLayer *)source;
        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.path = original.path;
        shape.fillColor = original.fillColor;
        shape.fillRule = original.fillRule;
        shape.strokeColor = original.strokeColor;
        shape.strokeStart = original.strokeStart;
        shape.strokeEnd = original.strokeEnd;
        shape.lineWidth = original.lineWidth;
        shape.lineCap = original.lineCap;
        shape.lineJoin = original.lineJoin;
        shape.miterLimit = original.miterLimit;
        shape.lineDashPhase = original.lineDashPhase;
        shape.lineDashPattern = original.lineDashPattern;
        copy = shape;
    } else if ([source isKindOfClass:[CAGradientLayer class]]) {
        CAGradientLayer *original = (CAGradientLayer *)source;
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = original.colors;
        gradient.locations = original.locations;
        gradient.startPoint = original.startPoint;
        gradient.endPoint = original.endPoint;
        gradient.type = original.type;
        copy = gradient;
    } else {
        copy = [CALayer layer];
    }
    copy.actions = @{};
    copy.bounds = source.bounds;
    copy.position = source.position;
    copy.anchorPoint = source.anchorPoint;
    copy.anchorPointZ = source.anchorPointZ;
    copy.zPosition = source.zPosition;
    copy.transform = source.transform;
    copy.sublayerTransform = source.sublayerTransform;
    copy.geometryFlipped = source.geometryFlipped;
    copy.doubleSided = source.doubleSided;
    copy.allowsGroupOpacity = source.allowsGroupOpacity;
    copy.hidden = source.hidden;
    copy.opacity = source.opacity;
    copy.backgroundColor = source.backgroundColor;
    copy.cornerRadius = source.cornerRadius;
    copy.maskedCorners = source.maskedCorners;
    copy.masksToBounds = source.masksToBounds;
    // Treat contents as an opaque Core Animation property. Never reinterpret it
    // as CGImageRef or call CFGetTypeID on an arbitrary Objective-C object.
    copy.contents = source.contents;
    copy.contentsRect = source.contentsRect;
    copy.contentsCenter = source.contentsCenter;
    copy.contentsScale = source.contentsScale;
    copy.contentsGravity = source.contentsGravity;
    copy.contentsFormat = source.contentsFormat;
    if (source.mask) copy.mask = TABCloneVisualLayer(source.mask, excluded, depth + 1, remaining, visited);
    for (CALayer *child in source.sublayers) {
        CALayer *subcopy = TABCloneVisualLayer(child, excluded, depth + 1, remaining, visited);
        if (subcopy) [copy addSublayer:subcopy];
    }
    return copy;
}

CGImageRef TABCopyLayerSnapshot(CALayer *root, NSSet<CALayer *> *excluded,
                               NSUInteger *visited, NSUInteger *opaquePixels) {
    if (visited) *visited = 0;
    if (opaquePixels) *opaquePixels = 0;
    if (!root) return NULL;
    CGRect bounds = root.bounds;
    if (!isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
        !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
        bounds.size.width < 1 || bounds.size.height < 1 ||
        bounds.size.width > 1024 || bounds.size.height > 1024) return NULL;
    NSUInteger remaining = 128, count = 0;
    CALayer *copy = nil;
    [CATransaction begin];
    @try {
        [CATransaction setDisableActions:YES];
        copy = TABCloneVisualLayer(root, excluded, 0, &remaining, &count);
    } @catch (NSException *exception) { copy = nil; }
    @finally { [CATransaction commit]; }
    if (visited) *visited = count;
    if (!copy) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) return NULL;
    uint8_t pixels[32 * 32 * 4] = {0};
    CGContextRef context = CGBitmapContextCreate(pixels, 32, 32, 8, 32 * 4, space,
                          kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGImageRef result = NULL;
    @try {
        CGContextScaleCTM(context, 32.0 / bounds.size.width, 32.0 / bounds.size.height);
        CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);
        [copy renderInContext:context];
        NSUInteger opaque = 0;
        for (size_t i = 0; i < 32 * 32; ++i) if (pixels[i * 4 + 3] >= 128) ++opaque;
        if (opaquePixels) *opaquePixels = opaque;
        if (opaque >= 16) result = CGBitmapContextCreateImage(context);
    } @catch (NSException *exception) { result = NULL; }
    @finally { CGContextRelease(context); }
    return result;
}
