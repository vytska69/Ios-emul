import Foundation
import IPSWKit

/// Settings written into the installed iOS's own preferences, so it starts up already configured.
///
/// A direct install creates the Data volume (/private/var) itself, so it can place preference
/// files where iOS reads them on first launch. They are the files iOS keeps for these settings on
/// a device (the accessibility domain, global preferences, the setup assistant's state, the
/// system configuration); the first-boot erase recreates the Data volume and drops them.
public struct GuestTweaks: Equatable {
    public enum Appearance: String, CaseIterable { case system, light, dark }
    public enum TextSize: String, CaseIterable { case system, large, extraLarge, accessibility }

    // Accessibility
    public var voiceOver = false
    public var zoom = false
    public var assistiveTouch = false
    public var boldText = false
    public var reduceMotion = false
    public var reduceTransparency = false
    public var increaseContrast = false
    public var invertColors = false
    public var grayscale = false
    public var textSize = TextSize.system

    // System
    public var appearance = Appearance.system
    /// BCP 47 language, e.g. "lt"; nil keeps the IPSW default (English).
    public var language: String?
    /// Locale identifier, e.g. "lt_LT"; nil derives nothing.
    public var region: String?
    public var deviceName: String?
    public var skipSetupAssistant = false
    public var use24HourClock = false

    public init() {}

    public var isEmpty: Bool { self == GuestTweaks() }

    /// Files to add to the Data volume, by path relative to /private/var.
    public func files() -> [String: (data: Data, attributes: APFSContainer.Attributes)] {
        let mobile = APFSContainer.Attributes(uid: 501, gid: 501, mode: 0o600)
        let root = APFSContainer.Attributes(uid: 0, gid: 0, mode: 0o644)
        var out: [String: (data: Data, attributes: APFSContainer.Attributes)] = [:]
        func add(_ path: String, _ plist: [String: Any], _ attributes: APFSContainer.Attributes) {
            guard !plist.isEmpty,
                  let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            else { return }
            out[path] = (data, attributes)
        }

        var accessibility: [String: Any] = [:]
        if voiceOver { accessibility["VoiceOverTouchEnabled"] = true }
        if zoom { accessibility["ZoomTouchEnabled"] = true }
        if assistiveTouch { accessibility["AssistiveTouchEnabled"] = true }
        if boldText { accessibility["EnhancedTextLegibilityEnabled"] = true }
        if reduceMotion { accessibility["ReduceMotionEnabled"] = true }
        if reduceTransparency { accessibility["EnhancedBackgroundContrastEnabled"] = true }
        if increaseContrast { accessibility["DarkenSystemColors"] = true }
        if invertColors { accessibility["ClassicInvertColors"] = true }
        if grayscale { accessibility["GrayscaleDisplay"] = true }
        add("mobile/Library/Preferences/com.apple.Accessibility.plist", accessibility, mobile)

        if let category = textSize.contentSizeCategory {
            add("mobile/Library/Preferences/com.apple.UIKit.plist", ["UIPreferredContentSizeCategoryName": category], mobile)
        }

        if appearance != .system {
            add("mobile/Library/Preferences/com.apple.uikitservices.userInterfaceStyleMode.plist",
                ["UserInterfaceStyleMode": appearance == .dark ? 2 : 1], mobile)
        }

        var global: [String: Any] = [:]
        if let language, !language.isEmpty { global["AppleLanguages"] = [language] }
        if let region, !region.isEmpty { global["AppleLocale"] = region }
        if use24HourClock { global["AppleICUForce24HourTime"] = true }
        add("mobile/Library/Preferences/.GlobalPreferences.plist", global, mobile)

        if skipSetupAssistant {
            // SetupDone alone is not enough: with a SetupVersion of 10 or less (or none) iOS 14 shows
            // the "upgrade mini buddy", which is the Hello screen again (Internal_BYSetupAssistantNeedsToRun).
            // The installer also patches the setup checks themselves (SharedCachePatches.skipSetupByBuild).
            add("mobile/Library/Preferences/com.apple.purplebuddy.plist",
                ["SetupDone": true, "SetupFinishedAllSteps": true, "SetupVersion": 11], mobile)
        }

        if let deviceName, !deviceName.isEmpty {
            let host = deviceName.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            add("preferences/SystemConfiguration/preferences.plist",
                ["System": ["System": ["ComputerName": deviceName, "HostName": host.isEmpty ? "iPhone" : host]]], root)
        }
        return out
    }
}

extension GuestTweaks.TextSize {
    /// UIKit's content size category for the "Larger Text" setting.
    var contentSizeCategory: String? {
        switch self {
        case .system: return nil
        case .large: return "UICTContentSizeCategoryXL"
        case .extraLarge: return "UICTContentSizeCategoryXXXL"
        case .accessibility: return "UICTContentSizeCategoryAccessibilityL"
        }
    }
}
