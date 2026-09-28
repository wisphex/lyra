import AppKit
import SwiftUI

/// Custom borderless window that can become key and handle ESC key to close
final class FullscreenCalibrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            OverlayWindowManager.shared.closeCalibrationWindow()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
public final class OverlayWindowManager {
    public static let shared = OverlayWindowManager()

    private var calibrationWindow: NSWindow?
    private var indicatorWindow: NSWindow?

    private init() {}

    /// The screen every overlay is drawn against.
    ///
    /// ponytail: single display, `NSScreen.main`. Multi-display needs per-screen overlay
    /// windows and gaze coordinates translated into the target screen's space; add when
    /// someone actually runs Lyra across two monitors.
    private var targetScreen: NSScreen? { NSScreen.main }

    // MARK: - Fullscreen Calibration Window

    public func showCalibrationWindow(viewModel: AppViewModel) {
        guard let screen = targetScreen else { return }

        closeCalibrationWindow()

        let window = FullscreenCalibrationWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(
            rootView: CalibrationOverlayView(viewModel: viewModel)
        )
        if #available(macOS 13.0, *) {
            hostingController.safeAreaRegions = []
        }
        window.contentViewController = hostingController

        // The size has to be stated *after* the hosting controller is installed.
        //
        // Installing a content view controller makes AppKit resize the window to the
        // controller's fitting size, and this root view is a `GeometryReader`, which has
        // no intrinsic size. The window came out 0x0 in the bottom-left corner: created,
        // ordered front, alpha 1.0, and completely invisible. Nothing about the code
        // looked wrong — only the window list showed it, as `1470x956` became `0x0`.
        //
        // Hide existing app windows (like the dashboard) during calibration so there is zero overlap
        NSApp.windows.forEach { otherWindow in
            if otherWindow != calibrationWindow && otherWindow != indicatorWindow {
                otherWindow.orderOut(nil)
            }
        }

        window.setFrame(screen.frame, display: true)

        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = false

        self.calibrationWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    public func closeCalibrationWindow() {
        calibrationWindow?.orderOut(nil)
        calibrationWindow?.close()
        calibrationWindow = nil

        // Restore dashboard window
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window != indicatorWindow {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    // MARK: - Gaze Indicator Overlay Window

    public func setIndicatorVisible(_ visible: Bool, viewModel: AppViewModel) {
        if visible {
            showIndicatorWindow(viewModel: viewModel)
        } else {
            closeIndicatorWindow()
        }
    }

    private func showIndicatorWindow(viewModel: AppViewModel) {
        if let window = indicatorWindow {
            guard let screen = targetScreen else { return }
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return
        }

        guard let screen = targetScreen else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(
            rootView: GazeIndicatorOverlay(viewModel: viewModel)
        )
        if #available(macOS 13.0, *) {
            hostingController.safeAreaRegions = []
        }
        window.contentViewController = hostingController

        // Same reason as `showCalibrationWindow`, and the same silent failure: without
        // this the window collapsed to the size of the dot it draws (66x73), so the
        // indicator could only ever appear near the bottom-left corner — the one place
        // its `.position(point)` happened to be inside the window's bounds.
        window.setFrame(screen.frame, display: true)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.orderFrontRegardless()

        self.indicatorWindow = window
    }

    /// Re-anchors the indicator overlay window to the active screen frame.
    public func updateIndicatorFrame() {
        guard let screen = targetScreen, let window = indicatorWindow else { return }
        window.setFrame(screen.frame, display: true)
    }

    private func closeIndicatorWindow() {
        indicatorWindow?.orderOut(nil)
        indicatorWindow?.close()
        indicatorWindow = nil
    }
}
