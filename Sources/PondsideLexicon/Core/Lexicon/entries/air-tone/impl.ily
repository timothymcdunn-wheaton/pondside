% air-tone: diamond noteheads and a label on the first note. The cue comes
% from the Lexicon dispatcher (the entry's [sound] binding).
#(define (pondside-air-first-note-add! music post)
   (let ((done #f))
     (music-map
      (lambda (m)
        (if (and (not done) (music-is-of-type? m 'note-event))
            (begin
              (set! done #t)
              (ly:music-set-property! m 'articulations (cons post (ly:music-property m 'articulations)))))
        m)
      music)))

#(pondside-lexicon-register! "air-tone"
  (lambda (params music)
    (let ((label (assq-ref params 'label)))
      (pondside-air-first-note-add! music #{ ^\markup \italic #label #})
      #{ \override NoteHead.style = #'harmonic #music \revert NoteHead.style #})))
