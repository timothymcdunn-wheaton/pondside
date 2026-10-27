% senza-misura: no meter or barlines inside the music (cadenza), a bar line
% after it, and a hidden tempo so the passage lasts `seconds` in the MIDI
% and in cue times; the tempo returns to `resume` afterwards.
#(pondside-lexicon-register! "senza-misura"
  (lambda (params music)
    (let* ((seconds (assq-ref params 'seconds))
           (resume (assq-ref params 'resume))
           (label (assq-ref params 'label))
           (len (ly:moment-main (ly:music-length music)))
           (bpm (/ (* len 4 60) seconds)))
      #{ << { \once \omit Score.MetronomeMark \tempo 4 = #(inexact->exact bpm) }
            { \cadenzaOn
              #(if (and (string? label) (not (string-null? label)))
                   #{ <>^\markup \italic #label #}
                   #{ #})
              #music
              \cadenzaOff \bar "|" } >>
         \once \omit Score.MetronomeMark \tempo 4 = #(inexact->exact resume) #})))
