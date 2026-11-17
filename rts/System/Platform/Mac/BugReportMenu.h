/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#ifndef MAC_BUG_REPORT_MENU_H
#define MAC_BUG_REPORT_MENU_H

#include <string>

namespace MacBugReport {
	// "Save Bug Report..." in the application menu: runs the app's sl-bridge
	// once to save the logs as a zip on the Desktop and show it in Finder.
	// BAR's lobby sends its Upload Infolog to BAR's own servers, which this
	// build does not use, so this menu item is the port's way to the logs.
	// No-op when sl-bridge is not beside the engine (a bare build folder).
	// After the window exists.
	void InstallMenuItem(const std::string& writeDir);
};

#endif // MAC_BUG_REPORT_MENU_H
