import Foundation
import PondsideCore
import PondsideTiming

/// Asks LilyPond when everything happens: tempos (printed or hidden),
/// cues (`\ecue`, read from the event's `cue-label`), timing marks
/// (`timing-label`), notes and groups, each at its exact moment with its
/// bar and position in the bar.
///
/// The rows are timing.ily's (the lilypond-supercollider workflow), plus
/// the position in the bar and `meter` rows, so Pondside and an existing
/// patch's scripts compute identical seconds from the same score.
public enum TimingDump {
    public static let marker = "PONDSIDE-TIMING\t"

    public static let listener = """
    #(define pondside-timing-last-meter #f)

    #(define (pondside-timing-row context kind . values)
       (let ((m (ly:context-current-moment context)))
         (if (zero? (ly:moment-grace m))
             (let* ((bar (ly:context-property context 'currentBarNumber 1))
                    (pos (ly:context-property context 'measurePosition (ly:make-moment 0)))
                    (meter (ly:context-property context 'timeSignatureFraction '(4 . 4)))
                    (row (lambda (k vs)
                           (display (string-join
                                     (append (list "PONDSIDE-TIMING"
                                                   (number->string (ly:moment-main m))
                                                   (number->string bar)
                                                   (string-append "@" (number->string (ly:moment-main pos)))
                                                   k)
                                             (map (lambda (v) (format #f "~a" v)) vs))
                                     "\\t"))
                           (newline))))
               (if (and (pair? meter) (not (equal? meter pondside-timing-last-meter)))
                   (begin
                     (set! pondside-timing-last-meter meter)
                     (row "meter" (list (format #f "~a/~a" (car meter) (cdr meter))))))
               (row kind values)))))

    #(define (pondside-timing-staff context)
       (let ((staff (ly:context-find context 'Staff)))
         (if staff (ly:context-id staff) "")))

    #(define (Pondside_timing_engraver context)
       (make-engraver
        (listeners
         ((tempo-change-event engraver event)
          (let ((count (ly:event-property event 'metronome-count #f))
                (unit (ly:event-property event 'tempo-unit #f)))
            (if (and (number? count) unit)
                (pondside-timing-row context "tempo"
                  (exact->inexact (* count (/ (ly:moment-main (ly:duration->moment unit)) 1/4)))))))
         ((text-script-event engraver event)
          (let ((cue (ly:event-property event 'cue-label #f))
                (mark (ly:event-property event 'timing-label #f)))
            (cond (cue (pondside-timing-row context "text" (string-append "cue " cue)))
                  (mark (pondside-timing-row context "text" mark)))))
         ((note-event engraver event)
          (let ((p (ly:event-property event 'pitch #f)))
            (if (ly:pitch? p)
                (pondside-timing-row context "note" (pondside-timing-staff context) (+ 60 (ly:pitch-semitones p))))))
         ((note-grouping-event engraver event)
          (pondside-timing-row context "group" (pondside-timing-staff context)
            (if (= (ly:event-property event 'span-direction) START) "start" "stop"))))))

    \\layout {
      \\context { \\Voice \\consists #Pondside_timing_engraver }
    }

    """

    /// Interprets `source` (no pages are written) and returns its timing log.
    public static func run(_ installation: LilyPondInstallation, source: URL) async throws -> TimingLog {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("timing.ily")
        try Data(listener.utf8).write(to: settings)
        let output = try await ProcessRunner.run(
            installation.executable,
            ["-dinclude-settings=\(settings.path)", "-dno-print-pages", "-dbackend=null",
             "-o", dir.appendingPathComponent("out").path, source.path],
            currentDirectory: source.deletingLastPathComponent().path)
        guard output.status == 0 else { throw EventDump.Failure(log: output.stderrString) }
        return TimingLog(parsing: output.stdoutString, prefix: marker)
    }
}
