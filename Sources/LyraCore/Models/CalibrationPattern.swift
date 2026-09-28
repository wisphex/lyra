import Foundation

/// A set of screen locations the user is asked to look at during calibration.
///
/// Three properties matter for fit quality, and the old fixed 9-point pattern at
/// 0.15/0.85 satisfied none of them:
///
/// 1. **Edge coverage.** The old pattern never sampled past 85% of the screen, so the
///    polynomial had to *extrapolate* to reach the real edges. Extrapolating a
///    quadratic past its data is how you get a cursor that flies off into a corner.
///    These patterns reach 6-8% from the border.
///
/// 2. **Point count versus term count.** The default basis has 20 terms, and a fit needs
///    strictly more constraints than free parameters. An exactly-determined pattern (20
///    points, 20 terms) is square: the measured design matrix has rank 19, so one
///    direction is undetermined and the ridge term decides it on its own — which is
///    regularisation quietly becoming the answer rather than stabilising it. The standard
///    pattern supplies 25 points, leaving five spare constraints.
///
/// 3. **Non-collinearity.** A perfect grid is highly structured, which leaves some
///    polynomial directions poorly constrained. A small deterministic jitter breaks
///    that up without making the pattern feel random to the user.
public struct CalibrationPattern: Sendable {

    public struct Point: Sendable, Identifiable, Equatable {
        public let id: Int
        /// Normalised screen position, origin top-left.
        public let x: Double
        public let y: Double

        public init(id: Int, x: Double, y: Double) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    public let points: [Point]
    public let name: String

    /// Intended duration of one point's hold, in seconds.
    public let holdDuration: Double

    /// 25 points in a 5x5 grid, inset from the edges, with deterministic jitter.
    ///
    /// Roughly a minute end to end. That is a real cost, but gaze calibration is done
    /// once per setup, and a bad calibration costs far more than a minute every time
    /// the user tries to click something. The point count is set by the basis: 20 terms
    /// need more than 20 constraints, so 25 it is.
    ///
    /// The hold is deliberately slow. The capture cannot move on until the eye has been
    /// on the target for a while anyway, and a hold shorter than the time it takes to
    /// find a new dot and settle on it just means every hold completes at the moment the
    /// user is still arriving.
    public static let standard = CalibrationPattern(
        points: grid(columns: 5, rows: 5, inset: 0.06, jitter: 0.012),
        name: "Standard (25 points)",
        holdDuration: 1.6
    )

    /// 12 points. Faster, noticeably less accurate at the edges. Offered for people
    /// who want to re-tune quickly after a small change in seating position.
    public static let quick = CalibrationPattern(
        points: grid(columns: 4, rows: 3, inset: 0.09, jitter: 0.010),
        name: "Quick (12 points)",
        holdDuration: 1.3
    )

    /// WebGazer 9-point multi-click pattern: 3x3 grid at 0.10, 0.50, 0.90 for X and Y.
    ///
    /// Following the WebGazer research paradigm (Papoutsaki et al., IJCAI 2016),
    /// 9 calibration points are active simultaneously across the screen:
    /// (0.10, 0.10), (0.50, 0.10), (0.90, 0.10),
    /// (0.10, 0.50), (0.50, 0.50), (0.90, 0.50),
    /// (0.10, 0.90), (0.50, 0.90), (0.90, 0.90).
    /// WebGazer 9-point multi-click pattern: 3x3 grid on the exact edges and corners of the screen.
    public static let webGazer9 = CalibrationPattern(
        points: [
            Point(id: 0, x: 0.02, y: 0.025),
            Point(id: 1, x: 0.50, y: 0.025),
            Point(id: 2, x: 0.98, y: 0.025),
            Point(id: 3, x: 0.02, y: 0.50),
            Point(id: 4, x: 0.50, y: 0.50),
            Point(id: 5, x: 0.98, y: 0.50),
            Point(id: 6, x: 0.02, y: 0.975),
            Point(id: 7, x: 0.50, y: 0.975),
            Point(id: 8, x: 0.98, y: 0.975)
        ],
        name: "WebGazer 9-Point (3×3)",
        holdDuration: 0
    )

