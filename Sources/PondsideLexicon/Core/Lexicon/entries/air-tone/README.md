# air-tone

Air sounds for winds: diamond noteheads, with a label (default *air*) over
the first note. The entry carries a sound. Placing it places an `airTone`
cue, whose params are derived from `amount` and the span's length in
seconds, so the patch's `airNoise` follows the score.

```lilypond
\lexicon "air-tone" #'((amount . 0.8)) { d''2 e''4 r }
```

**Pitfalls.** Diamond noteheads also mean harmonics to string players. For
strings, set `label` to make the sound explicit.
