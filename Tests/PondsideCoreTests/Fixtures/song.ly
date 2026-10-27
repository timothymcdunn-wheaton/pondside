\version "2.24.0"
% A song: lyrics, chord names, Scheme, embedded music and markup.

#(set-global-staff-size 19)

\paper {
  indent = 0\mm
  ragged-last-bottom = ##t
}

dolce = \markup { \italic "dolce" }

swing = #(define-music-function (m) (ly:music?)
  #{ \tempo "Swing" 4 = 132 $m #})

melody = \relative c' {
  \key g \major
  \time 4/4
  \partial 4 d8 e |
  g4 g8 a b4. a8 |
  g4-\dolce e d2 |
  e8 fis g a b4 \once \override NoteHead.color = #red c |
  d2. r8 d, |
  e4 g8[ fis] e[ d] c4 |
  b'2 a4. g8 |
  g1 \bar "|."
}

harmonies = \chordmode {
  \partial 4 s4 |
  g1 | e:m | c2 a:m7 | d1:7 |
  c1 | d:7 | g |
}

words = \lyricmode {
  Here we go a -- long the road,
  sing -- ing as we go, __
  la la la la la la la,
  "home" a -- gain.
}

\score {
  <<
    \new ChordNames \harmonies
    \new Voice = "mel" { \swing \melody }
    \new Lyrics \lyricsto "mel" \words
  >>
  \layout { }
}
