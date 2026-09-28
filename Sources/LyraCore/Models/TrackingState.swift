import Foundation

/// Whether the gaze pipeline is currently producing usable data.
public enum TrackingState: Sendable, Equatable {
    case idle
    case calibrating
    case tracking
    /// A face was found but the sample was unusable — usually a blink.
    case blinking
    case faceLost
    /// Camera is running but no calibration has been applied, so gaze cannot be trusted.
    case uncalibrated
    case error(String)

    public var isProducingGaze: Bool {
        if case .tracking = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .calibrating: return "Calibrating"
        case .tracking: return "Tracking"
        case .blinking: return "Eyes closed"
        case .faceLost: return "Face not found"
        case .uncalibrated: return "Not calibrated"
        case .error(let message): return message
        }
    }
}

/// Everything the UI needs to render, published as a single value.
///
/// The original design pushed state to the UI through four separate callbacks, which
/// made it possible for the interface to briefly show contradictory things (a stale
/// gaze dot alongside a fresh selection, say) and made the view model's state
/// impossible to reason about. One immutable snapshot per frame removes that whole
/// class of bug.
public struct LyraSnapshot: Sendable {
    public var trackingState: TrackingState
    public var isEngineRunning: Bool
    public var isSelectionModeActive: Bool

    /// Calibrated gaze position in screen points, origin top-left.
    public var gazePoint: LyraPoint?
    public var gazeConfidence: Double

    /// The target currently under consideration.
    public var selection: TargetSelection?
    /// 0...1 dwell progress towards committing the pending target.
    public var dwellProgress: Double?
    /// The target that has been committed and will act on the next activation command.
    public var committedTarget: TargetCandidate?

    /// How many targets were found in the last accessibility sweep. Zero usually means
    /// Accessibility permission is missing, which is worth surfacing explicitly.
    public var targetCount: Int
    public var targetsAreVisible: Bool
    public var isZoomed: Bool

    /// The lens currently being offered, ready to draw.
    ///
    /// Carried in the snapshot rather than fetched from the coordinator by the view so
    /// the rows the user sees and the rows the selection was computed against are
    /// guaranteed to be the same layout. Fetching it separately is a race with a visible
    /// symptom: a highlight drawn on a row the coordinator has already moved on from.
    public var lens: TargetLens.Layout

    public var lastTranscript: String
    public var lastCommand: LyraCommand?
    public var statusMessage: String
    public var errorMessage: String?

    /// Contextual macOS zone highlight (e.g. status bar, menu bar, stage manager, dock).
    public var contextualHighlight: ContextualHighlight?

    /// In-place cluster candidates around the gaze point highlighted directly on screen.
    public var inPlaceClusterCandidates: [TargetCandidate]

    public init(
        trackingState: TrackingState = .idle,
        isEngineRunning: Bool = false,
        isSelectionModeActive: Bool = false,
        gazePoint: LyraPoint? = nil,
        gazeConfidence: Double = 0,
        selection: TargetSelection? = nil,
        dwellProgress: Double? = nil,
        committedTarget: TargetCandidate? = nil,
        targetCount: Int = 0,
        targetsAreVisible: Bool = false,
        isZoomed: Bool = false,
        lens: TargetLens.Layout = .empty,
        lastTranscript: String = "—",
        lastCommand: LyraCommand? = nil,
        statusMessage: String = "Ready",
        errorMessage: String? = nil,
        contextualHighlight: ContextualHighlight? = nil,
        inPlaceClusterCandidates: [TargetCandidate] = []
    ) {
        self.trackingState = trackingState
        self.isEngineRunning = isEngineRunning
        self.isSelectionModeActive = isSelectionModeActive
        self.gazePoint = gazePoint
        self.gazeConfidence = gazeConfidence
        self.selection = selection
        self.dwellProgress = dwellProgress
        self.committedTarget = committedTarget
        self.targetCount = targetCount
        self.targetsAreVisible = targetsAreVisible
        self.isZoomed = isZoomed
        self.lens = lens
        self.lastTranscript = lastTranscript
        self.lastCommand = lastCommand
        self.statusMessage = statusMessage
        self.errorMessage = errorMessage
        self.contextualHighlight = contextualHighlight
        self.inPlaceClusterCandidates = inPlaceClusterCandidates
    }
}
