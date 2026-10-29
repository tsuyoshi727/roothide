#pragma once
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>

// Copies only public visual properties into new plain layers. No live-layer
// mutation, draw/layout delegates, animations, raw CF casts, or icon-generation APIs.
// The caller owns the returned image. A null image means conservative pass-through.
CGImageRef TABCopyLayerSnapshot(CALayer *root, NSSet<CALayer *> *excluded,
                               NSUInteger *visited, NSUInteger *opaquePixels) CF_RETURNS_RETAINED;
