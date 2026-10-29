# Tinge18 Standalone (experimental source only)

This package is NOT compiled and NOT verified on an iPhone. No functional .deb has been generated in the supplied environment, which lacks Xcode/iPhoneOS SDK, RootHide Theos and ldid. Do not mistake the original Tinge 26 core for an iOS 18 port.

This is an independent *minimal* attempt to reproduce only the desired behavior: badge background color from the SpringBoard-rendered icon while retaining notification numbers. It does **not** ship the opaque `Tinge.dylib` from the original source archive, and it does not implement original Tinge settings, text-color or border controls. The bundled images/rendering helpers are carried from the source archive; their original attribution and license files are included.

## Changes

* No dependency on the prebuilt Tinge 26 core, its injected methods or RootHide rootless-compat marker.
* Runtime checks method signatures before installing hooks; `layoutSubviews` is the minimal fallback. `configure*`, `prepareForReuse` and appearance methods are optional.
* Adds an iOS 18-only process gate and a passive owner lookup on layout to seed badge state.
* Supports several icon image-view getter names and refuses unknown badge backgrounds instead of overwriting arbitrary views.
* Defaults to adaptive color when no previous Tinge preferences exist, so no settings pane is needed.

## Build on a Mac

Install Xcode, the RootHide fork of Theos with its iPhoneOS SDK, `ldid` and required Theos prerequisites. Set `THEOS` to the installed RootHide Theos directory and run:

```
make clean package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
```

The intended output is in `packages/`, architecture `iphoneos-arm64e`. This may require additional adjustments on the build machine. No build or runtime success has been claimed.

## Safe testing

Before testing any compiled version, disable/remove any existing badge coloring tweak. Save a way to enter safe mode or disable this tweak's injection. Test on iOS 18.3 only after verifying package signing and dependencies. If SpringBoard restarts/crashes, disable this tweak in the jailbreak's tweak manager or remove it in safe mode. This build has not been tested on a device.

## Caveats

On iOS 18.3 the internal badge view may use a different hierarchy, in which case the port deliberately leaves the badge untouched. Folder color depends on finding the specific rendered icon. SpringBoard ABI checks avoid some exceptions but cannot prove crash-free behavior. Safe Mode might still occur. Do not force-install if dependency verification fails.
