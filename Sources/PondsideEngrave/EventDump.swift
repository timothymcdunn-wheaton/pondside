import Foundation
import PondsideCore

/// A note or rest as LilyPond itself interpreted it.
public struct InterpretedEvent: Hashable, Sendable {
    public enum Kind: String, Sendable { case note, rest }
    public var kind: Kind
    /// Absolute pitch in Pondside convention (c' = octave 1); nil for rests.
    public var pitch: Pitch?
    /// LilyPond's duration string, e.g. "8*2/3" inside a tuplet.
    public var duration: String
    public var line: Int
    /// 0-based Unicode-scalar offset, as in point-and-click.
    public var character: Int
    /// Musical time of the event in whole notes, as "n/d".
    public var moment: String
}

/// Asks LilyPond what the music *means*: every note and rest event with
/// its absolute pitch, duration, moment and source location.
///
/// This is the ground truth Pondside's static model is tested against, and
/// the extraction mechanism the timing engine (M8) builds on: an engraver
/// installed with `-dinclude-settings` listens to events during a normal
/// compile, so it sees exactly what the interpreter sees, Scheme and all.
public enum EventDump {
    public static let listener = """
    \\layout {
      \\context {
        \\Voice
        \\consists
        #(make-engraver
          (listeners
           ((note-event engraver event)
            (let* ((p (ly:event-property event 'pitch))
                   (d (ly:event-property event 'duration))
                   (m (ly:context-current-moment (ly:translator-context engraver)))
                   (o (ly:input-file-line-char-column (ly:event-property event 'origin))))
              (format #t "PONDSIDE-NOTE ~a ~a ~a ~a ~a ~a ~a\\n"
                      (ly:pitch-octave p) (ly:pitch-notename p) (ly:pitch-alteration p)
                      (ly:duration->string d) (cadr o) (caddr o) (ly:moment-main m))))
           ((rest-event engraver event)
            (let ((d (ly:event-property event 'duration))
                  (m (ly:context-current-moment (ly:translator-context engraver)))
                  (o (ly:input-file-line-char-column (ly:event-property event 'origin))))
              (format #t "PONDSIDE-REST ~a ~a ~a ~a\\n"
                      (ly:duration->string d) (cadr o) (caddr o) (ly:moment-main m))))))
      }
    }

    """

    public struct Failure: Error, CustomStringConvertible {
        public var log: String
        public var description: String { "LilyPond failed:\n\(log)" }
    }

    /// Compiles `source` without producing output and returns its events.
    public static func run(_ installation: LilyPondInstallation, source: URL) async throws -> [InterpretedEvent] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("listener.ily")
        try Data(listener.utf8).write(to: settings)
        let output = try await ProcessRunner.run(
            installation.executable,
            ["-dinclude-settings=\(settings.path)", "-dno-print-pages", "-dbackend=null",
             "-o", dir.appendingPathComponent("out").path, source.path],
            currentDirectory: source.deletingLastPathComponent().path)
        guard output.status == 0 else { throw Failure(log: output.stderrString) }
        return parse(output.stdoutString)
    }

    public static func parse(_ text: String) -> [InterpretedEvent] {
        var out: [InterpretedEvent] = []
        for line in text.split(separator: "\n") {
            // Progress chatter can share a line; find our marker anywhere.
            if let r = line.range(of: "PONDSIDE-NOTE ") {
                let f = line[r.upperBound...].split(separator: " ").map(String.init)
                guard f.count == 7, let octave = Int(f[0]), let step = Int(f[1]),
                      let lineNo = Int(f[4]), let ch = Int(f[5]) else { continue }
                let pitch = Pitch(step: step, alteration: quarterTones(f[2]), octave: octave + 1)
                out.append(InterpretedEvent(kind: .note, pitch: pitch, duration: f[3], line: lineNo, character: ch, moment: f[6]))
            } else if let r = line.range(of: "PONDSIDE-REST ") {
                let f = line[r.upperBound...].split(separator: " ").map(String.init)
                guard f.count == 4, let lineNo = Int(f[1]), let ch = Int(f[2]) else { continue }
                out.append(InterpretedEvent(kind: .rest, pitch: nil, duration: f[0], line: lineNo, character: ch, moment: f[3]))
            }
        }
        return out
    }

    /// "1/2" (whole tones) → 2 quarter tones.
    static func quarterTones(_ s: String) -> Int {
        let parts = s.split(separator: "/")
        guard let n = Int(parts.first ?? "0") else { return 0 }
        let d = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        return n * 4 / d
    }
}
