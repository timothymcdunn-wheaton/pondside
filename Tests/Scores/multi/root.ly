\version "2.24.0"
% A score split across files, the way musicxml2ly and most real projects
% lay it out. This root holds no notes of its own.
\include "defs.ily"
\include "flute.ily"
\include "graphics.ily"

\header {
  title = "Multi-file"
}

\score {
  \new Staff \with { instrumentName = \fluteName } {
    \flute
    \bar "|."
  }
  \layout { }
}
