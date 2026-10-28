% =============================================================================================
%  TEMPORARY: A COMPOSING AID ONLY. NOT PART OF THE SCORE.
%  REMOVE THIS FILE AND ITS \include IN score.ly BEFORE THE SCORE IS FINISHED.
% =============================================================================================
%
% Prints each electronics cue's time (minutes:seconds into the piece) in small coloured type
% just right of its cue box, e.g. [12] 2:26.9, so the cues can be matched against the patch and
% the test render while the piece is being written. The times are not for the performers:
% they will not appear in the final score, the performance notes or the legend, and nothing
% else in the score depends on them.
%
% The times are the patch's own: graphics.ily's (cue n), from every tempo change (printed and
% hidden \playTempo) as the MIDI plays it, so they match resources/piece.cues after an export.
% They are worked out while this score is engraved, so they are always current.
%
% How it works: it redefines \ecue (and so \ecueToCaesura, which calls it) to add the time
% after the box, taking no room (it moves nothing else on the page). Needs defs.ily (\ecue)
% and graphics.ily (cue); include it after both and before electronics.ly.
%
% To remove (when the piece is done):
%   1. delete the line  \include "cue-times.ily"  in score.ly
%   2. delete this file
%   3. delete its section in CLAUDE.md ("Cue times in the score: temporary")
% Nothing else changes: \ecue goes back to defs.ily's definition.

#(define cue-times-plain-ecue ecue)

% "m:ss.s"
#(define (cue-times-format sec)
   (let* ((tenths (inexact->exact (round (* sec 10))))
          (m (quotient tenths 600))
          (s (/ (- tenths (* m 600)) 10.0)))
     (format #f "~a:~a~,1f" m (if (< s 10) "0" "") s)))

% the time of cue `label`, read when the page is drawn (after the whole score is engraved, so
% every tempo and cue has been collected)
#(define-markup-command (cue-time-stamp layout props label) (string?)
   (interpret-markup layout props
     (markup #:whiteout #:with-color (rgb-color 0.8 0.1 0.45) #:sans #:fontsize -2
             (cue-times-format (cue (string->number label))))))

ecue =
#(define-event-function (label) (string?)
   (let ((ev (cue-times-plain-ecue label)))
     (ly:music-set-property! ev 'text
       #{ \markup \concat {
            #(ly:music-property ev 'text)
            \with-dimensions #'(0 . 0) #'(0 . 0) \translate #'(0.5 . 0.4)
              \cue-time-stamp #label } #})
     ev))
