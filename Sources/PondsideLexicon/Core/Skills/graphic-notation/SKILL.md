---
name: pondside-graphic-notation
description: Put graphic notation (textures, grains, ripples, wedges, swells, contours) into a LilyPond score through Pondside's Lexicon — find what the user means by "here", pick and combine existing graphic entries, set their parameters, preview, and insert them as minimal edits. Use whenever someone using Pondside asks for a graphic, texture, drawing or gesture in the score ("a grainy texture here, swelling until the next system", "ripple the staff lines", "a wedge into the cue"), even if they don't say Lexicon. Escalate to the pondside-lexicon-entries skill only when no combination of existing entries satisfies the user.
---

# Graphic notation with the Lexicon

Pondside draws graphic notation with **Lexicon entries** on a shared kit. An
entry is a named drawing with typed parameters; a graphic in the score is one
invocation, a spanner from one moment to another in a voice of skips:

```lilypond
s1\startGraphic "grain-cloud" #'((height . (swell 3 0.5 4)) (seed . 2))
s1 s1 s1\stopGraphic
```

The drawing is made at layout time, so it follows the music when spacing
changes, breaks across systems by itself, and is identical on every compile.

## Workflow

1. **Find "here".** Call `score_context`. It returns the clicked staff, the
   file and line, measure:beat, the moment, seconds, the system's start and end
   moments, and the `.ly` around the point (including any graphic already
   there, with its entry and params). Never guess a position from prose.
2. **Search before writing.** `lexicon_search` with the user's words returns
   one line per entry (id, gloss, tags, param names). `lexicon_entry <id>`
   gives the params with types, ranges and docs, and the README's pitfalls.
3. **Map words to params** (below), choose a span, then `graphic_preview` and
   look at the result. Iterate on params, not code.
4. **Insert** with `graphic_insert`: one minimal edit, in a voice of skips on
   the right staff (it creates the voice if the staff has none).
5. **If the user rejects every combination**, switch to the
   `pondside-lexicon-entries` skill and write a new entry as a draft.

## The core graphic entries

| id | what | key params |
|---|---|---|
| `grain-cloud` | seeded dots in a band | `density`, `height` (env), `centre` (env), `size`, `avoid`, `seed` |
| `staff-ripple` | staff lines turning into loops | `amplitude` (env), `curl`, `wavelength`, `lines`, `thickness`, `seed` |
| `wedge` | filled wedge, may dissolve into grains | `from`, `to`, `centre`, `gray`, `dissolve`, `seed` |
| `swell-shape` | solid shape following an envelope | `height` (env), `centre` (env), `side` (both/up/down), `gray` |
| `scribble` | short random strokes in a band | `density`, `height` (env), `length`, `spread`, `thickness`, `seed` |
| `arc` | smooth contour through points, with echoes | `points` ((q y) …), `thickness`, `echoes`, `echo-offset` |

Run `lexicon_search` anyway: project and user entries may add more.

## Envelopes: the vocabulary of change

Any `envelope` param takes a number or one of these, over q = 0…1 along the span:

| write | means |
|---|---|
| `2` or `(constant 2)` | steady |
| `(linear 0.5 3)` | grows (or shrinks) evenly |
| `(swell n lo hi)` | n smooth rises and falls between lo and hi |
| `(pulse n lo hi)` | n sharper peaks |
| `(lfo cycles depth centre)` | oscillates around centre |
| `(points (0 0.5) (0.3 3) (1 0.5))` | through exact values |
| `(sum e1 e2)`, `(product e1 e2)` | combine |
| `(smooth e)` | eases in from 0 |

Phrases and what they become:

- "expanding and contracting", "breathing" → `(swell 3 0.5 3)` on `height`
- "growing", "crescendo-like" → `(linear 0.3 3)`; "dying away" → `(linear 3 0.2)`
- "until the next system" → end the span at the system's end moment from `score_context`
- "denser toward the end" → a second cloud with higher `density` over the later part, or a `linear` height
- "keep out of the notes" → `avoid` `(note-head-interface accidental-interface)`
- "the same but different" → change `seed`

## Combining before inventing

- **Layer** two invocations on one span (in two voices of skips): a `swell-shape`
  in light `gray` under a `grain-cloud`.
- **Chain** spans: one entry ends where the next starts (`\stopGraphic\startGraphic` on one note).
- **Shape with data**: an `arc` or `points` envelope can take numbers computed
  elsewhere (from a sound file's analysis, say) as its param.

## Conventions

- Graphics live in a voice of skips (`s1*4`), never on notes that sound.
- Hide staff lines under a graphic that replaces them (`\stopStaff` … `\startStaff`).
- Units: staff spaces; y = 0 is the middle line, the lines are at −2…2.
- Keep seeds explicit when the user likes a drawing, so it never changes.
