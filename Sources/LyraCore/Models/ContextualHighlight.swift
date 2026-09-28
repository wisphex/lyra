import Foundation

/// A high-level macOS system chrome or contextual zone under the user's gaze.
///
/// Implements state-based macro navigation:
/// - Top-left: Apple menu & active app menu bar
/// - Top-right: Menu bar status items / Control Center
/// - Stage Manager: Active window thumbnail on the left edge (with fine-tuning between windows)
/// - Dock: macOS Dock at the bottom
/// - Active App: Active application window in the main workspace
public struct ContextualHighlight: Sendable, Equatable {
    public enum ZoneKind: String, Sendable, Codable, Equatable {
        case topLeftMenu = "Menu Bar"
        case topRightStatus = "Status Bar"
        case stageManager = "Stage Manager"
        case dock = "Dock"
        case activeAppWindow = "Active Application"
    }

    /// The kind of macOS functional zone.
    public let kind: ZoneKind

    /// Exact bounding frame in screen coordinates (origin top-left).
    public let frame: LyraRect

    /// Primary display title (e.g. app name, status item name, or zone name).
    public let title: String

    /// Optional secondary detail (e.g. role or thumbnail window title).
    public let subtitle: String?

    /// Whether this highlight can be activated by click or dwell.
    public let isActionable: Bool

    /// The underlying target candidate if backed by an accessibility element or thumbnail.
    public let candidate: TargetCandidate?

    public init(
        kind: ZoneKind,
        frame: LyraRect,
        title: String,
        subtitle: String? = nil,
        isActionable: Bool = true,
        candidate: TargetCandidate? = nil
    ) {
        self.kind = kind
        self.frame = frame
        self.title = title
        self.subtitle = subtitle
        self.isActionable = isActionable
        self.candidate = candidate
    }
}
