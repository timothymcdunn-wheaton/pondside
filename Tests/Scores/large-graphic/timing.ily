% Timing log for the SuperCollider workflow (lilypond/export_piece.sh): while the score is
% engraved, writes <output>.timing -- one line per event the patch needs, at its moment:
%
%   <moment in whole notes>  <bar>  tempo     <quarter notes per minute>
%   <moment>                 <bar>  text      cue 12        (\ecue "12", \improvMark: its text;
%                                                             "end": the end of the piece)
%   <moment>                 <bar>  note      <staff> <midi pitch>
%   <moment>                 <bar>  group     <staff> start|stop
%
% Include it after defs.ily; it adds an engraver to every Voice. Moments are exact
% rationals (e.g. 217/4); seconds are computed from them with the tempo lines.

#(define timing-port #f)

#(define (timing-line context kind . values)
   (if (not timing-port)
       (set! timing-port (open-output-file (string-append (ly:parser-output-name) ".timing"))))
   (let ((m (ly:context-current-moment context)))
     (if (zero? (ly:moment-grace m))
         (begin
           (display (string-join
                     (append (list (number->string (ly:moment-main m))
                                   (number->string (ly:context-property context 'currentBarNumber 1))
                                   kind)
                             (map (lambda (v) (format #f "~a" v)) values))
                     "\t")
                    timing-port)
           (newline timing-port)
           (force-output timing-port)))))

#(define (staff-id context)
   (let ((staff (ly:context-find context 'Staff)))
     (if staff (ly:context-id staff) "")))

#(define (Timing_voice_engraver context)
   (make-engraver
    (listeners
     ((tempo-change-event engraver event)
      (let ((count (ly:event-property event 'metronome-count #f))
            (unit (ly:event-property event 'tempo-unit #f)))
        (if (and (number? count) unit)
            (timing-line context "tempo"
                         (exact->inexact
                          (* count (/ (ly:moment-main (ly:duration->moment unit)) 1/4)))))))
     ((text-script-event engraver event)
      (let ((cue (ly:event-property event 'cue-label #f))
            (s (string-delete (string->char-set "[]")
                              (markup->string (ly:event-property event 'text)))))
        (cond (cue (timing-line context "text" (string-append "cue " cue)))
              ((or (string-prefix? "improv " s) (string=? s "end"))
               (timing-line context "text" s)))))
     ((note-event engraver event)
      (let ((p (ly:event-property event 'pitch #f)))
        (if (ly:pitch? p)
            (timing-line context "note" (staff-id context) (+ 60 (ly:pitch-semitones p))))))
     ((note-grouping-event engraver event)
      (timing-line context "group" (staff-id context)
                   (if (= (ly:event-property event 'span-direction) START) "start" "stop"))))))

\layout {
  \context { \Voice \consists #Timing_voice_engraver }
}
