import Foundation

/// The single control plane. Everything that reaches the outside world passes through here.
///
/// `docs/AGENTS.md` §4 forbids shortcuts such as `speech callback -> click()`. This actor
/// is the enforcement point: gaze and speech arrive as data, are combined into a
/// deliberate selection, pass a risk policy, and only then reach an executor. Nothing
/// else in the codebase is allowed to hold both a camera and an input controller.
///
/// Responsibilities, in the order data flows through them:
///
/// 1. Calibrated gaze: features in, screen point out, blink-rejected and smoothed.
/// 2. Target resolution: which on-screen control that point refers to.
/// 3. Stabilisation: whether the user has held it long enough to mean it.
/// 4. Command execution: risk check, then a semantic action or a coordinate fallback.
public actor LyraCoordinator {

    // MARK: - Dependencies

    private let gazeProvider: any GazeProvider
    private let speechProvider: any SpeechProvider
    private let targetProvider: any TargetProvider
    private let inputController: any InputController

    private let resolver: TargetResolver
    private let lens: TargetLens
    private let riskPolicy: RiskPolicy
    private let gazeFilter: OneEuroFilter
    private let noseFineTune: NoseFineTuneController
    private var stabilizer: TargetStabilizer
    private var syncSystemCursor: Bool = false
    private let continuousTrainer = ContinuousClickTrainer()

    // MARK: - State

    private var snapshot = LyraSnapshot()

    private var calibrationMap: CalibrationMap
    private var targets: [TargetCandidate] = []
    private var screenSize: LyraSize = LyraSize(width: 1512, height: 982)

    /// Rolling median of recent gaze confidence, used to stop a single weak frame from
    /// moving the selection.
    private var displayedGaze: LyraPoint?
    private var lastScreenPoint: LyraPoint?

    /// Deduplication for speech. Recognition emits the same phrase repeatedly as it
    /// refines, and acting twice on "click" is a real bug, not a theoretical one.
    private var lastExecutedCommand: LyraCommand?
    private var lastExecutedAt: Date = .distantPast
    private var lastFinalTranscript: String = ""

    private var zoomVisible = false
    private var zoomLimit: Int? = nil
    private var lensLayout: TargetLens.Layout = .empty
    private var pendingConfirmation: LyraCommand?

    /// Opens the lens without being asked, when the gaze settles on a cluster of small
    /// controls. See `AutoLensPolicy` for why that is the right trigger.
    private var autoLens: AutoLensTracker
    private var contextualResolver = ContextualRegionResolver()
    private var contextualHighlightingEnabled: Bool = true

    /// Whether the lens currently on screen was opened by the policy rather than by the
    /// user. Only an automatic lens may close itself; one the user asked for stays until
    /// they dismiss it, or "hide targets" would undo itself a second after being spoken.
    private var autoLensOpened = false

    private var lastPublishAt: Date = .distantPast

    /// Tap on the raw feature stream, used by the calibration UI.
    ///
    /// Calibration needs the *uncalibrated* measurements, but `GazeProvider.featureStream`
    /// is single-consumer — attaching a second reader would silently steal frames from
    /// the coordinator. Tapping the stream the coordinator already owns is the only way
    /// to observe frames without either duplicating the camera pipeline or racing over
    /// one continuation.
    private var featureObserver: (@Sendable (GazeFeatures) -> Void)?
    private var calibrationUpdateObserver: (@Sendable (CalibrationMap) -> Void)?

    public func setCalibrationUpdateObserver(_ observer: (@Sendable (CalibrationMap) -> Void)?) {
        self.calibrationUpdateObserver = observer
    }

    // MARK: - Tasks

    private var gazeTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?

    private var snapshotContinuation: AsyncStream<LyraSnapshot>.Continuation?

    // MARK: - Init

    public init(
        gazeProvider: any GazeProvider,
        speechProvider: any SpeechProvider,
        targetProvider: any TargetProvider,
        inputController: any InputController,
        calibrationMap: CalibrationMap = .identity,
        resolver: TargetResolver = TargetResolver(),
        lens: TargetLens = .default,
        stabilizer: TargetStabilizer = TargetStabilizer(),
        gazeFilter: OneEuroFilter = OneEuroFilter(),
        noseFineTune: NoseFineTuneController = NoseFineTuneController(),
        riskPolicy: RiskPolicy = RiskPolicy(),
        autoLensPolicy: AutoLensPolicy = AutoLensPolicy(isEnabled: false)
    ) {
        self.gazeProvider = gazeProvider
        self.speechProvider = speechProvider
        self.targetProvider = targetProvider
        self.inputController = inputController
        self.calibrationMap = calibrationMap
        self.resolver = resolver
        self.lens = lens
        self.stabilizer = stabilizer
        self.gazeFilter = gazeFilter
        self.noseFineTune = noseFineTune
        self.riskPolicy = riskPolicy
        self.autoLens = AutoLensTracker(policy: autoLensPolicy)
    }

    // MARK: - Observation

    /// Stream of UI state. One snapshot per meaningful change rather than a callback
    /// per concern, so the interface can never render a self-contradictory frame.
    public var snapshots: AsyncStream<LyraSnapshot> {
        AsyncStream { continuation in
            self.snapshotContinuation = continuation
            continuation.yield(self.snapshot)
            continuation.onTermination = { @Sendable _ in }
        }
    }

    public var currentSnapshot: LyraSnapshot { snapshot }

    public var currentCalibrationMap: CalibrationMap { calibrationMap }

    /// Installs the raw-feature tap. Pass `nil` to remove it.
    public func setFeatureObserver(_ observer: (@Sendable (GazeFeatures) -> Void)?) {
        featureObserver = observer
    }

    // MARK: - Configuration

    public func setScreenSize(_ size: LyraSize) {
        screenSize = LyraSize(width: max(size.width, 200), height: max(size.height, 200))
        snapshot.statusMessage = "Screen: \(Int(size.width))×\(Int(size.height))"
        publish(force: true)
    }

    public func setNoseFineTune(enabled: Bool, sensitivity: Double? = nil, invertX: Bool? = nil, invertY: Bool? = nil) {
        noseFineTune.configure(isEnabled: enabled, sensitivity: sensitivity, invertX: invertX, invertY: invertY)
        if !enabled {
            noseFineTune.reset()
        }
    }

    public func setNoseInversion(invertX: Bool, invertY: Bool) {
        noseFineTune.configure(invertX: invertX, invertY: invertY)
    }

    public func setSteeringMode(_ mode: NoseFineTuneController.Mode) {
        noseFineTune.configure(mode: mode)
        if mode == .noseOnly && snapshot.isEngineRunning {
            snapshot.trackingState = .tracking
            snapshot.statusMessage = "Nose Steering — Press 'C' to recenter"
        }
        publish(force: true)
    }

    public func recenterNose() {
        noseFineTune.recenter()
        if snapshot.isEngineRunning {
            snapshot.statusMessage = "Nose recentered to center"
            publish(force: true)
        }
    }

    public func setSyncSystemCursor(_ sync: Bool) {
        syncSystemCursor = sync
    }

    public func setCalibrationMap(_ map: CalibrationMap) {
        calibrationMap = map
        gazeFilter.reset()
        noseFineTune.reset()
        stabilizer.reset()
        displayedGaze = nil
        lastScreenPoint = nil
        snapshot.statusMessage = map.isCalibrated
            ? String(format: "Calibrated — %.0f px average error", map.validationErrorPixels)
            : "Not calibrated"
        publish(force: true)
    }

    public func applyCalibration(_ map: CalibrationMap) {
        setCalibrationMap(map)
    }

    public func setContinuousTrainingEnabled(_ enabled: Bool) {
        continuousTrainer.isEnabled = enabled
    }

    public func setContinuousTrainingBaseSamples(_ samples: [CalibrationSample]) {
        continuousTrainer.setBaseSamples(samples)
    }

    public func registerPassiveClick(atNormalized location: (x: Double, y: Double)) {
        guard continuousTrainer.isEnabled, calibrationMap.isCalibrated else { return }
        if let newMap = continuousTrainer.registerClick(
            atNormalized: location,
            screenSize: screenSize,
            context: calibrationMap.context
        ) {
            self.calibrationMap = newMap
            snapshot.statusMessage = String(format: "Calibrated — ±%.0f px (live refined)", newMap.validationErrorPixels)
            publish()
            calibrationUpdateObserver?(newMap)
        }
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !snapshot.isEngineRunning else { return }

        snapshot.errorMessage = nil
        if noseFineTune.mode == .noseOnly {
            snapshot.trackingState = .tracking
            snapshot.statusMessage = "Nose Steering — Press 'C' to recenter"
        } else {
            snapshot.trackingState = calibrationMap.isCalibrated ? .tracking : .uncalibrated
        }

        do {
            try await gazeProvider.start()
            listenToGaze()
        } catch {
            snapshot.trackingState = .error(error.localizedDescription)
            snapshot.errorMessage = error.localizedDescription
            publish(force: true)
            throw error
        }

        // Speech is optional. Losing it degrades Lyra to gaze-only, which is a supported
        // mode, so a failure here must never take the gaze pipeline down with it.
        do {
            try await speechProvider.start()
            listenToSpeech()
        } catch {
            snapshot.statusMessage = "Voice unavailable — gaze only. \(error.localizedDescription)"
        }

        startTargetSweeping()
        snapshot.isEngineRunning = true
        snapshot.isSelectionModeActive = true
        publish(force: true)
    }

    public func stop() async {
        guard snapshot.isEngineRunning else { return }

        gazeTask?.cancel(); gazeTask = nil
        speechTask?.cancel(); speechTask = nil
        sweepTask?.cancel(); sweepTask = nil

        await gazeProvider.stop()
        await speechProvider.stop()

        stabilizer.reset()
        gazeFilter.reset()
        noseFineTune.reset()
        // Also clears zoomVisible, which stopping otherwise leaves set — the overlay
        // would keep drawing a lens over a screen nothing is tracking.
        setZoom(false)
        // After setZoom, not before: setZoom stamps the cooldown, and a fresh run should
        // have no cooldown left over from the last one.
        autoLens.reset()
        targets = []
        displayedGaze = nil
        lastScreenPoint = nil

        snapshot.isEngineRunning = false
        snapshot.isSelectionModeActive = false
        snapshot.trackingState = .idle
        snapshot.selection = nil
        snapshot.committedTarget = nil
        snapshot.dwellProgress = nil
        snapshot.contextualHighlight = nil
        snapshot.inPlaceClusterCandidates = []
        snapshot.targetCount = 0
        snapshot.statusMessage = "Stopped"
        publish(force: true)
    }

    // MARK: - Gaze pipeline

    private func listenToGaze() {
        let stream = gazeProvider.featureStream
        gazeTask = Task { [weak self] in
            guard let self else { return }
            for await features in stream {
                if Task.isCancelled { break }
                await self.handle(features: features)
            }
        }
    }

    /// One frame of the pipeline, start to finish.
    func handle(features: GazeFeatures) async {
        // Deliberately before the calibration gate below: the calibration run needs every
        // frame, including the ones this method is about to discard for having no map yet.
        featureObserver?(features)
        continuousTrainer.observe(features: features)

        snapshot.gazeConfidence = features.confidence

        // Pure Nose Steering Mode: calibration and blink-dropping are bypassed!
        if noseFineTune.mode == .noseOnly {
            guard features.confidence > 0.25 else {
                snapshot.trackingState = .faceLost
                publish()
                return
            }

            let steered = noseFineTune.updateNoseOnly(
                yaw: features.yaw,
                pitch: features.pitch,
                now: features.timestamp
            )

            let point = LyraPoint(
                x: Double(steered.x) * Double(screenSize.width),
                y: Double(steered.y) * Double(screenSize.height)
            )

            displayedGaze = point
            lastScreenPoint = point
            snapshot.gazePoint = point
            snapshot.trackingState = .tracking

            if syncSystemCursor {
                try? await inputController.moveCursor(toScreenPoint: (point.x, point.y))
            }

            updateSelection(for: point, confidence: features.confidence)
            publish()
            return
        }

        guard calibrationMap.isCalibrated else {
            snapshot.trackingState = .uncalibrated
            publish()
            return
        }

        // Blinks and lost detections are dropped here rather than smoothed through.
        // A closed eye produces a pupil at the eyelid, which the model reads as a
        // large vertical gaze shift; filtering it would only spread the damage.
        guard features.isUsable else {
            snapshot.trackingState = .blinking
            publish()
            return
        }

        guard let predicted = calibrationMap.predict(features: features) else {
            snapshot.trackingState = .faceLost
            publish()
            return
        }

        let smoothed = gazeFilter.filter(predicted)
        let steered = noseFineTune.update(
            rawGaze: CGPoint(x: smoothed.x, y: smoothed.y),
            yaw: features.yaw,
            pitch: features.pitch,
            now: features.timestamp
        )

        let point = LyraPoint(
            x: Double(steered.x) * Double(screenSize.width),
            y: Double(steered.y) * Double(screenSize.height)
        )

        displayedGaze = point
        lastScreenPoint = point
        snapshot.gazePoint = point
        snapshot.trackingState = .tracking

        updateSelection(for: point, confidence: smoothed.confidence)
        publish()
    }

    /// Resolves and stabilises the target under the gaze point.
    private func updateSelection(for point: LyraPoint, confidence: Double) {
        snapshot.isSelectionModeActive = true
        let now = Date().timeIntervalSince1970

        // 1. Contextual macOS region highlighting (Top Right, Top Left, Stage Manager, Dock)
        if contextualHighlightingEnabled,
           let contextual = contextualResolver.resolve(gazePoint: point, screenSize: screenSize, candidates: targets) {
            snapshot.contextualHighlight = contextual

            let candidate = contextual.candidate ?? TargetCandidate(
                id: "contextual|\(contextual.kind.rawValue)|\(Int(contextual.frame.x)),\(Int(contextual.frame.y))",
                frame: contextual.frame,
                label: contextual.title,
                role: contextual.kind.rawValue,
                source: .screenRegion,
                depth: 1,
                isActionable: true,
                action: .press
            )
            let directSelection = TargetSelection(candidate: candidate, distance: 0, confidence: confidence)
            let outcome = stabilizer.update(selection: directSelection, at: now)
            apply(outcome)
            snapshot.inPlaceClusterCandidates = []
            return
        } else {
            snapshot.contextualHighlight = nil
        }

        // In lens mode the choice set is the lens, not the screen. Rows are large and
        // few, so a generous snap and no dwell requirement are both appropriate — the
        // lens has already done the hard work of making the decision binary.
        if zoomVisible {
            updateLensSelection(for: point, confidence: confidence)

            // Only an automatic lens closes itself. Closing keys off the panel rather
            // than off the cluster: the user has to look *at* the lens to choose a row,
            // so "gaze left the cluster" would shut it in the same instant they used it.
            if autoLensOpened,
               autoLens.updateOpen(gazePoint: point, lensPanel: lensLayout.panelFrame, at: now) {
                setZoom(false)
                snapshot.selection = nil
                snapshot.dwellProgress = nil
                snapshot.statusMessage = "Lens closed"
                publish(force: true)
            }
            return
        }

        // 2. In-place cluster candidates (highlights multiple nearby buttons in place on screen)
        let clusterRadius = 110.0
        let clusterCandidates = targets.filter { candidate in
            candidate.isActionable
                && candidate.area < (screenSize.area * 0.35)
                && candidate.frame.distance(to: point) <= clusterRadius
        }
        snapshot.inPlaceClusterCandidates = clusterCandidates

        // 3. AutoLens cluster zoom (disabled by default)
        if autoLens.policy.isEnabled {
            let radius = max(calibrationMap.validationErrorPixels, autoLens.policy.clusterRadius)
            if autoLens.updateClosed(gazePoint: point, candidates: targets, radius: radius, at: now) {
                setZoom(true)
                autoLensOpened = true
                snapshot.targetsAreVisible = true
                snapshot.statusMessage = "Magnifying — look at a row and say \"click\""
                updateLensSelection(for: point, confidence: confidence)
                publish(force: true)
                return
            }
        }

        let selection = resolver.resolve(
            gazePoint: point,
            candidates: targets,
            screenSize: screenSize,
            gazeConfidence: confidence
        )

        let outcome = stabilizer.update(selection: selection, at: now)
        apply(outcome)
    }

    private func updateLensSelection(for point: LyraPoint, confidence: Double) {
        lensLayout = lens.layout(
            candidates: targets,
            gazePoint: point,
            screenSize: screenSize,
            limit: zoomLimit
        )
        snapshot.lens = lensLayout

        guard let entry = lens.row(at: point, in: lensLayout) else {
            snapshot.selection = nil
            snapshot.dwellProgress = nil
            return
        }

        let selection = TargetSelection(
            candidate: entry.candidate,
            distance: entry.rowFrame.distance(to: point),
            confidence: max(confidence, 0.75)
        )
        apply(stabilizer.update(selection: selection, at: Date().timeIntervalSince1970))
    }

    private func apply(_ outcome: TargetStabilizer.Outcome) {
        switch outcome {
        case .none:
            snapshot.selection = nil
            snapshot.dwellProgress = nil
        case .pending(let selection, let progress):
            snapshot.selection = selection
            snapshot.dwellProgress = progress
        case .committed(let candidate):
            snapshot.selection = TargetSelection(
                candidate: candidate,
                distance: 0,
                confidence: 1.0
            )
            snapshot.committedTarget = candidate
            snapshot.dwellProgress = nil
        }
    }

    // MARK: - Target sweeping

    /// Refreshes the target list on a cadence.
    ///
    /// Walking an accessibility tree is orders of magnitude more expensive than a camera
    /// frame, so this deliberately runs well below frame rate. Anything faster burns CPU
    /// for no benefit: controls do not move sixty times a second.
    private func startTargetSweeping() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshTargets()
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
    }

    /// Forces an immediate target rescan. Called after an action, since the screen has
    /// usually changed and a stale target list is how you click the wrong thing twice.
    public func refreshTargetsNow() async {
        await refreshTargets()
    }

    private func refreshTargets() async {
        let captured = await targetProvider.snapshotTargets()
        targets = captured.candidates
        snapshot.targetCount = captured.candidates.count

        // A committed target that no longer exists must not remain committed.
        if let committed = snapshot.committedTarget,
           !captured.candidates.contains(where: { $0.id == committed.id }) {
            snapshot.committedTarget = nil
            snapshot.selection = nil
            stabilizer.reset()
        }
        publish()
    }

    // MARK: - Speech pipeline

    private func listenToSpeech() {
        let stream = speechProvider.transcriptStream
        speechTask = Task { [weak self] in
            guard let self else { return }
            for await transcript in stream {
                if Task.isCancelled { break }
                await self.handle(transcript: transcript)
            }
        }
    }

    func handle(transcript: Transcript) {
        snapshot.lastTranscript = transcript.text

        // Partial results are shown but never acted on. The recogniser revises them as
        // it hears more, so "click" in a partial result may still become "click the
        // other one" — executing on partials is how a system clicks twice.
        guard transcript.isFinal else {
            publish()
            return
        }

        let normalized = CommandParser.normalize(transcript.text)
        guard !normalized.isEmpty else { publish(); return }

        // Some recognisers re-deliver an identical final result. Act once.
        if normalized == lastFinalTranscript, Date().timeIntervalSince(lastExecutedAt) < 1.5 {
            return
        }
        lastFinalTranscript = normalized

        let command = CommandParser.parse(transcript.text)
        snapshot.lastCommand = command
        Task { await self.execute(command) }
    }

    /// Direct command entry point, used by the UI's own buttons and by tests.
    public func submit(command: LyraCommand) async {
        snapshot.lastCommand = command
        await execute(command)
    }

    // MARK: - Execution

    func execute(_ command: LyraCommand) async {
        // 1. Confirmation round-trip. A pending high-risk command consumes the next
        //    yes/no and nothing else, so a stray word cannot slip past the gate.
        if let pending = pendingConfirmation {
            pendingConfirmation = nil
            switch command {
            case .confirm:
                snapshot.statusMessage = "Confirmed"
                await perform(pending)
                return
            case .deny, .cancel:
                snapshot.statusMessage = "Cancelled"
                publish(force: true)
                return
            default:
                snapshot.statusMessage = "Waiting for yes or no"
                publish(force: true)
                return
            }
        }

        switch command {
        case .startTracking:
            snapshot.isSelectionModeActive = true
            snapshot.statusMessage = "Selection on — look at a control and say \"click\""
            publish(force: true)

        case .stopTracking:
            snapshot.isSelectionModeActive = false
            snapshot.selection = nil
            snapshot.committedTarget = nil
            snapshot.dwellProgress = nil
            snapshot.contextualHighlight = nil
            snapshot.inPlaceClusterCandidates = []
            snapshot.statusMessage = "Selection off"
            stabilizer.reset()
            publish(force: true)

        case .cancel:
            snapshot.selection = nil
            snapshot.committedTarget = nil
            snapshot.dwellProgress = nil
            snapshot.contextualHighlight = nil
            snapshot.inPlaceClusterCandidates = []
            if zoomVisible { setZoom(false) }
            snapshot.statusMessage = "Selection cleared"
            stabilizer.reset()
            publish(force: true)

        case .nextTarget, .previousTarget:
            cycleSelection(forward: command == .nextTarget)

        case .showTargets:
            setZoom(true)
            snapshot.targetsAreVisible = true
            snapshot.statusMessage = "Showing \(min(targets.count, zoomLimit ?? lens.maximumRows)) nearby targets"
            publish(force: true)

        case .hideTargets:
            setZoom(false)
            snapshot.targetsAreVisible = false
            snapshot.statusMessage = "Targets hidden"
            publish(force: true)

        case .zoomIn:
            setZoom(true)
            zoomLimit = min((zoomLimit ?? lens.maximumRows) + 1, lens.maximumRows + 3)
            snapshot.isZoomed = true
            snapshot.statusMessage = "Lens: \(zoomLimit ?? lens.maximumRows) rows"
            publish(force: true)

        case .zoomOut:
            let next = (zoomLimit ?? lens.maximumRows) - 1
            if next <= 1 {
                setZoom(false)
                snapshot.statusMessage = "Lens closed"
            } else {
                zoomLimit = next
                snapshot.statusMessage = "Lens: \(next) rows"
            }
            publish(force: true)

        case .activate, .doubleClick, .rightClick, .undo:
            await activate(command)

        case .confirm, .deny:
            snapshot.statusMessage = "Nothing to confirm"
            publish(force: true)

        case .unrecognized:
            publish()
        }
    }

    /// Runs the risk gate and then performs the action.
    private func activate(_ command: LyraCommand) async {
        guard let target = snapshot.committedTarget ?? snapshot.selection?.candidate else {
            snapshot.statusMessage = "Nothing selected — look at something first"
            publish(force: true)
            return
        }

        // The resolver deliberately reports non-actionable elements so the interface can
        // say "you are looking at the sidebar". That contract only holds if acting on one
        // is refused here — otherwise the coordinate fallback in `invoke` cheerfully
        // clicks the middle of a container the resolver just said was not clickable.
        guard target.isActionable else {
            snapshot.statusMessage = "“\(target.displayName)” cannot be clicked — say \"next\" for the nearest control"
            publish(force: true)
            return
        }

        if riskPolicy.requiresConfirmation(command, on: target) {
            pendingConfirmation = command
            snapshot.statusMessage = "Say \"yes\" to \(verb(for: command)) \"\(target.displayName)\""
            publish(force: true)
            return
        }

        await perform(command, on: target)
    }

    private func perform(_ command: LyraCommand, on target: TargetCandidate? = nil) async {
        guard let target = target ?? snapshot.committedTarget ?? snapshot.selection?.candidate else {
            return
        }

        // Freshness gate. Acting on a target list captured a while ago risks clicking
        // whatever has since occupied that position.
        if !riskPolicy.allowsStaleTarget(command), isStale(target) {
            await refreshTargets()
            snapshot.statusMessage = "Screen changed — look again"
            publish(force: true)
            return
        }

        let didAct = await invoke(command, on: target)
        if didAct && (command == .activate || command == .doubleClick) {
            let centre = LyraPoint(x: target.frame.midX, y: target.frame.midY)
            let normX = centre.x / max(screenSize.width, 1.0)
            let normY = centre.y / max(screenSize.height, 1.0)
            registerPassiveClick(atNormalized: (x: normX, y: normY))
        }

        // The screen almost always changed as a result, so the cached list is stale.
        await refreshTargets()
        snapshot.statusMessage = didAct
            ? "\(verb(for: command).capitalized) “\(target.displayName)”"
            : "Could not \(verb(for: command)) “\(target.displayName)”"
        publish(force: true)
    }

    /// Attempts the semantic action first, then falls back to a coordinate click.
    ///
    /// The fallback is what makes Stage Manager thumbnails, canvas content and other
    /// accessibility-invisible surfaces reachable. It is genuinely less safe — a
    /// coordinate click goes wherever the pointer frame says, with no verification that
    /// the intended control is still there — so it is logged and reported rather than
    /// done silently.
    private func invoke(_ command: LyraCommand, on target: TargetCandidate) async -> Bool {
        let centre = LyraPoint(x: target.frame.midX, y: target.frame.midY)

        switch command {
        case .activate, .undo:
            if let action = target.action, target.source == .accessibility {
                do {
                    await refreshTargets()
                    guard let live = targets.first(where: { $0.id == target.id }) else {
                        return await coordinateClick(centre, button: .left)
                    }
                    try await targetProvider.perform(action: action, on: TargetSnapshot(
                        candidates: [live],
                        screenSize: screenSize
                    ))
                    return true
                } catch {
                    snapshot.errorMessage = error.localizedDescription
                }
            }
            return await coordinateClick(centre, button: .left)

        case .doubleClick:
            do {
                try await inputController.doubleClick(atScreenPoint: (Double(centre.x), Double(centre.y)))
                return true
            } catch {
                snapshot.errorMessage = error.localizedDescription
                return false
            }

        case .rightClick:
            return await coordinateClick(centre, button: .right)

        default:
            return false
        }
    }

    private func coordinateClick(_ point: LyraPoint, button: MouseButton) async -> Bool {
        do {
            try await inputController.click(
                atScreenPoint: (Double(point.x), Double(point.y)),
                button: button
            )
            return true
        } catch {
            snapshot.errorMessage = error.localizedDescription
            return false
        }
    }

    private func isStale(_ target: TargetCandidate) -> Bool {
        !targets.contains(where: { $0.id == target.id })
    }

    /// Moves the selection to the next or previous candidate in the current list.
    ///
    /// This is the escape hatch for the fundamental limitation of gaze selection:
    /// sometimes the user looks at the right thing and the system picks the wrong one.
    /// Rather than fight for a few more points of accuracy, give them a way to correct
    /// it with one word.
    private func cycleSelection(forward: Bool) {
        guard !targets.isEmpty else {
            snapshot.statusMessage = "No targets found"
            publish(force: true)
            return
        }

        let anchor = snapshot.gazePoint ?? LyraPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        let ordered = targets
            .filter(\.isActionable)
            .sorted { lhs, rhs in
                let lhsDistance = lhs.frame.distance(to: anchor)
                let rhsDistance = rhs.frame.distance(to: anchor)
                if abs(lhsDistance - rhsDistance) > 1.0 { return lhsDistance < rhsDistance }
                return lhs.id < rhs.id
            }

        guard !ordered.isEmpty else {
            snapshot.statusMessage = "No actionable targets nearby"
            publish(force: true)
            return
        }

        let currentIndex = ordered.firstIndex { $0.id == snapshot.committedTarget?.id }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = forward
                ? (currentIndex + 1) % ordered.count
                : (currentIndex - 1 + ordered.count) % ordered.count
        } else {
            nextIndex = 0
        }

        let candidate = ordered[nextIndex]
        snapshot.committedTarget = candidate
        snapshot.selection = TargetSelection(candidate: candidate, distance: 0, confidence: 1.0)
        snapshot.statusMessage = "Selected “\(candidate.displayName)” (\(nextIndex + 1) of \(ordered.count))"

        // Keep the stabiliser in step, so the next gaze frame does not immediately
        // revert the manual choice.
        stabilizer.reset()
        publish(force: true)
    }

    private func setZoom(_ visible: Bool) {
        zoomVisible = visible
        snapshot.isZoomed = visible
        autoLensOpened = false
        if !visible {
            zoomLimit = nil
            lensLayout = .empty
            snapshot.lens = .empty
            snapshot.targetsAreVisible = false
            // Stamps the cooldown for every close path — a row was activated, the user
            // said "hide targets", selection was switched off. Without it the gaze drifts
            // back towards the cluster, the lens reopens, and the user is stuck in a loop
            // with no way to say "no, I meant to close that".
            autoLens.close(at: Date().timeIntervalSince1970)
        }
        stabilizer.reset()
    }

    /// Turns the automatic lens on or off. Off leaves the explicit "zoom" command working.
    public func setAutoLensEnabled(_ enabled: Bool) {
        autoLens.policy.isEnabled = enabled
        if !enabled, autoLensOpened { setZoom(false) }
        snapshot.statusMessage = enabled
            ? "Auto-magnify on — the lens opens when you look at small controls"
            : "Auto-magnify off"
        publish(force: true)
    }

    /// Turns contextual region highlighting on or off.
    public func setContextualHighlightingEnabled(_ enabled: Bool) {
        self.contextualHighlightingEnabled = enabled
        if !enabled {
            snapshot.contextualHighlight = nil
        }
        publish(force: true)
    }

    /// The current lens layout, for the overlay to render.
    public func currentLensLayout() -> TargetLens.Layout { lensLayout }

    public func lensLayout(for gazePoint: LyraPoint) -> TargetLens.Layout {
        lens.layout(candidates: targets, gazePoint: gazePoint, screenSize: screenSize, limit: zoomLimit)
    }

    public func setZoomVisible(_ visible: Bool) {
        setZoom(visible)
        publish(force: true)
    }

    public func setLensLimit(_ limit: Int?) {
        zoomLimit = limit
        publish(force: true)
    }

    private func verb(for command: LyraCommand) -> String {
        switch command {
        case .activate: return "click"
        case .doubleClick: return "double click"
        case .rightClick: return "right click"
        case .undo: return "undo"
        default: return "activate"
        }
    }

    // MARK: - Publishing

    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishAt) >= (1.0 / 30.0) else { return }
        lastPublishAt = now
        snapshotContinuation?.yield(snapshot)
    }
}
