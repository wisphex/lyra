import Foundation
import LyraCore

/// The macOS `TargetProvider`: accessibility elements plus the surfaces accessibility
/// cannot see.
///
/// Two sources feed one list because the resolver, the lens and the safety policy all
/// want to reason about a single set of things the user can look at. Splitting them
/// would mean two selection pipelines, two lens layouts and two chances for the
/// interface to disagree with itself about what is selected.
///
/// Routing an action back out is by `TargetCandidate.Source`, not by guessing from the
/// coordinate: an element-backed target gets a semantic action, a screen-region target
/// gets a coordinate click, and neither can be mistaken for the other.
public final class MacTargetProvider: TargetProvider, @unchecked Sendable {

    private let accessibility: AXTargetProvider
    private let strip: StripScanner
    private let lock = NSLock()
    private var screenSize = LyraSize(width: 1512, height: 982)

    public init(
        accessibility: AXTargetProvider = AXTargetProvider(),
        strip: StripScanner = StripScanner()
    ) {
        self.accessibility = accessibility
        self.strip = strip
    }

    public func setScreenSize(_ size: LyraSize) {
        lock.lock()
        screenSize = size
        lock.unlock()
        accessibility.setScreenSize(size)
    }

    private func currentScreenSize() -> LyraSize {
        lock.lock()
        defer { lock.unlock() }
        return screenSize
    }

    public func snapshotTargets() async -> TargetSnapshot {
        let size = currentScreenSize()

        // The accessibility walk is the expensive half and can block; the strip scan is
        // pure geometry over a window list. Run the strip scan concurrently rather than
        // after, so it never adds to the sweep's latency.
        async let accessibilityCandidates = accessibility.snapshotTargets()
        let stripCandidates = strip.scan(screenSize: size)
        let openWindowCandidates = strip.scanOpenWindows(screenSize: size)

        let captured = await accessibilityCandidates

        // Strip thumbnails and open application windows take priority over raw accessibility controls
        // for high-level macro window and surface navigation.
        return TargetSnapshot(
            candidates: stripCandidates + openWindowCandidates + captured.candidates,
            screenSize: size
        )
    }

    public func perform(action: TargetCandidate.SemanticAction, on target: TargetSnapshot) async throws {
        guard let candidate = target.candidates.first else {
            throw TargetProviderError.elementUnavailable
        }

        switch candidate.source {
        case .screenRegion:
            // Nothing to invoke: the caller must fall back to a coordinate click. Saying
            // so explicitly is what keeps that fallback visible instead of silent.
            throw TargetProviderError.actionUnsupported(candidate.role)
        case .accessibility:
            try await accessibility.perform(action: action, on: candidate)
        }
    }

    public func invalidate() {
        accessibility.invalidate()
    }

    /// Whether Stage Manager's strip is currently contributing targets.
    public var isStripActive: Bool {
        StripScanner.isStageManagerEnabled
    }
}
