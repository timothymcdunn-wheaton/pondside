/// PondsideTiming — tempo map → wall clock. Pure functions, no platform
/// dependencies, exhaustively tested. Lands in M8; see docs/DESIGN.md.
///
/// The module exists from the first commit so the portability seam is
/// enforced by CI before anything depends on it.
public enum PondsideTiming {
    public static let schemaVersion = 1
}
