import SwiftUI
import LyraCore

/// The transparent, click-through overlay drawn over all windows:
/// - Sleek, accurate live gaze cursor indicator for precision testing.
/// - In-place contextual selection highlights (Top Right status items, Top Left menu items,
///   Stage Manager active window thumbnails, and Dock items).
/// - In-place subtle hairline squircle borders for button clusters inside active application windows.
/// - Intrusive full zoom-in overlay completely disabled by default.
///
/// Built according to Emil Kowalski / Apple design principles:
/// - Zero garish saturations, clean zinc/monochrome palette.
/// - Hairline borders (0.5pt to 0.75pt, `Color.white.opacity(0.18)`).
/// - Continuous squircle radii (`style: .continuous`).
/// - Fluid spring animations and precise pixel-perfect alignment.
struct GazeIndicatorOverlay: View {
    @ObservedObject var viewModel: AppViewModel

    private var snapshot: LyraSnapshot { viewModel.snapshot }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Transparent click-through canvas spanning full screen
                Color.clear
                    .frame(width: geometry.size.width, height: geometry.size.height)

                // 1. In-place cluster candidates (nearby buttons in active app windows)
                if !snapshot.inPlaceClusterCandidates.isEmpty && !snapshot.isZoomed {
                    ForEach(snapshot.inPlaceClusterCandidates) { candidate in
                        if candidate.id != snapshot.selection?.candidate.id {
                            InPlaceCandidateBox(frame: candidate.frame)
                        }
                    }
                }

                // 2. Contextual macOS region highlight (Top Right, Top Left, Stage Manager, Dock)
                if let contextual = snapshot.contextualHighlight {
                    ContextualHighlightBox(
                        highlight: contextual,
                        dwellProgress: snapshot.dwellProgress,
                        isCommitted: snapshot.committedTarget?.id == contextual.candidate?.id
                    )
                } else if let selection = snapshot.selection, !snapshot.isZoomed {
                    // 3. Direct standard target candidate highlight
                    FrostedTargetBox(
                        frame: selection.candidate.frame,
                        dwellProgress: snapshot.dwellProgress,
                        label: selection.candidate.displayName,
                        role: selection.candidate.role,
                        isCommitted: snapshot.committedTarget?.id == selection.candidate.id
                    )
                }

                // 4. AutoLens magnified cluster panel (only if explicitly enabled by user)
                if viewModel.autoLensEnabled && snapshot.isZoomed && !snapshot.lens.entries.isEmpty {
                    lensView
                }

                // 5. Live gaze dot / reticle (hidden when contextual highlight is active to avoid visual clutter)
                if viewModel.showGazeOverlay && snapshot.contextualHighlight == nil, let gaze = snapshot.gazePoint {
                    frostedGazeIndicator(at: CGPoint(x: gaze.x, y: gaze.y))
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Frosted Gaze Indicator

    private func frostedGazeIndicator(at point: CGPoint) -> some View {
        let confidence = max(0.0, min(snapshot.gazeConfidence, 1.0))

        return ZStack {
            // Diffuse frosted ambient halo glow
            Circle()
                .fill(Color.white.opacity(0.12 * confidence))
                .frame(width: 44, height: 44)
                .blur(radius: 2)

            // Inner translucent frosted disc
            Circle()
                .fill(Color.white.opacity(0.04 * confidence))
                .frame(width: 22, height: 22)

            // High-precision outer hairline ring with contrast shadow
            Circle()
                .stroke(Color.white.opacity(0.65 * confidence), lineWidth: 0.75)
                .frame(width: 22, height: 22)
                .shadow(color: Color.black.opacity(0.40 * confidence), radius: 2, y: 1)

            // Crisp center dot with subtle dark border for light/dark background contrast
            Circle()
                .fill(Color.white.opacity(0.95 * confidence))
                .frame(width: 5, height: 5)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.35 * confidence), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 1.5, y: 0.5)
        }
        .position(point)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: point)
    }

    // MARK: - AutoLens Panel (Explicit Mode Only)

    private var lensView: some View {
        let layout = snapshot.lens

        return ZStack(alignment: .topLeading) {
            // Lens panel background card
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 24, y: 10)
                .frame(width: layout.panelFrame.width, height: layout.panelFrame.height)
                .position(x: layout.panelFrame.midX, y: layout.panelFrame.midY)

            // AutoLens target rows
            ForEach(layout.entries) { entry in
                autoLensRow(entry)
            }
        }
    }

    private func autoLensRow(_ entry: TargetLens.Entry) -> some View {
        let isSelected = snapshot.selection?.candidate.id == entry.candidate.id
        let isCommitted = snapshot.committedTarget?.id == entry.candidate.id

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.12)
                        : Color.white.opacity(0.04)
                )

            if isSelected, let dwell = snapshot.dwellProgress {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.14)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(dwell))
                        .animation(.linear(duration: 0.05), value: dwell)
                }
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isCommitted
                        ? Color(red: 0.22, green: 0.78, blue: 0.48)
                        : (isSelected ? Color.white.opacity(0.35) : Color.white.opacity(0.08)),
                    lineWidth: isCommitted ? 1.5 : (isSelected ? 1.0 : 0.5)
                )

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.candidate.displayName)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium, design: .default))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text(entry.candidate.role.isEmpty ? "target" : entry.candidate.role)
                        .font(.system(size: 10, design: .default))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                        .lineLimit(1)
                }

                Spacer()

                if isCommitted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.48))
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: entry.rowFrame.width, height: entry.rowFrame.height)
        .position(x: entry.rowFrame.midX, y: entry.rowFrame.midY)
    }

    // MARK: - Standby Pill Badge

    private var standbyPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "eye.slash")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.62))
            Text("Say \u{201C}cursor\u{201D} to select")
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.88))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.88))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)
        .padding(.top, 44)
        .padding(.leading, 18)
    }
}

