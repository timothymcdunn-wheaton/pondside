# senza-misura

Unmetered music with a decided length. Inside the passage there is no
meter and no barline (a cadenza). Afterwards comes a bar line, and the
meter continues from where it left off. In the MIDI, and so in every cue
time after it, the passage lasts exactly `seconds`.

```lilypond
\lexicon "senza-misura" #'((seconds . 20) (label . "senza misura, ca. 20″"))
  { c''8 d'' e'' f'' g''4 }
```

**Pitfalls.**
- Bar numbers don't advance inside the passage.
- `resume` restates the tempo at its end. Drop a printed `\tempo` that
  falls at the same moment, or Pondside warns about two tempos.
