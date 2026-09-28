import Foundation

/// State-based Macro Navigation Engine for macOS gaze control.
///
/// Instead of continuous, jittery pixel-level floating cursor hunting:
/// 1. The screen is partitioned into high-level macro states so gaze ALWAYS attaches
///    confidently to an obvious target.
/// 2. States:
///    - Top Right: Whole menu extras / Control Center status bar
///    - Top Left: Whole Apple menu & application menu bar
///    - Bottom: Whole macOS Dock
///    - Left Edge (Stage Manager): Attaches to Stage Manager, then fine-tunes vertically
///      to highlight the exact window thumbnail closest to gaze
///    - Main Workspace: Highlights the active application window
public struct ContextualRegionResolver: Sendable {

    public init() {}

    /// Resolves the active macro state for any gaze coordinate.
    ///
    /// - Parameters:
    ///   - gazePoint: The user's screen-space gaze point (origin top-left).
    ///   - screenSize: Dimensions of the screen currently being tracked.
    ///   - candidates: Current snapshot of actionable/scanned UI targets.
    /// - Returns: A `ContextualHighlight` representing the active macro region.
    public func resolve(
        gazePoint: LyraPoint,
        screenSize: LyraSize,
        candidates: [TargetCandidate] = []
    ) -> ContextualHighlight? {
        guard screenSize.width > 100, screenSize.height > 100 else { return nil }

        let width = screenSize.width
        let height = screenSize.height

        // Macro boundary thresholds
        // Top bar threshold: generous 28% of screen height (~275pt on 982)
        let topBarThresholdY = max(height * 0.28, 220.0)
        // Dock threshold: generous bottom 34% of screen height (~66% of height)
        let dockThresholdY = height - max(height * 0.34, 280.0)
        // Stage Manager left edge threshold
        let stageManagerThresholdX = max(width * 0.18, 170.0)
        // Stage Manager vertical bounds: strictly in middle band
        let stageManagerMinY = max(height * 0.25, 200.0)
        let stageManagerMaxY = height - max(height * 0.32, 260.0)

        // 1. Stage Manager: Left edge STRICTLY within its physical vertical thumbnail band
        if gazePoint.x <= stageManagerThresholdX && gazePoint.y >= stageManagerMinY && gazePoint.y <= stageManagerMaxY {
            return resolveStageManagerThumbnail(gazePoint: gazePoint, screenSize: screenSize, candidates: candidates)
        }

        // 2. Whole Dock (Bottom Area):
        // Downward glance, or bottom-right glance (Dock Right / Trash), or left edge below Stage Manager
        let isBottomRight = gazePoint.x >= (width * 0.55) && gazePoint.y >= (height * 0.58)
        let isBottomLeft = gazePoint.x <= stageManagerThresholdX && gazePoint.y > stageManagerMaxY
        if gazePoint.y >= dockThresholdY || isBottomRight || isBottomLeft {
            return resolveWholeDock(screenSize: screenSize)
        }

        // 3. Top Menu Bar (Top Left & Top Right):
        // Upward glance, or left edge above Stage Manager, or top-left ish glance when not inside an open window
        let isLeftEdgeTop = gazePoint.x <= stageManagerThresholdX && gazePoint.y < stageManagerMinY
        let isTopLeftIsh = gazePoint.x <= (width * 0.40) && gazePoint.y <= max(height * 0.32, 290.0) && !candidates.contains(where: {
            ($0.role == "AXWindow" || $0.role == "window" || $0.role == "ActiveWindow") && $0.frame.contains(gazePoint)
        })

        if gazePoint.y <= topBarThresholdY || isLeftEdgeTop || isTopLeftIsh {
            let splitX = width * 0.50
            if gazePoint.x >= splitX && gazePoint.y <= topBarThresholdY {
                return resolveWholeTopRight(screenSize: screenSize)
            } else {
                return resolveWholeTopLeft(screenSize: screenSize)
            }
        }

        // 4. Main Workspace: Selects between the open application windows on the screen
        return resolveActiveAppWindow(gazePoint: gazePoint, screenSize: screenSize, candidates: candidates)
    }

    // MARK: - Macro State Creators

    /// Highlights the entire top-right status bar / Control Center region.
    public func resolveWholeTopRight(screenSize: LyraSize) -> ContextualHighlight {
        let barHeight = 32.0
        let startX = screenSize.width * 0.52
        let barWidth = screenSize.width - startX - 8.0
        let frame = LyraRect(x: startX, y: 3.0, width: barWidth, height: barHeight)

        return ContextualHighlight(
            kind: .topRightStatus,
            frame: frame,
            title: "Control Center & Status",
            subtitle: "Top Right",
            candidate: nil
        )
    }

    /// Highlights the entire top-left Apple menu & application menu bar.
    public func resolveWholeTopLeft(screenSize: LyraSize) -> ContextualHighlight {
        let barHeight = 32.0
        let startX = 6.0
        let barWidth = (screenSize.width * 0.48) - startX
        let frame = LyraRect(x: startX, y: 3.0, width: barWidth, height: barHeight)

        return ContextualHighlight(
            kind: .topLeftMenu,
            frame: frame,
            title: "Apple & App Menu",
            subtitle: "Top Left",
            candidate: nil
        )
    }