// MARK: - Contextual Highlight Box (macOS Zones)

private struct ContextualHighlightBox: View {
    let highlight: ContextualHighlight
    let dwellProgress: Double?
    let isCommitted: Bool

    var body: some View {
        let frame = highlight.frame
        let cornerRadius: CGFloat = {
            switch highlight.kind {
            case .dock: return 20
            case .stageManager: return 14
            case .activeAppWindow: return 16
            default: return 8
            }
        }()

        ZStack(alignment: .topLeading) {
            // Fluid dwell progress fill
            if let dwell = dwellProgress {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.20))
                    .frame(width: CGFloat(frame.width) * CGFloat(dwell), height: CGFloat(frame.height))
                    .offset(x: CGFloat(frame.minX), y: CGFloat(frame.minY))
                    .animation(.linear(duration: 0.05), value: dwell)
            }

            // Translucent frosted backing
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                .offset(x: CGFloat(frame.minX), y: CGFloat(frame.minY))

            // Prominent high-contrast continuous squircle border with luminous glow
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    isCommitted
                        ? Color(red: 0.22, green: 0.85, blue: 0.50)
                        : Color.white.opacity(0.85),
                    lineWidth: isCommitted ? 2.5 : 2.0
                )
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                .offset(x: CGFloat(frame.minX), y: CGFloat(frame.minY))
                .shadow(color: Color.white.opacity(0.40), radius: 8)
                .shadow(color: Color.black.opacity(0.50), radius: 10, y: 3)

            // Minimal floating label pill
            HStack(spacing: 5) {
                Text(highlight.title)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let subtitle = highlight.subtitle, !subtitle.isEmpty {
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.40))
                    Text(subtitle)
                        .font(.system(size: 10, design: .default))
                        .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.75))
                        .lineLimit(1)
                }

                if isCommitted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.48))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.92))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
            .offset(
                x: CGFloat(frame.minX),
                y: (highlight.kind == .topLeftMenu || highlight.kind == .topRightStatus)
                    ? CGFloat(frame.maxY) + 6
                    : max(CGFloat(frame.minY) - 26, 4)
            )
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: frame)
    }
}

// MARK: - In-Place Cluster Candidate Box

private struct InPlaceCandidateBox: View {
    let frame: LyraRect

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
            .offset(x: CGFloat(frame.minX), y: CGFloat(frame.minY))
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: frame)
    }
}

// MARK: - Frosted Target Box (Direct Selection)

private struct FrostedTargetBox: View {
    let frame: LyraRect
    let dwellProgress: Double?
    let label: String
    let role: String
    let isCommitted: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Fluid dwell progress fill
            if let dwell = dwellProgress {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: CGFloat(frame.width) * CGFloat(dwell), height: CGFloat(frame.height))
                    .offset(x: CGFloat(frame.minX), y: CGFloat(frame.minY))
                    .animation(.linear(duration: 0.05), value: dwell)
            }

            // Subtle target background fill
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                .offset(x: CGFloat(frame.minX), y: CGFloat(frame.minY))

            // Target bounding stroke
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isCommitted
                        ? Color(red: 0.22, green: 0.78, blue: 0.48)
                        : Color.white.opacity(0.40),
                    lineWidth: isCommitted ? 1.5 : 0.75
                )
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                .offset(x: CGFloat(frame.minX), y: CGFloat(frame.minY))
                .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)

            // Minimal floating label pill
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !role.isEmpty {
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.52))
                    Text(role)
                        .font(.system(size: 10, design: .default))
                        .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.72))
                        .lineLimit(1)
                }

                if isCommitted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.48))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.92))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
            .offset(x: CGFloat(frame.minX), y: max(CGFloat(frame.minY) - 24, 4))
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: frame)
    }
}
