/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

// AppKit is linked into the windowed engine only
#ifndef HEADLESS

#include "BugReportMenu.h"

#import <AppKit/AppKit.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>

#include <algorithm>
#include <climits>
#include <cstdint>

static NSString* bridgePath = nil;
static NSMenu* dockMenu = nil;
static NSString* writeDirPath = nil;

@interface TellurionBugReportTarget : NSObject
- (void)saveBugReport:(id)sender;
- (void)showAbout:(id)sender;
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

// About Tellurion: the standard panel, with the engine version and a credits
// text saying what the app is and where to report problems
- (void)showAbout:(id)sender
{
	(void)sender;
	NSDictionary* info = [[NSBundle mainBundle] infoDictionary];
	NSString* port = info[@"PortVersion"] ?: info[@"CFBundleShortVersionString"] ?: @"?";
	NSString* engine = info[@"EngineVersion"] ?: info[@"CFBundleVersion"] ?: @"?";

	NSFont* font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	NSMutableParagraphStyle* para = [[NSMutableParagraphStyle alloc] init];
	[para setAlignment:NSTextAlignmentCenter];
	[para setParagraphSpacing:10];
	[para setLineSpacing:2];
	NSDictionary* plain = @{NSFontAttributeName: font, NSParagraphStyleAttributeName: para, NSForegroundColorAttributeName: [NSColor labelColor]};
	NSMutableAttributedString* credits = [[NSMutableAttributedString alloc] init];
	void (^add)(NSString*) = ^(NSString* t) { [credits appendAttributedString:[[NSAttributedString alloc] initWithString:t attributes:plain]]; };
	void (^link)(NSString*, NSString*) = ^(NSString* t, NSString* url) {
		NSMutableDictionary* a = [plain mutableCopy];
		a[NSLinkAttributeName] = [NSURL URLWithString:url];
		[credits appendAttributedString:[[NSAttributedString alloc] initWithString:t attributes:a]];
	};

	add(@"Beyond All Reason for Mac on Apple silicon, drawn through Mesa on Metal.\n");
	add(@"Not made or supported by the Beyond All Reason team. Please report problems at ");
	link(@"github.com/qant-au/tellurion/issues", @"https://github.com/qant-au/tellurion/issues");
	add(@", not to BAR.\n");
	add(@"Source: ");
	link(@"github.com/qant-au/tellurion", @"https://github.com/qant-au/tellurion");
	add(@"\nGNU GPL v2 or later. Third-party licences: Resources/LICENSES in the app.");

	[NSApp activateIgnoringOtherApps:YES];
	[NSApp orderFrontStandardAboutPanelWithOptions:@{
		NSAboutPanelOptionApplicationName: @"Tellurion",
		NSAboutPanelOptionApplicationVersion: port,
		NSAboutPanelOptionVersion: [NSString stringWithFormat:@"Recoil %@", engine],
		NSAboutPanelOptionCredits: credits,
	}];
}
@end

// -applicationDockMenu: for SDL's application delegate: the same item on the
// Dock icon's menu, which stays reachable while the game is in full screen
// (the menu bar is hidden there); Cmd+Tab away, then right-click the icon
static NSMenu* DockMenu(id, SEL, NSApplication*) { return dockMenu; }

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

		NSMenuItem* about = [appMenu numberOfItems] > 0 ? [appMenu itemAtIndex:0] : nil;
		if (about != nil && [about action] == @selector(orderFrontStandardAboutPanel:)) {
			[about setTarget:target];
			[about setAction:@selector(showAbout:)];
		}

		// after "About ...", in its own group
		const NSInteger at = std::min<NSInteger>(1, [appMenu numberOfItems]);
		[appMenu insertItem:[NSMenuItem separatorItem] atIndex:at];
		[appMenu insertItem:item atIndex:at + 1];

		id delegate = [NSApp delegate];
		const SEL sel = @selector(applicationDockMenu:);
		if (delegate != nil && ![delegate respondsToSelector:sel]) {
			dockMenu = [[NSMenu alloc] init];
			NSMenuItem* dockItem = [[NSMenuItem alloc] initWithTitle:@"Save Bug Report…" action:@selector(saveBugReport:) keyEquivalent:@""];
			[dockItem setTarget:target];
			[dockMenu addItem:dockItem];
			class_addMethod([delegate class], sel, (IMP)DockMenu, "@@:@");
		}
	}
}

}

#endif // !HEADLESS
