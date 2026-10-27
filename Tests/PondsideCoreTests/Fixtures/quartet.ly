\version "2.24.0"
\language "english"
% Absolute and \fixed entry, English note names, dynamics, hairpins,
% articulations, multi-measure rests and a \transpose.

\header {
  title = "Quartet Fragment"
}

violinI = {
  \key bf \major
  \time 3/4
  bf'4\p( c'' d'') |
  ef''2.~ |
  ef''4 d''8-. c''-. bf'4 |
  a'2\< g'4\! |
  f'2.\f |
  R2.*2 |
  bf'2\fermata r4 \bar "|."
}

violinII = \fixed c' {
  \key bf \major
  \time 3/4
  d4\p( ef f) |
  g2.~ |
  g4 f8-. ef-. d4 |
  c2 cs4 |
  d2.\f |
  R2.*2 |
  d2 r4 \bar "|."
}

viola = \transpose c c {
  \clef alto
  \key bf \major
  bf4 a g |
  c'2. |
  bf4 a8 g fs4-> |
  g2 a4 |
  bf2. |
  R2.*2 |
  bf2 r4 \bar "|."
}

cello = \relative c {
  \clef bass
  \key bf \major
  bf4-- f' d |
  c2.:16 |
  g4 a bf |
  ef, f g |
  bf,2. |
  r4 r f'' |
  bf,,2 r4 \bar "|."
}

\score {
  \new StaffGroup <<
    \new Staff \with { instrumentName = "Vln I" } \violinI
    \new Staff \with { instrumentName = "Vln II" } \violinII
    \new Staff \with { instrumentName = "Vla" } \viola
    \new Staff \with { instrumentName = "Vc" } \cello
  >>
}
