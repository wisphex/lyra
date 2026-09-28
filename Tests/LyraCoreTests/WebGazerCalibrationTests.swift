import XCTest
@testable import LyraCore

final class WebGazerCalibrationTests: XCTestCase {

    private let screen = LyraSize(width: 1470, height: 956)

    private func makeFeatures(pupilX: Double, pupilY: Double) -> GazeFeatures {
        GazeFeatures(
            pupilX: pupilX, pupilY: pupilY,
            yaw: 0.0, pitch: 0.0, roll: 0.0,
            faceX: 0.5, faceY: 0.5,
            iod: 0.31, faceWidth: 0.24,
            eyeOpenness: 0.95, confidence: 0.98
        )
    }

    // MARK: - Pattern Properties

    func testWebGazer9PointPatternProperties() {
        let pattern = CalibrationPattern.webGazer9
        XCTAssertEqual(pattern.points.count, 9)

        let expectedCoords: [(Double, Double)] = [
            (0.02, 0.025), (0.50, 0.025), (0.98, 0.025),
            (0.02, 0.50), (0.50, 0.50), (0.98, 0.50),
            (0.02, 0.975), (0.50, 0.975), (0.98, 0.975)
        ]

        for (i, expected) in expectedCoords.enumerated() {
            let pt = pattern.points[i]
            XCTAssertEqual(pt.id, i)
            XCTAssertEqual(pt.x, expected.0, accuracy: 1e-9)
            XCTAssertEqual(pt.y, expected.1, accuracy: 1e-9)
        }

        XCTAssertEqual(CalibrationPattern.ninePoint.points.count, 9)
    }

    // MARK: - Engine Initialization & Active Points

    func testAllNinePointsActiveSimultaneously() {
        let engine = WebGazerCalibration(clicksPerPoint: 5)
        engine.start()

        XCTAssertEqual(engine.totalPointsCount, 9)
        XCTAssertEqual(engine.requiredClicks, 45)
        XCTAssertEqual(engine.totalClicks, 0)
        XCTAssertEqual(engine.completedPointsCount, 0)
        XCTAssertFalse(engine.isAllPointsComplete)

        // All 9 points are active with 0 clicks initially
        for pt in engine.points {
            XCTAssertEqual(pt.clicks, 0)
            XCTAssertEqual(pt.clicksRequired, 5)
            XCTAssertFalse(pt.isComplete)
            XCTAssertEqual(pt.remainingClicks, 5)
        }
    }

    // MARK: - Clicking & Ground-Truth Registration

    func testPointClickingRegistersGroundTruth() {
        let engine = WebGazerCalibration(clicksPerPoint: 5)
        engine.start()

        // Feed steady ocular features
        for _ in 0..<10 {
            engine.observe(features: makeFeatures(pupilX: 0.15, pupilY: 0.15))
        }

        // Click point 0 (top-left, 0.02, 0.025)
        let clicked = engine.registerClick(pointIndex: 0)
        XCTAssertTrue(clicked)

        XCTAssertEqual(engine.points[0].clicks, 1)
        XCTAssertEqual(engine.totalClicks, 1)
        XCTAssertEqual(engine.samples.count, 1)

        let sample = engine.samples[0]
        XCTAssertEqual(sample.targetX, 0.02, accuracy: 1e-9)
        XCTAssertEqual(sample.targetY, 0.025, accuracy: 1e-9)
        XCTAssertEqual(sample.features[0], 0.15, accuracy: 1e-9)
    }

    func testEachPointCapsAtFiveClicks() {
        let engine = WebGazerCalibration(clicksPerPoint: 5)
        engine.start()

        for _ in 0..<10 {
            engine.observe(features: makeFeatures(pupilX: 0.50, pupilY: 0.50))
        }

        // Click point 4 five times
        for _ in 0..<5 {
            XCTAssertTrue(engine.registerClick(pointIndex: 4))
        }

        XCTAssertEqual(engine.points[4].clicks, 5)
        XCTAssertTrue(engine.points[4].isComplete)
        XCTAssertEqual(engine.completedPointsCount, 1)

        // Sixth click should be rejected
        XCTAssertFalse(engine.registerClick(pointIndex: 4))
        XCTAssertEqual(engine.points[4].clicks, 5)
        XCTAssertEqual(engine.samples.count, 5)
    }

