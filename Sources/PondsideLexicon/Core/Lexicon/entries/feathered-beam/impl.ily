% feathered-beam: visual feathering of the beams inside the music.
#(pondside-lexicon-register! "feathered-beam"
  (lambda (params music)
    (let* ((d (assq-ref params 'direction))
           (dir (if (member d (list "rit" 'rit)) LEFT RIGHT)))
      #{ \override Beam.grow-direction = #dir #music \revert Beam.grow-direction #})))
