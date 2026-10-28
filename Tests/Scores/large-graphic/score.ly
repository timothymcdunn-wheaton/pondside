\version "2.26.0"
% ...as the wind whispers sweet nothings -- full score (flute and electronics)

\include "defs.ily"
\include "flute.ly"
\include "graphics.ily"
% TEMPORARY composing aid: each cue's time next to its box. Not part of the score;
% delete this line (and cue-times.ily) before the score is finished.
\include "cue-times.ily"
\include "electronics.ly"
\include "timing.ily"

\header {
  % Didot: hairline serifs (the title not bold)
  title = \markup \override #'(font-name . "Didot") \abs-fontsize #22 "...as the wind whispers sweet nothings"
  composer = \markup \override #'(font-name . "Didot") \abs-fontsize #11 "Timothy W McDunn"
  tagline = ##f
}

\paper {
  #(set-paper-size "a4landscape")
  top-margin = 10\mm
  bottom-margin = 18\mm
  left-margin = 30\mm
  right-margin = 28\mm
  % the staves of a system as close as they go; the room left on the page goes between the
  % systems, evenly, on every page (the last too)
  system-system-spacing = #'((basic-distance . 12) (minimum-distance . 8) (padding . 2)
                             (stretchability . 100))
  score-system-spacing.basic-distance = #14
  ragged-bottom = ##f
  ragged-last-bottom = ##f
  print-first-page-number = ##f
}

% Systems and pages as in the Dorico score
structure = {
  \autoLineBreaksOff \autoPageBreaksOff
  s4*54 s4*2 \break |                            % 1-2
  s4*8 s4*7 \break |                             % 3-4
  s4*7 s4*6 s4*7 \pageBreak |                               % 5-7
  s4*7 s4*7 s4*7 \break |                                   % 8-10
  s4*7 s4*3 s4*7 s4*3 \break |                              % 11-14
  s4*11 s4*3 \pageBreak |                                   % 15-16
  s4*3 s4*7 s4*7 \break |                                   % 17-19
  s4*12 \break |                                            % 20
  s4*14 \pageBreak |                                        % 21
  s4*42 \break |                                 % 22
  s4*3 s4*7 s4*3 \break |                                   % 23-25
  s4*11 s4*3 \pageBreak |                                   % 26-27
  % bar 28: less room after the fanned figures (the hidden rests), the 32nds as they were
  \newSpacingSection \override Score.SpacingSpanner.spacing-increment = #0.75
  s4*4 \newSpacingSection \revert Score.SpacingSpanner.spacing-increment s4*3 \break |                                        % 28-29
  s4*7 s4*7 \break |                                        % 30-31
  \repeat unfold 11 { s4*7 | } s4 | s4*10                   % 32-44
}

\score {
  <<
    \new Staff = "flute" \with {
      instrumentName = "Flute"
      shortInstrumentName = "Fl."
    } <<
      \new Voice = "flute" \removeWithTag #'played \flute
      % in the flute's own voice, so a dynamic on a note is placed by that note
      \context Voice = "flute" \fluteDynamics
      \new Voice \fluteBoxes
      \new Voice \fluteLinks
      \new Voice \flutePlayback
      \new Devnull \structure
    >>
    \new PianoStaff \with {
      \remove Keep_alive_together_engraver   % the bass staff comes and goes on its own
      \omit Rest \omit MultiMeasureRest      % no rests on the electronics staves
      instrumentName = "Electronics"
      shortInstrumentName = "Elect."
    } <<
      \new Staff = "elecUp" \with {
        % the collections: stemless noteheads in parentheses
        \omit Stem \omit Flag \omit Beam
      } <<
        \new Voice \with { \collectionStyle } \electronics
        \new Voice \electronicsCues
        \new Voice \electronicsGraphics
        \new Voice \electronicsArc
        \new Voice \electronicsFanStaff
        \new Voice \electronicsBursts
      >>
      \new Staff = "elecDown" \with {
        % shown from bar 5 (pb5's low swells), as in the Dorico score
        \RemoveAllEmptyStaves
        keepAliveInterfaces = #'(multi-measure-rest-interface rest-interface note-head-interface)
      } << \electronicsBass \\ \electronicsLowGraphics >>
    >>
  >>
  \layout {
    \context {
      \Score
      \omit TimeSignature                 % no meters: bars are proportioned by their content
      measureBarType = #"'"               % tick barlines
      \override MetronomeMark.font-size = #-1
      \override BarNumber.font-shape = #'italic
      % hairpins long enough to read, even under a single held note
      \override Hairpin.minimum-length = #4
      \override Hairpin.springs-and-rods = #ly:spanner::set-spacing-rods
      % tuplets: the number only (each tuplet is beamed on its own)
      \override TupletBracket.bracket-visibility = ##f
    }
    \context {
      \Staff
      \override TupletNumber.font-series = #'bold
      % staves as close as their contents allow (skylines), never stretched
      \override VerticalAxisGroup.staff-staff-spacing =
        #'((basic-distance . 0) (minimum-distance . 0) (padding . 1.0) (stretchability . 0))
    }
    \context {
      \PianoStaff
      \override StaffGrouper.staff-staff-spacing =
        #'((basic-distance . 0) (minimum-distance . 0) (padding . 1.0) (stretchability . 0))
      \override StaffGrouper.staffgroup-staff-spacing =
        #'((basic-distance . 0) (minimum-distance . 0) (padding . 1.0) (stretchability . 0))
    }
  }
}

% Soli Deo gloria, under the last system on the right
\markup \fill-line { "" \italic "SDG" }

% The MIDI for the audio render (lilypond/export_piece.sh): the flute alone, its improvisations
% silent (SuperCollider renders them), with the tempo marks of the printed score
\score {
  \new Staff \with { midiInstrument = "flute" } <<
    % (\unfoldRepeats: the tremolos play as the alternating 32nds they stand for)
    \new Voice \unfoldRepeats \midiTrills \removeWithTag #'printed \flute
    \new Voice \fluteDynamics
    \new Voice \flutePlayback
  >>
  % the dynamics are a voice of their own (fluteDynamics): read them for the whole staff, or
  % they reach no notes (every note would play at the same velocity)
  \midi {
    \context { \Voice \remove Dynamic_performer }
    % and over the full range (LilyPond's flute default squeezes p..f into velocities 48-66)
    \context { \Staff \consists Dynamic_performer
               midiMinimumVolume = #0.15 midiMaximumVolume = #1 }
  }
}
