/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

// AppKit is linked into the windowed engine only
#ifndef HEADLESS

#include "BugReportMenu.h"

#import <AppKit/AppKit.h>
#include <mach-o/dyld.h>

#include <algorithm>
#include <climits>
#include <cstdint>

static NSString* bridgePath = nil;
static NSString* writeDirPath = nil;

@interface TellurionBugReportTarget : NSObject
- (void)saveBugReport:(id)sender;
@end

@implementation TellurionBugReportTarget
- (void)saveBugReport:(id)sender
{
	(void)sender;
	NSArray* args = @[
		@"--writedir", writeDirPath,
		@"--log", [writeDirPath stringByAppendingPathComponent:@"sl-bridge.log"],
		@"--bug-report", @"1",
	];
	NSError* err = nil;
	[NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:bridgePath] arguments:args error:&err terminationHandler:nil];
	if (err != nil)
		NSLog(@"[MacBugReport] could not start sl-bridge: %@", err);
}
@end

namespace MacBugReport {

void InstallMenuItem(const std::string& writeDir)
{
	@autoreleasepool {
		char exe[PATH_MAX];
		uint32_t size = sizeof(exe);
		if (_NSGetExecutablePath(exe, &size) != 0)
			return;

		NSString* bridge = [[[NSString stringWithUTF8String:exe] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"sl-bridge"];
		if (![[NSFileManager defaultManager] isExecutableFileAtPath:bridge])
			return;

		NSMenu* appMenu = [[[NSApp mainMenu] itemAtIndex:0] submenu];
		if (appMenu == nil || bridgePath != nil)
			return;

		bridgePath = [bridge copy];
		writeDirPath = [[NSString stringWithUTF8String:writeDir.c_str()] copy];

		static TellurionBugReportTarget* target = [[TellurionBugReportTarget alloc] init];
		NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"Save Bug Report…" action:@selector(saveBugReport:) keyEquivalent:@""];
		[item setTarget:target];

		// after "About ...", in its own group
		const NSInteger at = std::min<NSInteger>(1, [appMenu numberOfItems]);
		[appMenu insertItem:[NSMenuItem separatorItem] atIndex:at];
		[appMenu insertItem:item atIndex:at + 1];
	}
}

}

#endif // !HEADLESS
