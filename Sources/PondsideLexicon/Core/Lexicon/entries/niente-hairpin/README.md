# niente-hairpin

Every hairpin in the music gets a small circle at its quiet end: *al niente*
for a decrescendo, *dal niente* for a crescendo.

```lilypond
\lexicon "niente-hairpin" #'() { g'2\> g'4 r\! }
```

**Pitfalls.** The circle sits where the hairpin ends. End it on the rest after
the sound has gone (`r\!`), not on the last note, or the circle lands under
the note.
