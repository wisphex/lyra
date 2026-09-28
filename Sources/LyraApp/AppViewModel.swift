import SwiftUI
import Combine
import LyraCore
import LyraGaze
import LyraSpeech
import LyraInput
import LyraAccessibility
import AVFoundation
import Speech
import AppKit

/// Owns the platform objects and mirrors the coordinator's state into SwiftUI.
///
/// Deliberately thin. Everything the UI shows is either a field of `LyraSnapshot` or a
/// property of the calibration run; there is no second copy of engine state to drift out
/// of sync with the coordinator. The previous version kept `isCursorActive`,
/// `calibrationAccuracy` and `meanPixelError` as separate published values updated from
/// callbacks, which is how the interface ended up able to show a stale gaze dot next to
/// a fresh selection.
@MainActor
public final class AppViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var snapshot = LyraSnapshot()
    @Published public private(set) var previewImage: CGImage?

    public enum CalibrationMode: String, CaseIterable, Identifiable, Sendable {
        case macroZones5
        case webGazer9
        case adaptive
        case click

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .macroZones5: return "Macro Zones (Menu Bar • Stage Manager • Dock • Windows)"
            case .webGazer9: return "WebGazer 9-Point (3×3 Grid • 45 Clicks)"
            case .adaptive: return "3-Stage Smart (Corners → Ball → Polish)"
            case .click: return "Click Dots (16 dots, 64 clicks)"
            }
        }
    }

    @Published public var calibrationMode: CalibrationMode = .macroZones5
    @Published public private(set) var calibrationStage: CalibrationStage = .idle
    @Published public private(set) var webGazerProgress: WebGazerCalibration.Progress?
    @Published public private(set) var calibrationProgress: ClickCalibration.Progress?
    @Published public private(set) var adaptiveProgress: AdaptiveCalibration.Progress?
    @Published public private(set) var calibrationError: String?
    @Published public private(set) var calibrationResult: CalibrationResult?

    /// Where the user is in the calibration flow.
    ///
    /// Calibration used to have no first act and no last one: pressing Calibrate threw the
    /// user straight at a dot with no warning, and when the run ended the surface closed
    /// itself with the outcome reported as a line of status text on a window they were no
    /// longer looking at. Both ends of a task you cannot see the edges of read as a
    /// malfunction.
    public enum CalibrationStage: Equatable {
        case idle
        /// Explaining what is about to happen, before anything starts.
        case intro
        case running
        /// Run complete; the model is being fitted.
        case fitting
        /// Showing the outcome and how good it is.
        case finished
    }

    public struct CalibrationResult: Equatable {
        public let errorPixels: Double
        public let accuracyPercentage: Double
        public let usedPoints: Int
        public let totalPoints: Int
        /// Clicks the run refused. Either they landed away from the dot, or there was no
        /// trustworthy eye measurement behind them to label with.
        public let abandonedPoints: Int

        /// Whether the fit came out tight enough to point at things with. Roughly the
        /// height of a line of text — below this, gaze lands where the user intended; far
        /// above it, the lens is doing all the work.
        public var isPrecise: Bool { errorPixels <= 70 || accuracyPercentage >= 80.0 }

        public init(
            errorPixels: Double,
            accuracyPercentage: Double = 92.0,
            usedPoints: Int,
            totalPoints: Int,
            abandonedPoints: Int
        ) {
            self.errorPixels = errorPixels
            self.accuracyPercentage = accuracyPercentage
            self.usedPoints = usedPoints
            self.totalPoints = totalPoints
            self.abandonedPoints = abandonedPoints
        }
    }

    /// True while a calibration surface is up and the engine is not available to selection.
    public var isCalibrating: Bool {
        calibrationStage == .intro || calibrationStage == .running || calibrationStage == .fitting
    }

    /// What the intro screen is offering.
    public var calibrationPointCount: Int {
        switch calibrationMode {
        case .macroZones5: return CalibrationPattern.macro5.points.count
        case .webGazer9: return 9
        case .adaptive: return 5
        case .click: return CalibrationPattern.click.points.count
        }
    }

    /// How many clicks the offered run asks for in total.
    public var calibrationClickCount: Int {
        switch calibrationMode {
        case .macroZones5: return calibrationPointCount * 5
        case .webGazer9: return 45
        case .adaptive: return 5
        case .click: return calibrationPointCount * Self.clicksPerPoint
        }
    }

    static let clicksPerPoint = 4

    @Published public private(set) var cameraGranted = false
    @Published public private(set) var microphoneGranted = false
    @Published public private(set) var speechGranted = false
    @Published public private(set) var accessibilityGranted = false

    @Published public var showGazeOverlay = true {
        didSet { overlays.setIndicatorVisible(showGazeOverlay, viewModel: self) }
    }

    /// Whether the lens opens by itself on a cluster of small controls. Disabled by default
    /// in favor of clean in-place contextual region highlighting.
    @Published public var autoLensEnabled = false {
        didSet { Task { await coordinator.setAutoLensEnabled(autoLensEnabled) } }
    }

    /// Whether in-place contextual region highlighting (menu bar, status icons, Stage Manager, Dock) is enabled.
    @Published public var contextualHighlightingEnabled = true {
        didSet {
            UserDefaults.standard.set(contextualHighlightingEnabled, forKey: "com.lyra.contextualHighlightingEnabled")
            Task { await coordinator.setContextualHighlightingEnabled(contextualHighlightingEnabled) }
        }
    }

    /// Steering mode: pure eye gaze tracking (default and standard).
    @Published public var steeringMode: NoseFineTuneController.Mode = .gazeOnly {
        didSet {
            UserDefaults.standard.set(steeringMode.rawValue, forKey: "com.lyra.steeringMode")
            Task { await coordinator.setSteeringMode(steeringMode) }
        }
    }

    /// Whether the macOS system cursor is warped to follow the tracking point.
    @Published public var syncSystemCursor: Bool = false {
        didSet {
            UserDefaults.standard.set(syncSystemCursor, forKey: "com.lyra.syncSystemCursor")
            Task { await coordinator.setSyncSystemCursor(syncSystemCursor) }
        }
    }

    /// Continuous training from background clicks (disabled per design).
    @Published public var continuousTrainingEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(continuousTrainingEnabled, forKey: "com.lyra.continuousTrainingEnabled")
            Task { await coordinator.setContinuousTrainingEnabled(continuousTrainingEnabled) }
        }
    }

    public var noseFineTuneEnabled: Bool {
        get { steeringMode != .gazeOnly }
        set {
            if newValue && steeringMode == .gazeOnly {
                steeringMode = .noseOnly
            } else if !newValue {
                steeringMode = .gazeOnly
            }
        }
    }

    @Published public var noseSensitivity: Double = 2.0 {
        didSet {
            UserDefaults.standard.set(noseSensitivity, forKey: "com.lyra.noseSensitivity")
            Task { await coordinator.setNoseFineTune(enabled: steeringMode != .gazeOnly, sensitivity: noseSensitivity) }
        }
    }

    @Published public var invertNoseX: Bool = false {
        didSet {
            UserDefaults.standard.set(invertNoseX, forKey: "com.lyra.invertNoseX")
            Task { await coordinator.setNoseInversion(invertX: invertNoseX, invertY: invertNoseY) }
        }
    }

    @Published public var invertNoseY: Bool = false {
        didSet {
            UserDefaults.standard.set(invertNoseY, forKey: "com.lyra.invertNoseY")
            Task { await coordinator.setNoseInversion(invertX: invertNoseX, invertY: invertNoseY) }
        }
    }

    /// Whether Stage Manager's strip is on. Surfaced because "why can't I select the
    /// thumbnails" has exactly one answer when this is false.
    public var isStageManagerOn: Bool { StripScanner.isStageManagerEnabled }

    /// The map currently driving gaze. Kept here as a stored value rather than read back
    /// from the coordinator, whose state is actor-isolated and cannot be touched
    /// synchronously from a view body.
    @Published public private(set) var calibrationMap: CalibrationMap = .identity

    /// Set when a stored calibration was found but no longer applies — the display or
    /// camera changed underneath it. Surfaced rather than silently dropped, because the
    /// alternative is a user whose gaze is subtly wrong with no explanation.
    @Published public private(set) var calibrationInvalidReason: String?

    public var isCalibrated: Bool { calibrationMap.isCalibrated }

    /// Identifies the display and camera the setup currently consists of.
    ///
    /// This is what makes calibration follow the machine rather than being a one-off
    /// ritual: a map is only valid for the geometry it was measured in, and this is how
    /// that geometry is named.
    public var currentCalibrationContext: CalibrationMap.CalibrationContext {
        CalibrationMap.CalibrationContext(
            displayID: Self.mainDisplayID(),
            cameraID: gazeProvider.activeCameraID,
            screenSize: NSScreen.main.map {
                LyraSize(width: Double($0.frame.width), height: Double($0.frame.height))
            }
        )
    }

    /// `CGDirectDisplayID` of the screen Lyra is operating on.
    static func mainDisplayID() -> UInt32? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    // MARK: - Dependencies

    public let gazeProvider: VisionGazeProvider
    public let speechProvider: NativeSpeechProvider
    public let inputController: CGInputController
    public let targetProvider: MacTargetProvider
    public let coordinator: LyraCoordinator

    private let overlays = OverlayWindowManager.shared
    private let calibrationStorageKey = "com.lyra.calibrationMap"
    private var webGazerRun: WebGazerCalibration?
    private var clickRun: ClickCalibration?
    private var adaptiveRun: AdaptiveCalibration?
    private var calibrationTimer: AnyCancellable?
    private var snapshotTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var latestFeatures = GazeFeatures(
        pupilX: 0.5, pupilY: 0.5, yaw: 0, pitch: 0, roll: 0,
        faceX: 0.5, faceY: 0.5, iod: 0.31, faceWidth: 0.24,
        eyeOpenness: 1.0, confidence: 1.0
    )

    public init() {
        let gaze = VisionGazeProvider()
        let speech = NativeSpeechProvider()
        let input = CGInputController()
        let targets = MacTargetProvider()

        self.gazeProvider = gaze
        self.speechProvider = speech
        self.inputController = input
        self.targetProvider = targets
        self.coordinator = LyraCoordinator(
            gazeProvider: gaze,
            speechProvider: speech,
            targetProvider: targets,
            inputController: input
        )

        updateScreenSize()
        refreshPermissions()
        observeCoordinator()
        observeDisplayChanges()

        gazeProvider.onPreviewFrame = { [weak self] image in
            Task { @MainActor [weak self] in self?.previewImage = image }
        }

        self.steeringMode = .gazeOnly
        self.syncSystemCursor = UserDefaults.standard.bool(forKey: "com.lyra.syncSystemCursor")
        self.invertNoseX = false
        self.invertNoseY = false
        self.continuousTrainingEnabled = false
        self.autoLensEnabled = false
        self.contextualHighlightingEnabled = UserDefaults.standard.object(forKey: "com.lyra.contextualHighlightingEnabled") as? Bool ?? true
        Task { [sync = self.syncSystemCursor, contextHigh = self.contextualHighlightingEnabled] in
            await coordinator.setSteeringMode(.gazeOnly)
            await coordinator.setNoseFineTune(enabled: false, sensitivity: 2.0, invertX: false, invertY: false)
            await coordinator.setSyncSystemCursor(sync)
            await coordinator.setContinuousTrainingEnabled(false)
            await coordinator.setAutoLensEnabled(false)
            await coordinator.setContextualHighlightingEnabled(contextHigh)
        }

        // Passive click monitoring disabled per product requirements (eye-tracking only)
        Task { await restoreCalibration() }
    }

    private func setupPassiveClickMonitoring() {
        // Disabled: continuous background click monitoring removed to prevent noise.
    }

    private func handlePassiveSystemClick(screenPoint: NSPoint) {
        // No-op
    }

    // MARK: - Display changes

    /// Re-reads the screen and re-checks the calibration whenever the display setup moves.
    ///
    /// Resolution changes, a display being attached, the arrangement changing — all of
    /// them invalidate assumptions Lyra is holding: the screen size every gaze point is
    /// scaled by, and the validity of a map fitted under different geometry. Nothing
    /// announces this, so it has to be watched for.
    private func observeDisplayChanges() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDisplayChange() }
        }
    }

    private func handleDisplayChange() {
        updateScreenSize()
        overlays.updateIndicatorFrame()
        revalidateCalibration()
    }

    /// Drops the stored calibration if the setup it was fitted in is gone.
    ///
    /// Called on a display change and again once the camera has started, because which
    /// camera is in use is only knowable after that — a calibration made through an
    /// external webcam is meaningless once the machine is running on its built-in one.
    func revalidateCalibration() {
        guard calibrationMap.isCalibrated else { return }
        let context = currentCalibrationContext
        guard !calibrationMap.isUsable(with: context) else {
            calibrationInvalidReason = nil
            return
        }

        let changed = calibrationMap.context?.difference(from: context) ?? "a change in your setup"
        calibrationInvalidReason = "Your display setup changed (\(changed)), so the saved calibration no longer applies. Calibrate again."
        resetCalibration()
    }

    // MARK: - Coordinator observation

    private func observeCoordinator() {
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            await self.coordinator.setCalibrationUpdateObserver { [weak self] newMap in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.calibrationMap = newMap
                    self.persist(newMap)
                }
            }
            for await update in await self.coordinator.snapshots {
                guard !Task.isCancelled else { break }
                self.snapshot = update
            }
        }
    }

    public func updateScreenSize() {
        guard let screen = NSScreen.main else { return }
        let size = LyraSize(
            width: Double(screen.frame.width),
            height: Double(screen.frame.height)
        )
        targetProvider.setScreenSize(size)
        Task { await coordinator.setScreenSize(size) }
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityGranted = AccessibilityHelper.isAccessibilityTrusted
    }

    public func requestPermissions() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if !AccessibilityHelper.isAccessibilityTrusted {
                _ = AccessibilityHelper.requestAccessibilityPrompt()
            }
            refreshPermissions()
        }
    }

    // MARK: - Engine

    public func start() async {
        updateScreenSize()
        do {
            try await coordinator.start()
            // Only now is it known which camera is actually running, so this is the first
            // moment a stored calibration can be checked against it.
            revalidateCalibration()
            if showGazeOverlay {
                overlays.setIndicatorVisible(true, viewModel: self)
            }
        } catch {
            refreshPermissions()
        }
    }

    public func stop() async {
        await coordinator.stop()
        previewImage = nil
        overlays.setIndicatorVisible(false, viewModel: self)
    }

    public func toggleEngine() {
        Task {
            if snapshot.isEngineRunning { await stop() } else { await start() }
        }
    }

    // MARK: - Commands

    public func send(_ command: LyraCommand) {
        Task { await coordinator.submit(command: command) }
    }

    public func recenterNose() {
        Task { await coordinator.recenterNose() }
    }

    // MARK: - Calibration

    /// Opens the calibration surface on its explanation screen. Nothing is measured yet.
    public func startCalibration() {
        calibrationError = nil
        webGazerProgress = nil
        calibrationProgress = nil
        adaptiveProgress = nil
        calibrationResult = nil
        calibrationStage = .intro
        calibrationTimer?.cancel()
        calibrationTimer = nil
        webGazerRun = nil
        clickRun = nil
        adaptiveRun = nil
        overlays.showCalibrationWindow(viewModel: self)
    }

    /// Begins measuring, once the user has read what is about to happen and is ready.
    public func beginCalibration() {
        guard calibrationStage == .intro else { return }

        let observer: @Sendable (GazeFeatures) -> Void = { [weak self] features in
            Task { @MainActor [weak self] in self?.ingest(features) }
        }

        if calibrationMode == .macroZones5 || calibrationMode == .webGazer9 {
            let pattern = (calibrationMode == .macroZones5) ? CalibrationPattern.macro5 : CalibrationPattern.webGazer9
            let run = WebGazerCalibration(pattern: pattern, clicksPerPoint: 5, verificationDuration: 3.5)
            webGazerRun = run
            calibrationStage = .running
            webGazerProgress = run.progress

            Task { [weak self] in
                guard let self else { return }
                await start()
                guard await coordinator.currentSnapshot.isEngineRunning else {
                    calibrationError = "The camera did not start, so calibration cannot run. Check Camera permission, then try again."
                    webGazerRun = nil
                    calibrationStage = .intro
                    return
                }

                await coordinator.submit(command: .stopTracking)
                await coordinator.setFeatureObserver(observer)
                run.start()
                webGazerProgress = run.progress
            }
        } else if calibrationMode == .adaptive {
            let size = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
            let run = AdaptiveCalibration(
                screenWidth: Double(size.width),
                screenHeight: Double(size.height),
                context: currentCalibrationContext,
                refinementThresholdPixels: 60.0,
                pursuitDuration: 28.0,
                requireClick: true,
                latencyCompensation: 0.13
            )
            adaptiveRun = run
            calibrationStage = .running
            adaptiveProgress = run.progress()

            Task { [weak self] in
                guard let self else { return }
                await start()
                guard await coordinator.currentSnapshot.isEngineRunning else {
                    calibrationError = "The camera did not start, so calibration cannot run. Check Camera permission, then try again."
                    adaptiveRun = nil
                    calibrationStage = .intro
                    return
                }

                await coordinator.submit(command: .stopTracking)
                await coordinator.setFeatureObserver(observer)
                run.start()
                adaptiveProgress = run.progress()

                calibrationTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in
                        self?.tickAdaptive()
                    }
            }
        } else {
            let run = ClickCalibration(clicksPerPoint: Self.clicksPerPoint)
            clickRun = run
            calibrationStage = .running
            calibrationProgress = run.progress

            Task {
                await start()
                guard await coordinator.currentSnapshot.isEngineRunning else {
                    calibrationError = "The camera did not start, so calibration cannot run. Check Camera permission, then try again."
                    clickRun = nil
                    calibrationStage = .intro
                    return
                }

                await coordinator.submit(command: .stopTracking)
                await coordinator.setFeatureObserver(observer)
                run.start()
                calibrationProgress = run.progress
            }
        }
    }

    private func tickAdaptive() {
        guard calibrationStage == .running, let run = adaptiveRun else {
            calibrationTimer?.cancel()
            calibrationTimer = nil
            return
        }
        let prog = run.progress()
        self.adaptiveProgress = prog
        if prog.isFinished {
            calibrationTimer?.cancel()
            calibrationTimer = nil
            completeAdaptiveCalibration(with: run)
        }
    }

    /// Records a direct click on a WebGazer point dot by index.
    public func handleCalibrationClick(pointIndex: Int) {
        guard calibrationStage == .running else { return }
        if (calibrationMode == .macroZones5 || calibrationMode == .webGazer9), let run = webGazerRun {
            run.registerClick(pointIndex: pointIndex)
            webGazerProgress = run.progress
            if run.isAllPointsComplete {
                completeWebGazerCalibration(with: run)
            }
        }
    }

    /// Records a click on the calibration surface.
    public func handleCalibrationClick(atNormalized location: CGPoint) {
        guard calibrationStage == .running else { return }

        if (calibrationMode == .macroZones5 || calibrationMode == .webGazer9), let run = webGazerRun {
            let size = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
            run.registerClick(
                atNormalized: (x: Double(location.x), y: Double(location.y)),
                screenSize: LyraSize(
                    width: Double(size.width),
                    height: Double(size.height)
                )
            )
            webGazerProgress = run.progress
            if run.isAllPointsComplete {
                completeWebGazerCalibration(with: run)
            }
            return
        }

        if calibrationMode == .adaptive, let run = adaptiveRun {
            let handled = run.registerClick(atNormalized: (x: Double(location.x), y: Double(location.y)))
            if handled {
                tickAdaptive()
            }
            return
        }

        guard calibrationMode == .click, let run = clickRun else { return }

        run.registerClick(
            atNormalized: (x: Double(location.x), y: Double(location.y)),
            screenSize: LyraSize(
                width: Double(NSScreen.main?.frame.width ?? 1512),
                height: Double(NSScreen.main?.frame.height ?? 982)
            )
        )
        calibrationProgress = run.progress

        if run.isFinished {
            completeClickCalibration(with: run)
        }
    }

    private func ingest(_ features: GazeFeatures) {
        latestFeatures = features
        guard isCalibrating else { return }
        if calibrationMode == .macroZones5 || calibrationMode == .webGazer9 {
            webGazerRun?.observe(features: features)
        } else if calibrationMode == .adaptive {
            adaptiveRun?.observe(features: features)
        } else {
            clickRun?.observe(features: features)
        }
    }

    private func completeWebGazerCalibration(with run: WebGazerCalibration) {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        let context = currentCalibrationContext

        calibrationStage = .fitting
        Task { [weak self] in
            guard let self else { return }
            do {
                let map = try run.fit(
                    screenWidth: Double(size.width),
                    screenHeight: Double(size.height),
                    context: context
                )
                await coordinator.setCalibrationMap(map)
                await coordinator.setContinuousTrainingBaseSamples(run.samples)
                calibrationMap = map
                calibrationInvalidReason = nil
                persist(map)
                calibrationError = nil

                let score = run.computeCalibrationAccuracy(
                    screenWidth: Double(size.width),
                    screenHeight: Double(size.height)
                )

                calibrationResult = CalibrationResult(
                    errorPixels: score.errorPixels,
                    accuracyPercentage: score.accuracyPercentage,
                    usedPoints: run.samples.count,
                    totalPoints: run.requiredClicks,
                    abandonedPoints: run.rejectedClicks + run.droppedClicks
                )
                webGazerProgress = run.progress
                webGazerRun = nil
                calibrationStage = .finished
                refreshPermissions()
            } catch {
                calibrationError = error.localizedDescription
                webGazerRun = nil
                calibrationStage = .finished
            }
        }
    }

    private func completeAdaptiveCalibration(with run: AdaptiveCalibration) {
        Task {
            calibrationStage = .fitting
            await coordinator.setFeatureObserver(nil)

            if let map = run.finalMap {
                await coordinator.setCalibrationMap(map)
                calibrationMap = map
                calibrationInvalidReason = nil
                persist(map)
                calibrationError = nil
                calibrationResult = CalibrationResult(
                    errorPixels: map.validationErrorPixels,
                    usedPoints: map.pointCount,
                    totalPoints: 25,
                    abandonedPoints: 0
                )
            } else {
                calibrationError = "The calibration points could not be fitted into a gaze model."
            }

            adaptiveRun = nil
            calibrationStage = .finished
            refreshPermissions()
        }
    }

    private func completeClickCalibration(with run: ClickCalibration) {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        let context = currentCalibrationContext
        let samples = run.samples
        let refused = run.rejectedClicks + run.droppedClicks
        let totalClicks = run.totalClicks

        Task {
            calibrationStage = .fitting
            await coordinator.setFeatureObserver(nil)

            do {
                let map = try GazeCalibrator().calibrate(
                    samples: samples,
                    screenWidth: Double(size.width),
                    screenHeight: Double(size.height),
                    context: context
                )
                await coordinator.setCalibrationMap(map)
                calibrationMap = map
                calibrationInvalidReason = nil
                persist(map)
                calibrationError = nil
                writeDiagnosticsIfRequested(samples: samples, screen: size, errorPixels: map.validationErrorPixels)

                calibrationResult = CalibrationResult(
                    errorPixels: map.validationErrorPixels,
                    usedPoints: map.pointCount,
                    totalPoints: totalClicks,
                    abandonedPoints: refused
                )
            } catch {
                calibrationError = error.localizedDescription
            }

            clickRun = nil
            calibrationStage = .finished
            refreshPermissions()
        }
    }

    /// Abandons a run in progress, or closes the result screen.
    public func cancelCalibration() {
        closeCalibration()
    }

    /// Dismisses the calibration surface and returns the engine to normal use.
    public func closeCalibration() {
        calibrationStage = .idle
        calibrationTimer?.cancel()
        calibrationTimer = nil
        webGazerRun = nil
        clickRun = nil
        adaptiveRun = nil
        webGazerProgress = nil
        calibrationProgress = nil
        adaptiveProgress = nil
        overlays.closeCalibrationWindow()
        Task { await coordinator.setFeatureObserver(nil) }
    }

    /// Runs another calibration immediately.
    public func repeatCalibration() {
        closeCalibration()
        startCalibration()
    }

    public func resetCalibration() {
        UserDefaults.standard.removeObject(forKey: calibrationStorageKey)
        calibrationMap = .identity
        Task { await coordinator.setCalibrationMap(.identity) }
    }

    private func persist(_ map: CalibrationMap) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: calibrationStorageKey)
    }

    /// Writes a summary of the last run, but only when explicitly asked for.
    ///
    /// A bad calibration number cannot say whether the measurements carried no gaze
    /// signal or carried a noisy one, and those need opposite fixes. This exists to tell
    /// the two apart.
    ///
    /// Gated on an environment variable rather than always on, because it is a
    /// diagnostic and not a feature: gaze measurements should not be landing on disk as a
    /// side effect of using the app. It writes aggregate statistics — ranges, deviations,
    /// correlations — never the measurements themselves.
    private func writeDiagnosticsIfRequested(
        samples: [CalibrationSample],
        screen: CGSize,
        errorPixels: Double
    ) {
        guard ProcessInfo.processInfo.environment["LYRA_CALIBRATION_DIAGNOSTICS"] == "1" else { return }

        let summaries = CalibrationDiagnostics.summarise(samples)
        var report: [String: Any] = [
            "screenWidth": Double(screen.width),
            "screenHeight": Double(screen.height),
            "errorPixels": errorPixels,
            "sampleCount": samples.count,
            "patternPoints": CalibrationPattern.click.points.count,
            "features": summaries.map { summary -> [String: Any] in
                [
                    "name": summary.name,
                    "min": summary.minimum,
                    "max": summary.maximum,
                    "range": summary.range,
                    "std": summary.standardDeviation,
                    "correlationWithX": summary.correlationWithX,
                    "correlationWithY": summary.correlationWithY
                ]
            }
        ]
        report["frameCounts"] = samples.map(\.frameCount)
        report["featureSpreads"] = samples.map(\.featureSpread)

        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/lyra-calibration-diagnostics.json"))
    }

    private func restoreCalibration() async {
        guard let data = UserDefaults.standard.data(forKey: calibrationStorageKey),
              let map = try? JSONDecoder().decode(CalibrationMap.self, from: data),
              map.schemaVersion == GazeFeatures.schemaVersion else {
            return
        }

        // The camera is only known once it is running, and the display only matters when
        // a map was fitted against another one, so the check is redone at start rather
        // than trusted from launch.
        let context = currentCalibrationContext
        guard map.isUsable(with: context) else {
            let changed = map.context?.difference(from: context) ?? "a change in your setup"
            calibrationInvalidReason = "Your display setup changed (\(changed)), so the saved calibration no longer applies. Calibrate again."
            resetCalibration()
            return
        }

        await coordinator.setCalibrationMap(map)
        calibrationMap = map
    }
}
