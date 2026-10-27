# timed-fermata

A fermata whose length is a decision, not a guess: the printed score shows a
fermata, and in the MIDI (so in the mockup and every cue time after it) the
held music lasts exactly `seconds`. This is the hidden-`\playTempo` practice
from the lilypond-supercollider workflow, packaged.

```lilypond
\lexicon "timed-fermata" #'((seconds . 6) (resume . 72)) { g'1 }
```

**Pitfalls.**
- `resume` restates the tempo where the held music ends. If a printed
  `\tempo` starts at that same moment, Pondside warns about two tempos at
  one moment. Drop the printed one, or move it.
- The fermata goes on the first note of the music. Hold a single note or
  chord.
