import Foundation
import CoreGraphics
import AppKit
import LyraCore

/// Produces targets for surfaces macOS accessibility cannot see.
///
/// Stage Manager's thumbnail strip is the motivating case and the reason this file
/// exists at all. The strip is drawn by the WindowServer, not by any application, so it
/// appears nowhere in the accessibility tree — `AXUIElement` can enumerate the Dock and
/// the menu bar but has no idea the strip is there. Gaze selection that cannot see the
/// strip therefore cannot reach the single most gaze-friendly target on the screen: a
/// column of large, well-separated, stationary thumbnails.
///
/// **How the geometry is found.** An earlier version synthesised slots from an assumed
/// strip width and vertical centring. Measured against a real display that was wrong on
/// every axis — assumed 287 points wide at x=10 and centred, actual 137 points wide at
/// x=16 and sitting near the top. Clicking the centre of a synthesised slot would have
/// landed in the gap between two thumbnails.
///
/// The real geometry needs no guessing. In Stage Manager the thumbnails *are* the windows
/// the system is holding: `CGWindowListCopyWindowInfo` reports each at exactly the size
/// and position it is drawn, with its owner — which is the label the user reads. A window
/// parked in the strip band is a thumbnail; the front window is not, because it is in the
/// middle of the display. That test is the whole classifier.
///
/// Clicking a slot is a coordinate click on a region we are confident about, which is why
/// these are marked `.screenRegion`: the coordinator refuses to invoke a semantic
/// accessibility action on them, because there is no element to invoke it on.
public struct StripScanner: Sendable {

    /// How far the strip reaches from its screen edge, as a fraction of screen width.
    ///
    /// Only has to separate "a window parked in the strip" from "a window in the middle of
    /// the display", so it is generous. On a 1470-point-wide display the widest real
    /// thumbnail ends at x=174, or 0.118.
    public var bandFraction: Double

    /// Smallest window that can be a thumbnail. Filters out the tiny helper windows
    /// applications leave lying around.
    public var minimumSize: Double

    public init(bandFraction: Double = 0.16, minimumSize: Double = 100) {
        self.bandFraction = bandFraction
        self.minimumSize = minimumSize
    }

    /// A window the strip is showing.
    public struct Thumbnail: Sendable {
        public let ownerName: String
        public let title: String?
        public let frame: LyraRect

        public var displayName: String {
            if let title, !title.isEmpty, title != ownerName {
                return "\(ownerName) — \(title)"
            }
            return ownerName
        }
    }

    // MARK: - Detection

    /// Whether Stage Manager is switched on.
    ///
    /// Read from the WindowServer's own preferences rather than guessed from geometry,
    /// so an ordinary desktop with a left-aligned window is never mistaken for a strip.
    public static var isStageManagerEnabled: Bool {
        let domain = "com.apple.WindowManager" as CFString
        guard let preferences = CFPreferencesCopyAppValue(
            "GloballyEnabled" as CFString,
            domain
        ) else {
            return false
        }
        return (preferences as? Bool) ?? false
    }

    /// Whether the strip is on the right edge, per the system preference.
    public static var isStripOnRightEdge: Bool {
        let domain = "com.apple.WindowManager" as CFString
        guard let preferences = CFPreferencesCopyAppValue(
            "windowManagerPrefersRightSide" as CFString,
            domain
        ) else {
            return false
        }
        return (preferences as? Bool) ?? false
    }

    // MARK: - Scanning

    /// Builds candidates for every thumbnail the strip is showing.
    ///
    /// Returns an empty array when Stage Manager is off, which is the honest answer: an
    /// inactive strip is not a target, and inventing slots along the edge of an ordinary
    /// desktop would put clickable ghosts over the user's actual windows.
    public func scan(screenSize: LyraSize, excludingPid pid: pid_t = getpid()) -> [TargetCandidate] {
        guard Self.isStageManagerEnabled else { return [] }

        return thumbnails(screenSize: screenSize, excludingPid: pid).enumerated().map { index, thumbnail in
            let identifier = [
                "strip",
                thumbnail.ownerName,
                "\(Int(thumbnail.frame.x)),\(Int(thumbnail.frame.y))",
                "\(index)"
            ].joined(separator: "|")

            return TargetCandidate(
                id: identifier,
                frame: thumbnail.frame,
                label: thumbnail.displayName,
                role: "StageManagerThumbnail",
                source: .screenRegion,
                // Shallow depth: these are top-level chrome, not nested content, and the
                // resolver prefers deeper elements when areas tie.
                depth: 1,
                isActionable: true,
                action: .press
            )
        }
    }