    /// Highlights the entire macOS Dock at the bottom of the screen.
    public func resolveWholeDock(screenSize: LyraSize) -> ContextualHighlight {
        let dockHeight = 84.0
        let dockWidth = min(screenSize.width * 0.88, 1200.0)
        let dockX = (screenSize.width - dockWidth) / 2.0
        let dockY = screenSize.height - dockHeight - 4.0
        let frame = LyraRect(x: dockX, y: dockY, width: dockWidth, height: dockHeight)

        return ContextualHighlight(
            kind: .dock,
            frame: frame,
            title: "Dock",
            subtitle: "Bottom",
            candidate: nil
        )
    }

    /// Fine-tunes vertically inside Stage Manager to calculate which specific window thumbnail
    /// is closest to gaze Y, and highlights that window thumbnail rectangle.
    public func resolveStageManagerThumbnail(
        gazePoint: LyraPoint,
        screenSize: LyraSize,
        candidates: [TargetCandidate] = []
    ) -> ContextualHighlight {
        // If accessibility scanned real Stage Manager window thumbnails, match against them
        let thumbnailCandidates = candidates.filter {
            $0.role == "StageManagerThumbnail" ||
            ($0.source == .screenRegion && $0.frame.minX <= 30.0 && $0.frame.width >= 60.0 && $0.frame.height >= 50.0)
        }

        if let best = thumbnailCandidates.min(by: { abs($0.frame.midY - gazePoint.y) < abs($1.frame.midY - gazePoint.y) }) {
            return ContextualHighlight(
                kind: .stageManager,
                frame: best.frame,
                title: best.displayName,
                subtitle: "Stage Manager Window",
                candidate: best
            )
        }

        // Geometric Stage Manager slots (calibrated to macOS 13/14 Stage Manager strip)
        let topY = 160.0
        let bottomY = screenSize.height - 110.0
        let availableHeight = max(bottomY - topY, 300.0)

        let slotCount = 4
        let slotHeight = min(availableHeight / Double(slotCount) - 16.0, 135.0)
        let slotWidth = 125.0
        let slotX = 6.0
        let spacing = (availableHeight - (Double(slotCount) * slotHeight)) / Double(slotCount - 1)

        var closestIndex = 0
        var minDistance = Double.infinity
        var closestFrame = LyraRect(x: slotX, y: topY, width: slotWidth, height: slotHeight)

        for i in 0..<slotCount {
            let y = topY + Double(i) * (slotHeight + spacing)
            let centerY = y + (slotHeight / 2.0)
            let distance = abs(gazePoint.y - centerY)

            if distance < minDistance {
                minDistance = distance
                closestIndex = i
                closestFrame = LyraRect(x: slotX, y: y, width: slotWidth, height: slotHeight)
            }
        }

        return ContextualHighlight(
            kind: .stageManager,
            frame: closestFrame,
            title: "Stage Manager (Window \(closestIndex + 1))",
            subtitle: "Left Edge",
            candidate: nil
        )
    }

    /// Highlights the open application window under gaze in the main workspace.
    public func resolveActiveAppWindow(
        gazePoint: LyraPoint = LyraPoint(x: 0, y: 0),
        screenSize: LyraSize,
        candidates: [TargetCandidate] = []
    ) -> ContextualHighlight {
        // Collect all open window candidates
        let windowCandidates = candidates.filter {
            ($0.role == "AXWindow" || $0.role == "window" || $0.role == "ActiveWindow") &&
            $0.frame.width >= 160 &&
            $0.frame.height >= 120
        }

        // 1. If gaze is directly inside one of the open windows, highlight that exact window!
        // (CGWindowList returns windows in front-to-back z-order, so the topmost window wins if overlapping)
        if let windowUnderGaze = windowCandidates.first(where: { $0.frame.contains(gazePoint) }) {
            return ContextualHighlight(
                kind: .activeAppWindow,
                frame: windowUnderGaze.frame,
                title: windowUnderGaze.displayName,
                subtitle: "Open Window",
                candidate: windowUnderGaze
            )
        }

        // 2. If gaze is in the workspace near open windows, select the nearest open window
        if let closestWindow = windowCandidates.min(by: { $0.frame.distance(to: gazePoint) < $1.frame.distance(to: gazePoint) }) {
            return ContextualHighlight(
                kind: .activeAppWindow,
                frame: closestWindow.frame,
                title: closestWindow.displayName,
                subtitle: "Open Window",
                candidate: closestWindow
            )
        }

        // 3. Fallback if no window candidates: pleasantly proportioned centered workspace window (not too big!)
        let fallbackWidth = min(screenSize.width * 0.60, 880.0)
        let fallbackHeight = min(screenSize.height * 0.55, 540.0)
        let fallbackX = (screenSize.width - fallbackWidth) / 2.0
        let fallbackY = 44.0 + (screenSize.height - 44.0 - 90.0 - fallbackHeight) / 2.0

        let frame = LyraRect(x: fallbackX, y: fallbackY, width: fallbackWidth, height: fallbackHeight)

        return ContextualHighlight(
            kind: .activeAppWindow,
            frame: frame,
            title: "Active Application",
            subtitle: "Main Workspace",
            candidate: nil
        )
    }
}
