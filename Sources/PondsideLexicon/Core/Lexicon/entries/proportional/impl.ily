% proportional: a spacing section where space is proportional to duration.
#(pondside-lexicon-register! "proportional"
  (lambda (params music)
    (let ((unit (assq-ref params 'unit)))
      #{ \newSpacingSection
         \set Score.proportionalNotationDuration = #(ly:make-moment 1 unit)
         #music
         \newSpacingSection
         \unset Score.proportionalNotationDuration #})))
