import AppKit

extension NSImage {
    var height: CGFloat {
        return self.size.height
    }

    var width: CGFloat {
        return self.size.width
    }

    func copy(size: NSSize) -> NSImage? {
        let frame = NSMakeRect(0, 0, size.width, size.height)
        guard let rep = self.bestRepresentation(for: frame, context: nil, hints: nil) else {
            return nil
        }
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        if rep.draw(in: frame) {
            return img
        }
        return nil
    }

    func resizeWhileMaintainingAspectRatioToSize(size: NSSize) -> NSImage? {
        let newSize: NSSize

        let widthRatio  = size.width / self.width
        let heightRatio = size.height / self.height

        if widthRatio > heightRatio {
            newSize = NSSize(width: floor(self.width * widthRatio), height: floor(self.height * widthRatio))
        } else {
            newSize = NSSize(width: floor(self.width * heightRatio), height: floor(self.height * heightRatio))
        }

        return self.copy(size: newSize)
    }
}

func getActiveBrowserTabURLAppleScriptCommand(_ appId: String) -> String? {
	switch appId {
	case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary", "com.mighty.app", "com.ghostbrowser.gb1", "com.bookry.wavebox", "com.pushplaylabs.sidekick", "com.operasoftware.Opera",  "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper", "com.vivaldi.Vivaldi":
		return "tell app id \"\(appId)\" to get the URL of active tab of front window to set visible to false"
	case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
		return "tell app id \"\(appId)\" to get URL of front document to set visible to false"
	default:
		return nil
	}
}

func exitWithoutResult() -> Never {
	print("null")
	exit(0)
}

@available(macOS 10.12, *)
func writeApplicationIconToDisk(app: NSRunningApplication) -> String? {
	let tmpDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("activewin").path;
	try! FileManager.default.createDirectory(atPath: tmpDirectory, withIntermediateDirectories: true, attributes: nil)
	let tmpPath = tmpDirectory + "/" + (app.bundleIdentifier ?? UUID().uuidString) + ".png"

	// Return early if this icon already exists on disk at this location
	if FileManager.default.fileExists(atPath: tmpPath) {
		return tmpPath
	}

	let resizedImage = app.icon!.resizeWhileMaintainingAspectRatioToSize(size: NSSize(width: 48, height: 48))
	let rep = NSBitmapImageRep(data: resizedImage!.tiffRepresentation!)
	let icon = rep?.representation(using: NSBitmapImageRep.FileType.png, properties: [.compressionFactor : 0.8])
	try! icon?.write(to: URL(fileURLWithPath: tmpPath))

	return tmpPath
}

let disableScreenRecordingPermission = CommandLine.arguments.contains("--no-screen-recording-permission")

// Show accessibility permission prompt if needed. Required to get the complete window title.
if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
	print("active-win requires the accessibility permission in “System Preferences › Security & Privacy › Privacy › Accessibility”.")
	exit(1)
}

let frontmostAppPID = NSWorkspace.shared.frontmostApplication!.processIdentifier
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]

// Show screen recording permission prompt if needed. Required to get the complete window title.
if
	let firstWindow = windows.first,
	let windowNumber = firstWindow[kCGWindowNumber as String] as? CGWindowID,
	CGWindowListCreateImage(.null, .optionIncludingWindow, windowNumber, [.boundsIgnoreFraming, .bestResolution]) == nil
{
	print("active-win requires the screen recording permission in “System Preferences › Security & Privacy › Privacy › Screen Recording”.")
	exit(1)
}

for window in windows {
	let windowOwnerPID = window[kCGWindowOwnerPID as String] as! pid_t // Documented to always exist.

	if windowOwnerPID != frontmostAppPID {
		continue
	}

	// Skip transparent windows, like with Chrome.
	if (window[kCGWindowAlpha as String] as! Double) == 0 { // Documented to always exist.
		continue
	}

	let bounds = CGRect(dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary)! // Documented to always exist.

	// Skip tiny windows, like the Chrome link hover statusbar.
	let minWinSize: CGFloat = 50
	if bounds.width < minWinSize || bounds.height < minWinSize {
		continue
	}

	// This should not fail as we're only dealing with apps, but we guard it just to be safe.
	guard let app = NSRunningApplication(processIdentifier: windowOwnerPID) else {
		continue
	}

	let appName = window[kCGWindowOwnerName as String] as? String ?? app.bundleIdentifier ?? "<Unknown>"

	let windowTitle = disableScreenRecordingPermission ? "" : window[kCGWindowName as String] as? String ?? ""

	var applicationIcon = "";

	if #available(macOS 10.12, *) {
		applicationIcon = writeApplicationIconToDisk(app: app) ?? ""
	}


	var output: [String: Any] = [
		"title": windowTitle,
		"id": window[kCGWindowNumber as String] as! Int, // Documented to always exist.
		"bounds": [
			"x": bounds.origin.x,
			"y": bounds.origin.y,
			"width": bounds.width,
			"height": bounds.height
		],
		"owner": [
			"name": appName,
			"processId": windowOwnerPID,
			"bundleId": app.bundleIdentifier ?? "", // I don't think this could happen, but we also don't want to crash.
			"path": app.bundleURL?.path ?? "" // I don't think this could happen, but we also don't want to crash.
		],
		"icon": applicationIcon,
		"memoryUsage": window[kCGWindowMemoryUsage as String] as? Int ?? 0
	]

	// Only run the AppleScript if active window is a compatible browser.
	if
		let bundleIdentifier = app.bundleIdentifier,
		let script = getActiveBrowserTabURLAppleScriptCommand(bundleIdentifier),
		let url = runAppleScript(source: script)
	{
		output["url"] = url
	}

	guard let string = try? toJson(output) else {
		exitWithoutResult()
	}

	print(string)
	exit(0)
}

exitWithoutResult()