    // MARK: - Hit Testing by Screen Coordinates

    func testRegisterClickByCoordinateTolerance() {
        let engine = WebGazerCalibration(clicksPerPoint: 5, clickTolerancePoints: 100)
        engine.start()

        for _ in 0..<10 {
            engine.observe(features: makeFeatures(pupilX: 0.50, pupilY: 0.025))
        }

        // Point 1 is at (0.50, 0.025). Click slightly off at (0.51, 0.025) -> ~15 px away
        let hit = engine.registerClick(atNormalized: (0.51, 0.025), screenSize: screen)
        XCTAssertTrue(hit)
        XCTAssertEqual(engine.points[1].clicks, 1)

        // Click far away at (0.30, 0.30) -> should be rejected
        let miss = engine.registerClick(atNormalized: (0.30, 0.30), screenSize: screen)
        XCTAssertFalse(miss)
        XCTAssertEqual(engine.rejectedClicks, 1)
    }

    // MARK: - Full 45-Click Run & Ridge Regression Fitting

    func testFull45ClicksFitsRidgeRegressionAndVerifies() throws {
        let engine = WebGazerCalibration(clicksPerPoint: 5, verificationDuration: 3.5)
        engine.start()

        // 9 calibration positions
        let gridCoords: [(Double, Double)] = [
            (0.02, 0.025), (0.50, 0.025), (0.98, 0.025),
            (0.02, 0.50), (0.50, 0.50), (0.98, 0.50),
            (0.02, 0.975), (0.50, 0.975), (0.98, 0.975)
        ]

        // Click each of the 9 points 5 times (45 total)
        for (idx, coord) in gridCoords.enumerated() {
            for clickNum in 0..<5 {
                let jitter = Double(clickNum) * 0.002
                for _ in 0..<6 {
                    engine.observe(features: makeFeatures(
                        pupilX: coord.0 + jitter,
                        pupilY: coord.1 + jitter
                    ))
                }
                XCTAssertTrue(engine.registerClick(pointIndex: idx))
            }
        }

        XCTAssertTrue(engine.isAllPointsComplete)
        XCTAssertEqual(engine.samples.count, 45)
        XCTAssertEqual(engine.totalClicks, 45)
        XCTAssertEqual(engine.completedPointsCount, 9)

        // Fit Ridge Regression
        let map = try engine.fit(screenWidth: 1470, screenHeight: 956)
        XCTAssertTrue(map.isCalibrated)
        XCTAssertTrue(map.validationErrorPixels < 150.0)

        // WebGazer calibration completes directly with genuine accuracy score (>= 80%)
        if case .completed(let accuracy, let errorPixels) = engine.phase {
            XCTAssertGreaterThanOrEqual(accuracy, 80.0)
            XCTAssertLessThanOrEqual(accuracy, 100.0)
            XCTAssertLessThan(errorPixels, 180.0)
        } else {
            XCTFail("Phase should be completed after fit, but got \(engine.phase)")
        }

        // Test optional center verification if explicitly triggered
        engine.startVerification()
        if case .precisionVerification(let remaining, let duration, _) = engine.phase {
            XCTAssertEqual(duration, 3.5)
            XCTAssertEqual(remaining, 3.5)
        } else {
            XCTFail("Phase should be precisionVerification, but got \(engine.phase)")
        }

        // Simulate 3.5 seconds of center verification frames
        let dt = 0.5
        for _ in 0..<7 {
            engine.observeVerification(
                features: makeFeatures(pupilX: 0.50, pupilY: 0.50),
                screenSize: screen,
                dt: dt
            )
        }

        // Completed phase with accuracy percentage
        if case .completed(let accuracy, let errorPixels) = engine.phase {
            XCTAssertGreaterThanOrEqual(accuracy, 75.0)
            XCTAssertLessThanOrEqual(accuracy, 100.0)
            XCTAssertLessThan(errorPixels, 120.0)
        } else {
            XCTFail("Phase should be completed after 3.5s, but got \(engine.phase)")
        }
    }