    /// The thumbnails the strip is showing, top to bottom.
    public func thumbnails(screenSize: LyraSize, excludingPid pid: pid_t) -> [Thumbnail] {
        let onLeft = !Self.isStripOnRightEdge
        let band = screenSize.width * bandFraction

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var found: [Thumbnail] = []
        for entry in raw {
            guard let ownerPid = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPid != pid else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let owner = entry[kCGWindowOwnerName as String] as? String else { continue }
            // System chrome owns real windows too — the WindowServer's own gesture
            // overlays, the Dock, Control Centre. None of them are thumbnails, and a slot
            // labelled "WindowManager" is a slot that raises nothing when clicked.
            guard !Self.systemOwners.contains(owner) else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }

            let frame = LyraRect(
                x: Double(rect.minX),
                y: Double(rect.minY),
                width: Double(rect.width),
                height: Double(rect.height)
            )

            guard frame.width >= minimumSize, frame.height >= minimumSize else { continue }
            guard onLeft ? frame.maxX <= band : frame.minX >= screenSize.width - band else { continue }

            // Window titles need Screen Recording permission; without it this is simply
            // nil and the label falls back to the application name.
            let title = entry[kCGWindowName as String] as? String
            found.append(Thumbnail(ownerName: owner, title: title, frame: frame))
        }

        // Collapse to one entry per application. The strip shows applications, and a
        // window caught mid-animation reports a second, overlapping frame — the same
        // window twice, at slightly different offsets.
        var seen = Set<String>()
        let unique = found
            .sorted { $0.frame.minY < $1.frame.minY }
            .filter { seen.insert($0.ownerName).inserted }

        return unique
    }

    /// Scans for visible application windows open on the desktop (excluding Stage Manager strip thumbnails).
    public func openWindows(screenSize: LyraSize, excludingPid pid: pid_t = getpid()) -> [Thumbnail] {
        let onLeft = !Self.isStripOnRightEdge
        let band = Self.isStageManagerEnabled ? (screenSize.width * bandFraction) : 0.0

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var found: [Thumbnail] = []
        for entry in raw {
            guard let ownerPid = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPid != pid else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let owner = entry[kCGWindowOwnerName as String] as? String else { continue }
            guard !Self.systemOwners.contains(owner) else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }

            let frame = LyraRect(
                x: Double(rect.minX),
                y: Double(rect.minY),
                width: Double(rect.width),
                height: Double(rect.height)
            )

            // Must be large enough to be an interactive application window
            guard frame.width >= 160, frame.height >= 120 else { continue }

            // Exclude windows parked in the Stage Manager strip
            if Self.isStageManagerEnabled {
                if onLeft && frame.maxX <= band { continue }
                if !onLeft && frame.minX >= screenSize.width - band { continue }
            }

            let title = entry[kCGWindowName as String] as? String
            found.append(Thumbnail(ownerName: owner, title: title, frame: frame))
        }

        return found
    }

    /// Builds TargetCandidate entries for every open application window on the workspace.
    public func scanOpenWindows(screenSize: LyraSize, excludingPid pid: pid_t = getpid()) -> [TargetCandidate] {
        return openWindows(screenSize: screenSize, excludingPid: pid).enumerated().map { index, window in
            let identifier = [
                "window",
                window.ownerName,
                "\(Int(window.frame.x)),\(Int(window.frame.y))",
                "\(index)"
            ].joined(separator: "|")

            return TargetCandidate(
                id: identifier,
                frame: window.frame,
                label: window.displayName,
                role: "AXWindow",
                source: .screenRegion,
                depth: 1,
                isActionable: true,
                action: .press
            )
        }
    }

    /// Processes that own on-screen windows without being applications a user can switch
    /// to. They never appear in the strip.
    private static let systemOwners: Set<String> = [
        "WindowManager", "Window Server", "Dock", "Control Center",
        "Notification Center", "Spotlight", "SystemUIServer", "TextInputMenuAgent",
        "universalaccessd", "loginwindow", "CoreServicesUIAgent"
    ]
}
