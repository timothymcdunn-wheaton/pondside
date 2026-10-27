# proportional

Within the passage, horizontal space is proportional to time: a quarter
note takes twice the room of an eighth. `unit` picks the value that gets
one unit of space. Use the shortest value in the passage.

```lilypond
\lexicon "proportional" #'((unit . 16)) { c''8 c''16 c'' c''4 }
```

**Pitfalls.** Proportional spacing needs room. Long passages may want
`\override Score.SpacingSpanner.uniform-stretching = ##t` in the
`\layout`.
