#pragma once
#import <Foundation/Foundation.h>

BOOL TABIsFolderIcon(id icon);
long long TABBadgeCount(id icon);
// Mirrors Test 3: highest positive count among direct folder members, first
// member on ties. Optional unsupported private APIs are never invoked blindly.
id TABHighestBadgedMember(id folderIcon, long long *count);
