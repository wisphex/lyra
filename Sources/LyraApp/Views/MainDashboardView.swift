import SwiftUI
import LyraCore

/// Main control window: Emil Kowalski / Apple-grade minimalist macOS dashboard.
///
/// Principles:
/// - Monochromatic zinc/graphite/white palette with zero garish colors.
/// - Hairline 0.5pt borders (`Color.white.opacity(0.08)`).
/// - Continuous squircle radii (`style: .continuous`).
/// - SF Pro typography with tabular figures.
/// - Tactile spring animations.
struct MainDashboardView: View {
    @ObservedObject var viewModel: AppViewModel

    private var snapshot: LyraSnapshot { viewModel.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerBar
                primaryActionsBar
                settingsGrid
                telemetrySection
                permissionsBar
                footerNotes
            }
            .padding(24)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea())
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 16) {
            // App Branding & State Icon
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(statusColor.opacity(0.3), lineWidth: 0.5)
                        )
                    Image(systemName: statusSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Lyra Eye Control")
                            .font(.system(size: 16, weight: .semibold, design: .default))
                            .foregroundStyle(.white)
                        Text("v0.1")
                            .font(.system(size: 11, weight: .medium, design: .default).monospacedDigit())
                            .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.52))
                    }
                    Text(snapshot.statusMessage)
                        .font(.system(size: 11, design: .default))
                        .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Precision Badge Pill
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                if viewModel.isCalibrated {
                    Text(String(format: "±%.0f px", viewModel.calibrationMap.validationErrorPixels))
                        .font(.system(size: 12, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundStyle(.white)
                } else {
                    Text("Uncalibrated")
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.25))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
    }

    private var statusColor: Color {
        switch snapshot.trackingState {
        case .tracking:
            return Color(red: 0.22, green: 0.78, blue: 0.48)
        case .calibrating:
            return Color(red: 0.75, green: 0.75, blue: 0.78)
        case .blinking, .uncalibrated:
            return Color(red: 0.95, green: 0.65, blue: 0.25)
        case .faceLost, .error:
            return Color(red: 0.92, green: 0.35, blue: 0.35)
        case .idle:
            return Color(red: 0.5, green: 0.5, blue: 0.52)
        }
    }

    private var statusSymbol: String {
        switch snapshot.trackingState {
        case .tracking: return "eye"
        case .calibrating: return "scope"
        case .blinking: return "eye.slash"
        case .faceLost: return "person.fill.questionmark"
        case .uncalibrated: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .idle: return "pause"
        }
    }

    // MARK: - Action Buttons

    private var primaryActionsBar: some View {
        HStack(spacing: 12) {
            // Start / Stop Toggle
            Button(action: { viewModel.toggleEngine() }) {
                HStack(spacing: 8) {
                    Image(systemName: snapshot.isEngineRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(snapshot.isEngineRunning ? "Stop Eye Tracking" : "Start Eye Tracking")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(ZincProminentButtonStyle())
            .disabled(viewModel.isCalibrating)

            Button(action: { viewModel.startCalibration() }) {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                        .font(.system(size: 12))
                    Text(viewModel.isCalibrated ? "Recalibrate" : "Calibrate")
                        .font(.system(size: 13, weight: .medium, design: .default))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
            .buttonStyle(ZincSecondaryButtonStyle())
            .disabled(viewModel.isCalibrating)
        }
    }

    // MARK: - Settings Grid

    private var settingsGrid: some View {
        VStack(spacing: 12) {
            HStack {
                settingToggleRow(
                    title: "Context Highlights",
                    subtitle: "Menu bar, Dock, Stage Manager",
                    isOn: $viewModel.contextualHighlightingEnabled
                )
                Divider()
                    .frame(height: 32)
                    .background(Color.white.opacity(0.06))
                settingToggleRow(
                    title: "Gaze Indicator",
                    subtitle: "On-screen reticle overlay",
                    isOn: $viewModel.showGazeOverlay
                )
            }

            Divider()
                .background(Color.white.opacity(0.06))

            HStack {
                settingToggleRow(
                    title: "Sync System Mouse",
                    subtitle: "Warp macOS cursor to gaze",
                    isOn: $viewModel.syncSystemCursor
                )
                Divider()
                    .frame(height: 32)
                    .background(Color.white.opacity(0.06))
                settingToggleRow(
                    title: "AutoLens Magnify",
                    subtitle: "Popup zoom list (optional)",
                    isOn: $viewModel.autoLensEnabled
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func settingToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.90))
                Text(subtitle)
                    .font(.system(size: 10, design: .default))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(title)
        }
    }

    // MARK: - Telemetry & Vision Diagnostics

    private var telemetrySection: some View {
        VStack(spacing: 12) {
            if let preview = viewModel.previewImage {
                HStack(spacing: 16) {
                    // Preview Frame
                    Image(decorative: preview, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 140, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )

                    // Vision Telemetry Specs
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(snapshot.trackingState == .tracking ? Color(red: 0.22, green: 0.78, blue: 0.48) : Color(red: 0.95, green: 0.65, blue: 0.25))
                                .frame(width: 6, height: 6)
                            Text("Facial Geometry Tracking")
                                .font(.system(size: 12, weight: .semibold, design: .default))
                                .foregroundStyle(.white)
                        }

                        Text("WebGazer polynomial mapping from ocular features to screen coordinates.")
                            .font(.system(size: 11, design: .default))
                            .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
                            .lineLimit(2)

                        HStack(spacing: 12) {
                            Text("\(snapshot.targetCount) targets active")
                                .font(.system(size: 11, weight: .medium, design: .default).monospacedDigit())
                                .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))

                            if snapshot.isZoomed {
                                Text("AutoLens Magnified")
                                    .font(.system(size: 10, weight: .medium, design: .default))
                                    .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.48))
                            }
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }

            // Voice & Selection Telemetry Row
            HStack(spacing: 16) {
                // Voice Status
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.62))
                    Text(snapshot.lastTranscript.isEmpty ? "Voice ready" : "\u{201C}\(snapshot.lastTranscript)\u{201D}")
                        .font(.system(size: 12, design: .default))
                        .foregroundStyle(Color(red: 0.8, green: 0.8, blue: 0.82))
                        .lineLimit(1)
                }

                Spacer()

                if let command = snapshot.lastCommand {
                    Text(commandName(command))
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }

                if let selection = snapshot.selection {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                            .font(.system(size: 10))
                        Text(selection.candidate.displayName)
                            .font(.system(size: 11, weight: .medium, design: .default))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.48))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Permissions Row

    private var permissionsBar: some View {
        HStack(spacing: 8) {
            permissionPill("Camera", viewModel.cameraGranted)
            permissionPill("Mic", viewModel.microphoneGranted)
            permissionPill("Speech", viewModel.speechGranted)
            permissionPill("Accessibility", viewModel.accessibilityGranted)

            Spacer()

            if !viewModel.accessibilityGranted || !viewModel.cameraGranted {
                Button("Grant Permissions") {
                    viewModel.requestPermissions()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.25))
            }
        }
    }

    private func permissionPill(_ name: String, _ granted: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(granted ? Color(red: 0.22, green: 0.78, blue: 0.48) : Color.white.opacity(0.2))
                .frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 11, design: .default))
                .foregroundStyle(granted ? Color(red: 0.88, green: 0.88, blue: 0.90) : Color(red: 0.5, green: 0.5, blue: 0.52))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Footer

    private var footerNotes: some View {
        HStack {
            Text("Shortcuts: ESC to exit • Space to trigger")
                .font(.system(size: 11, design: .default))
                .foregroundStyle(Color(red: 0.62, green: 0.62, blue: 0.65))

            Spacer()

            if viewModel.isCalibrated {
                Button("Reset Calibration") {
                    viewModel.resetCalibration()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .default))
                .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
            }
        }
        .padding(.top, 4)
    }

    private func commandName(_ command: LyraCommand) -> String {
        switch command {
        case .startTracking: return "start"
        case .stopTracking: return "stop"
        case .activate: return "click"
        case .doubleClick: return "double click"
        case .rightClick: return "right click"
        case .nextTarget: return "next"
        case .previousTarget: return "previous"
        case .showTargets: return "show targets"
        case .hideTargets: return "hide targets"
        case .zoomIn: return "zoom in"
        case .zoomOut: return "zoom out"
        case .undo: return "undo"
        case .cancel: return "cancel"
        case .confirm: return "confirm"
        case .deny: return "deny"
        case .unrecognized(let text): return "heard: \(text.prefix(15))"
        }
    }
}

// MARK: - Minimalist Zinc Button Styles

private struct ZincProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .default))
            .foregroundStyle(Color.black)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct ZincSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .default))
            .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.90))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