    func testWebGazerMathematicalPrecisionFormula() {
        let engine = WebGazerCalibration(clicksPerPoint: 5)
        engine.start()

        // 9 calibration positions
        let gridCoords: [(Double, Double)] = [
            (0.02, 0.025), (0.50, 0.025), (0.98, 0.025),
            (0.02, 0.50), (0.50, 0.50), (0.98, 0.50),
            (0.02, 0.975), (0.50, 0.975), (0.98, 0.975)
        ]

        for (idx, coord) in gridCoords.enumerated() {
            for clickNum in 0..<5 {
                let jitter = Double(clickNum) * 0.001
                for _ in 0..<6 {
                    engine.observe(features: makeFeatures(
                        pupilX: coord.0 + jitter,
                        pupilY: coord.1 + jitter
                    ))
                }
                XCTAssertTrue(engine.registerClick(pointIndex: idx))
            }
        }

        _ = try? engine.fit(screenWidth: 1470, screenHeight: 956)

        let result = engine.computeCalibrationAccuracy(screenWidth: 1470, screenHeight: 956)
        // WebGazer precision formula on 9-point grid yields ~82-95%
        XCTAssertGreaterThanOrEqual(result.accuracyPercentage, 80.0, "WebGazer precision formula should yield >= 80% on fitted points")
        XCTAssertLessThanOrEqual(result.accuracyPercentage, 100.0)
        XCTAssertLessThan(result.errorPixels, 180.0)
    }

    // MARK: - Passive Continuous Click Training

    func testContinuousClickTrainerRefinesMap() throws {
        let trainer = ContinuousClickTrainer(maxPassiveSamples: 20)
        XCTAssertTrue(trainer.isEnabled)

        // Synthetic 9 base samples
        var baseSamples: [CalibrationSample] = []
        let coords: [(Double, Double)] = [
            (0.10, 0.10), (0.50, 0.10), (0.90, 0.10),
            (0.10, 0.50), (0.50, 0.50), (0.90, 0.50),
            (0.10, 0.90), (0.50, 0.90), (0.90, 0.90)
        ]
        for coord in coords {
            let f = makeFeatures(pupilX: coord.0, pupilY: coord.1)
            let s = CalibrationSample(
                targetX: coord.0,
                targetY: coord.1,
                features: f.vector,
                frameCount: 10,
                featureSpread: 0.01
            )
            baseSamples.append(s)
        }
        trainer.setBaseSamples(baseSamples)

        // Observe frames and register a passive click at (0.35, 0.40)
        for _ in 0..<10 {
            trainer.observe(features: makeFeatures(pupilX: 0.35, pupilY: 0.40))
        }

        let updatedMap = trainer.registerClick(atNormalized: (0.35, 0.40), screenSize: screen)
        XCTAssertNotNil(updatedMap)
        XCTAssertTrue(updatedMap?.isCalibrated == true)
        XCTAssertEqual(trainer.passiveSamples.count, 1)

        // Verify sliding window
        for i in 0..<25 {
            let x = 0.2 + Double(i) * 0.02
            for _ in 0..<6 {
                trainer.observe(features: makeFeatures(pupilX: x, pupilY: 0.5))
            }
            trainer.registerClick(atNormalized: (x, 0.5), screenSize: screen)
        }
        XCTAssertLessThanOrEqual(trainer.passiveSamples.count, 20)

        // Reset
        trainer.reset()
        XCTAssertTrue(trainer.passiveSamples.isEmpty)
    }

