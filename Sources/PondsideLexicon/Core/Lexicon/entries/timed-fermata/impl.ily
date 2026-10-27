% timed-fermata: print a fermata on the first note; in the MIDI and the cue
% times, the music lasts exactly `seconds`, then the tempo returns to `resume`.
#(define (pondside-first-note-add! music post)
   (let ((done #f))
     (music-map
      (lambda (m)
        (if (and (not done) (music-is-of-type? m 'note-event))
            (begin
              (set! done #t)
              (ly:music-set-property! m 'articulations (cons post (ly:music-property m 'articulations)))))
        m)
      music)))

#(pondside-lexicon-register! "timed-fermata"
  (lambda (params music)
    (let* ((seconds (assq-ref params 'seconds))
           (resume (assq-ref params 'resume))
           (len (ly:moment-main (ly:music-length music)))
           (bpm (/ (* len 4 60) seconds)))
      (pondside-first-note-add! music #{ \fermata #})
      #{ << { \once \omit Score.MetronomeMark \tempo 4 = #(inexact->exact bpm) } #music >>
         \once \omit Score.MetronomeMark \tempo 4 = #(inexact->exact resume) #})))
