import Foundation

/// Coordinate convention for the whole prototype.
///
///   +X = right, -X = left, +Y = up, -Y = down, -Z = forward, +Z = behind.
///
/// All angles are horizontal azimuth in degrees, measured about the vertical axis:
///   0   = straight ahead
///   > 0 = to the right
///   < 0 = to the left
///
/// Y is always 0 here; pitch and roll are ignored.
public enum Geo {

    /// Distance of the virtual source from the listener, in metres. Constant for
    /// every trial so distance is never a cue.
    public static let sourceDistance: Double = 1.5

    /// Wrap an angle into (-180, +180].
    public static func wrap(_ degrees: Double) -> Double {
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a <= -180 { a += 360 }
        return a
    }

    /// Signed angular difference `a - b`, correctly wrapped.
    public static func delta(_ a: Double, _ b: Double) -> Double {
        wrap(a - b)
    }

    /// The azimuth of a world-fixed source as heard by a listener whose head is
    /// yawed by `headYaw` from the world's forward direction.
    ///
    ///   target +60, head   0 -> +60
    ///   target +60, head +30 -> +30
    ///   target +60, head +60 ->   0
    ///   target +60, head +90 -> -30
    public static func relativeAngle(worldTarget: Double, headYaw: Double) -> Double {
        wrap(worldTarget - headYaw)
    }

    /// World-space position of a source at the given azimuth, at `sourceDistance`.
    /// -Z is forward, +X is right, so azimuth a -> (r sin a, 0, -r cos a).
    public static func position(azimuth: Double, distance: Double = sourceDistance)
        -> (x: Double, y: Double, z: Double)
    {
        let r = azimuth * .pi / 180
        return (distance * sin(r), 0, -distance * cos(r))
    }

    /// Unwrap `sample` so that it is continuous with `previous` (no +-180 jumps).
    /// Used to accumulate total head rotation across a trial.
    public static func unwrap(_ sample: Double, previous: Double) -> Double {
        previous + wrap(sample - previous)
    }
}