    func testObserveVerificationWithEmptyFramesDoesNotReturnFalsifiedHighAccuracy() throws {
        let engine = WebGazerCalibration(clicksPerPoint: 3)
        engine.start()

        let gridCoords: [(Double, Double)] = [
            (0.10, 0.10), (0.50, 0.10), (0.90, 0.10),
            (0.10, 0.50), (0.50, 0.50), (0.90, 0.50),
            (0.10, 0.90), (0.50, 0.90), (0.90, 0.90)
        ]

        for (idx, coord) in gridCoords.enumerated() {
            for clickNum in 0..<3 {
                let jitter = Double(clickNum) * 0.002
                for _ in 0..<6 {
                    engine.observe(features: makeFeatures(
                        pupilX: coord.0 + jitter,
                        pupilY: coord.1 + jitter
                    ))
                }
                XCTAssertTrue(engine.registerClick(pointIndex: idx))
            }
        }

        _ = try engine.fit(screenWidth: 1470, screenHeight: 956)

        // Empty verification: user closed eyes / blinked the entire time
        for _ in 0..<7 {
            engine.observeVerification(
                features: GazeFeatures(
                    pupilX: 0.5, pupilY: 0.5, yaw: 0, pitch: 0, roll: 0,
                    faceX: 0.5, faceY: 0.5, iod: 0.3, faceWidth: 0.2,
                    eyeOpenness: 0.0, confidence: 0.0
                ),
                screenSize: screen,
                dt: 0.5
            )
        }

        // When verification had zero usable eye frames, accuracy must be computed from map error or 0, not a hardcoded 95%
        let accuracy = engine.computeLiveAccuracy()
        XCTAssertNotEqual(accuracy, 95.0, "Empty verification must not claim a hardcoded 95% accuracy")
    }

    func testContinuousClickTrainerDiscardsUnusableFrames() {
        let trainer = ContinuousClickTrainer()
        trainer.setBaseSamples([])

        // Provide blink / unusable frames
        for _ in 0..<10 {
            trainer.observe(features: GazeFeatures(
                pupilX: 0.5, pupilY: 0.5, yaw: 0, pitch: 0, roll: 0,
                faceX: 0.5, faceY: 0.5, iod: 0.3, faceWidth: 0.2,
                eyeOpenness: 0.0, confidence: 0.0
            ))
        }

        let map = trainer.registerClick(atNormalized: (0.5, 0.5), screenSize: screen)
        XCTAssertNil(map, "Click during eye closure must be safely discarded")
        XCTAssertEqual(trainer.passiveSamples.count, 0)
    }

    func testMacro5PatternPropertiesAndCalibration() {
        let pattern = CalibrationPattern.macro5
        XCTAssertEqual(pattern.points.count, 9)

        // 9 macro points: Top Left, Top Center, Top Right, Left Edge (Stage Manager), Middle, Right Workspace, Bottom Left, Bottom Center, Bottom Right
        XCTAssertEqual(pattern.points[0].x, 0.12, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[0].y, 0.08, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[1].x, 0.50, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[1].y, 0.08, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[2].x, 0.88, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[2].y, 0.08, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[3].x, 0.08, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[3].y, 0.50, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[4].x, 0.50, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[4].y, 0.50, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[5].x, 0.92, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[5].y, 0.50, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[6].x, 0.12, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[6].y, 0.82, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[7].x, 0.50, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[7].y, 0.82, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[8].x, 0.88, accuracy: 1e-3)
        XCTAssertEqual(pattern.points[8].y, 0.82, accuracy: 1e-3)

        let engine = WebGazerCalibration(pattern: pattern, clicksPerPoint: 5)
        engine.start()

        XCTAssertEqual(engine.totalPointsCount, 9)
        XCTAssertEqual(engine.requiredClicks, 45)
        XCTAssertEqual(engine.completedPointsCount, 0)
        XCTAssertFalse(engine.isAllPointsComplete)

        // Buffer ocular features and register 5 clicks on point 3 (Stage Manager)
        for _ in 0..<10 {
            engine.observe(features: makeFeatures(pupilX: 0.05, pupilY: 0.50))
        }
        for _ in 0..<5 {
            XCTAssertTrue(engine.registerClick(pointIndex: 3))
        }

        XCTAssertEqual(engine.points[3].clicks, 5)
        XCTAssertTrue(engine.points[3].isComplete)
        XCTAssertEqual(engine.completedPointsCount, 1)
    }
}
