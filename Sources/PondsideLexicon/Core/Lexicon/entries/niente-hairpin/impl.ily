% niente-hairpin: circled tips (al/dal niente) on the hairpins inside the music.
#(pondside-lexicon-register! "niente-hairpin"
  (lambda (params music)
    #{ \override Hairpin.circled-tip = ##t #music \revert Hairpin.circled-tip #}))
