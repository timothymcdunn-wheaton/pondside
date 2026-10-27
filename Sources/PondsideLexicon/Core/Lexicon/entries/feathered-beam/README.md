# feathered-beam

Feathered beams over each beamed group in the music. `accel` beams spread
to the right, `rit` beams converge.

```lilypond
\lexicon "feathered-beam" #'((direction . "accel")) { c''16[ d'' e'' f'' g'' a''] }
```

**Pitfalls.** This is visual only: the written durations, and so the MIDI
and cue times, are unchanged. To make the playback accelerate as well,
write the durations with `\featherDurations`.