    public static let ninePoint = webGazer9

    /// Macro targets matching macOS functional zones: Top Left, Top Center, Top Right, Stage Manager, Middle, Right Workspace, Bottom Left (Dock), Bottom Center (Dock), and Bottom Right (Dock).
    public static let macro5 = CalibrationPattern(
        points: [
            Point(id: 0, x: 0.12, y: 0.08),  // Top Left (Apple & App Menu)
            Point(id: 1, x: 0.50, y: 0.08),  // Top Center (Menu Bar)
            Point(id: 2, x: 0.88, y: 0.08),  // Top Right (Control Center & Status)
            Point(id: 3, x: 0.08, y: 0.50),  // Left Edge (Stage Manager)
            Point(id: 4, x: 0.50, y: 0.50),  // Middle (Center Open Window)
            Point(id: 5, x: 0.92, y: 0.50),  // Right Workspace
            Point(id: 6, x: 0.12, y: 0.82),  // Bottom Left (Dock Left)
            Point(id: 7, x: 0.50, y: 0.82),  // Bottom Center (Dock Center)
            Point(id: 8, x: 0.88, y: 0.82)   // Bottom Right (Dock Right / Trash)
        ],
        name: "Macro Zones (Menu Bar • Stage Manager • Dock • Windows)",
        holdDuration: 0
    )

    /// 16 points in a 4x4 grid, for click-driven calibration.
    ///
    /// Coverage matters more than replication here. The fit has ~20 terms, and what
    /// conditions it is the design matrix spanning the feature space — which needs
    /// *positions*, including the corners and edges, far more than it needs many repeats
    /// of the same position. Each of these is clicked several times, which supplies the
    /// replication; this grid supplies the span.
    public static let click = CalibrationPattern(
        points: grid(columns: 4, rows: 4, inset: 0.08, jitter: 0.010),
        name: "Click (16 points)",
        holdDuration: 0
    )

    /// Held-out points used to *measure* accuracy after fitting, on data the fit never saw.
    ///
    /// These are offset from the calibration grid intersections on purpose: a validation
    /// point that coincides with a training point would be scored on a location the model
    /// has already been tuned to hit, which flatters the result.
    public static let validation = CalibrationPattern(
        points: [
            Point(id: 0, x: 0.19, y: 0.24),
            Point(id: 1, x: 0.79, y: 0.22),
            Point(id: 2, x: 0.50, y: 0.50),
            Point(id: 3, x: 0.21, y: 0.77),
            Point(id: 4, x: 0.81, y: 0.79),
            Point(id: 5, x: 0.50, y: 0.12),
            Point(id: 6, x: 0.50, y: 0.88)
        ],
        name: "Accuracy check",
        holdDuration: 0.85
    )

    /// Builds a grid with a small deterministic offset so no two points sit in a
    /// perfectly collinear arrangement. The offsets repeat run to run, so calibration
    /// is reproducible rather than depending on a random seed.
    private static func grid(columns: Int, rows: Int, inset: Double, jitter: Double) -> [Point] {
        var points: [Point] = []
        let spanX = 1.0 - 2 * inset
        let spanY = 1.0 - 2 * inset

        var index = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let baseX = inset + spanX * Double(column) / Double(columns - 1)
                let baseY = inset + spanY * Double(row) / Double(rows - 1)

                let jitterX = Double((index % 3) - 1) * jitter
                let jitterY = Double(((index / 3) % 3) - 1) * jitter

                points.append(Point(
                    id: index,
                    x: min(max(baseX + jitterX, 0.02), 0.98),
                    y: min(max(baseY + jitterY, 0.02), 0.98)
                ))
                index += 1
            }
        }

        // Centre the sweep so the eye does not always start at a corner.
        return points.sorted { lhs, rhs in
            let lhsRadius = pow(lhs.x - 0.5, 2) + pow(lhs.y - 0.5, 2)
            let rhsRadius = pow(rhs.x - 0.5, 2) + pow(rhs.y - 0.5, 2)
            return lhsRadius < rhsRadius
        }.enumerated().map { Point(id: $0.offset, x: $0.element.x, y: $0.element.y) }
    }
}
