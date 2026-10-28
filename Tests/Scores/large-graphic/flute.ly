%% Migrated from Dorico's MusicXML by build.py (musicxml2ly); edited by hand from here on
\pointAndClickOff

%% additional definitions required by the score:
% \accs-ornament
% --------------
%
% Position the `above` and `below` markup lists as vertical stacks
% above and below markup `script`, respectively.  `above` and `below`
% are by default horizontally centered on `script` (controlled by the
% property `acc-dir`), printed at a size given by the property
% `acc-font-size` (default value -5), and a color given by the
% property `acc-color` (default is black).  Between all markups a
% vertical space given by the property `acc-padding` (default value
% 0.2) is inserted.  The `above` stack grows from bottom to top, while
% the `below` stack grows from top to bottom.
%
% If either `above` or `below` is an empty argument, or if `script` is
% set to `#f`, the corresponding argument is not printed.
%
% If an element of `above`, `script`, or `below` is a plain string,
% check the following.
%
% * If the string consists entirely of one or more characters from the
%   accidental set '♮♭♯𝄪𝄫' (not counting a possible enclosure), add
%   `\number` internally as a prefix to use the Emmentaler font.
%
% * Otherwise the element is taken as a glyph name (again not counting
%   a possible enclosure), to be internally accessed with the
%   `\musicglyph` command.
%
% * (Not for `script`.)  If an element of `above` or `below` is a
%   plain string and the first and last character is `(` and `)`,
%   respectively, the element gets enclosed in parentheses.  The same
%   holds for `[` and `]`, enclosing the element in brackets.  The
%   font size of the enclosure characters is controlled by the
%   property `enclosure-font-size` (default value -2).
%
% Example:
%
% ```
% \markup \override #'(acc-padding . 0.5)
%         \accs-ornament { "♭" "(♯)" } "scripts.haydnturn" {}
% ```

#(define-markup-command (accs-ornament layout props
                                       above script below)
   (markup-list? markup? markup-list?)
   #:properties ((acc-font-size -5)
                 (acc-color black)
                 (acc-padding 0.3)
                 (acc-dir CENTER)
	         (enclosure-font-size -2))

   (define enclosure-regex
     ;; `(?(-3) ...)` is a 'conditional subpattern' that is only
     ;; considered for matching if the subpattern three opening
     ;; parentheses earlier (i.e., the first group) matches.
     (ly:make-regex "(?x) ^ ( [([] ) ?
                            ( [^]()[] + )
                            ( (?(-3) [])] ) ) $"))

   (define charset:accidentals (string->char-set "♮♭♯𝄪𝄫"))

   (define (musicglyph-or-number-markup arg)
     (if (string-every charset:accidentals arg)
         (make-number-markup arg)
         (make-musicglyph-markup arg)))

   (define (with-enclosure-markup arg)
     (let ((match (ly:regex-exec enclosure-regex arg)))
       (if match
           (let* (;; `left` is `#f` if there is no enclosure.
                  (left (ly:regex-match-substring match 1))
                  (left (if left
                            (make-normalsize-markup
                             (make-fontsize-markup
                              enclosure-font-size left))
                            #f))
                  (glyph (ly:regex-match-substring match 2))
                  ;; `right` is `""` if there is no enclosure.
                  (right (ly:regex-match-substring match 3))
                  (right (if (string-null? right)
                             #f
                             (make-normalsize-markup
                              (make-fontsize-markup
                               enclosure-font-size right)))))
             (make-concat-markup
              (list
               (or left "")
               (musicglyph-or-number-markup glyph)
               (or right ""))))
           #f)))

   (define (to-markup arg enclosure)
     (if (string? arg)
	 (if (string-null? arg)
             #f
             (if enclosure
                 (with-enclosure-markup arg)
                 (musicglyph-or-number-markup arg)))
         arg))

   (define (make-acc-stencil arg)
     (if arg
         (interpret-markup
          layout props
          (make-halign-markup
           acc-dir
           (make-with-color-markup
            acc-color
            (make-fontsize-markup
             acc-font-size arg))))
         #f))

   (let* ((above (map (lambda (x) (to-markup x #t)) above))
          (above-stils (map (lambda (x)
                              (make-acc-stencil x))
                            above))

          (script (to-markup script #f))
          (script-stil (if script
                           (interpret-markup layout props script)
                           empty-stencil))

          (below (map (lambda (x) (to-markup x #t)) below))
          (below-stils (map (lambda (x)
                              (make-acc-stencil x))
                            below))

          (script-stil (fold (lambda (elem previous)
                               (ly:stencil-combine-at-edge
                                previous Y UP elem acc-padding))
                             script-stil
                             above-stils))
          (script-stil (fold (lambda (elem previous)
                               (ly:stencil-combine-at-edge
                                previous Y DOWN elem acc-padding))
                             script-stil
                             below-stils)))
     script-stil))


% \acc-ornament
% -------------
%
% This function behaves similar to `\accs-ornament` with the
% difference that `above` and `below` are single markups, not markup
% lists.  If one of the arguments is an empty string, it is not
% printed.
%
% Example:
%
% ```
% \markup \acc-ornament "[♭]" "scripts.turn" ♯
% ```

#(define-markup-command (acc-ornament layout props
                                      above script below)
   (markup? markup? markup?)
   #:properties (accs-ornament-markup)
   (accs-ornament-markup layout props
                         (if (and (string? above) (string-null? above))
                             '()
                             (list above))
                         (if (and (string? script) (string-null? script))
                             #f
                             script)
                         (if (and (string? below) (string-null? below))
                             '()
                             (list below))))


% Some shorthands to make the usage of `\acc-ornament` more
% comfortable for simple cases.


ornament =
#(define-music-function (above script below)
   (string? string? string?)
   #{
     \tweak parent-alignment-X #CENTER
     \tweak self-alignment-X #CENTER
     -\markup \acc-ornament #above #script #below
   #})


% a trill with its upper note's accidental above it; the MIDI plays it (\midiTrills, defs.ily)
accTrill =
#(define-music-function (above)
   (string?)
   (let ((ev #{
     \tweak parent-alignment-X #CENTER
     \tweak self-alignment-X #CENTER
     -\markup
        \override #'((acc-dir . -1.3)
                     (acc-padding . -0.4))
        \acc-ornament #above "scripts.trill" ""
   #}))
     (ly:music-set-property! ev 'trill-upper above)
     ev))


#(define-markup-command (trill-acc-tweak layout props above)
   (string?)
   (interpret-markup
    layout props
    #{
      \markup
        \override #'((acc-dir . -1.3)
                     (acc-padding . -0.4))
        \with-dimension-from #X
          \with-true-dimension #X \musicglyph "scripts.trill"
            \acc-ornament
              #above
              \with-true-dimension #X \musicglyph "scripts.trill"
          ""
    #}))


% `color` and `size` are optional.  If `size` is present, `color` must
% be present, too.  `size` also sets the `enclosure-font-size`
% property (three magsteps larger).
trillTweak =
#(define-music-function (acc color size music)
   (string? (color? black) (number?) ly:music?)
   (let* ((override (list `(acc-color . ,color)))
          (override (if size
                        (cons `(enclosure-font-size . ,(+ size 3))
                         (cons `(acc-font-size . ,size) override))
                        override)))
     #{
       \tweak bound-details.left.text
         \markup \override #override
                   \trill-acc-tweak #acc
       #music
     #}))

\layout {
  \context {
    \Staff
    printKeyCancellation = ##f
  }
  \context {
    \Score
    autoBeaming = ##f
  }
}
flute = {
  \clef "treble" \time 54/4 \key c \major
  s8 \improvisation 1 {
  d'1 \wind #1 \timeField "improvise gradually more pitch" "30″"
  s8*15 a'1 \wind #1 g'1 \wind #0.75
  s8*15 e'1 \wind #1 r4 d'8 \wind #0.75 [ e'8 \wind #0.75 a'8 \wind #0.75 g'8 \wind #0.75 ]
  d''8 \wind #0.5 r8 c''1 \wind #0.75 g'1 \wind #0.5 a'1 \wind #0.5
  s8*13 \stopTextSpan
  } | % 1
  \time 2/4 \tempo 4 = 120 \tuplet 5/4 {
    c''16 ^( [ d''16 e''16 g''16 a''16 ) ] }
  \tuplet 5/4 {
    c'''16 ^( [ a''16 g''16 e''16 d''16 ) ] } | % 2
  \time 8/4
  \improvisation 2 { \slapOn
  e'8 \timeField "improvise gradually growing" "30″" s8 e'8 d'8 s8 a'8 g'8 c''8 s8
  \featherOn e'8 [ d'8 a'8 ] g'8 [ c''8 ] \featherOff \slapOff
  s4 \stopTextSpan
  } | % 3
  \time 7/4 \tempo "Lyrical and Rubato" 4 = 80 a'4 ^( e'4
  d''1 ^\fermata ) s4 \caes | % 4
  a'4 _( d'4 e'1 ^\fermata ) s4 \caes | % 5
  \time 6/4 gis'4 ^( fis'4 cis''4 b'4 fis''!2 | % 6
  \time 7/4 es''4 f''?4 bes''1 ^\longfermata )
  s4 \caes | % 7
  a'4 _( d'4 e'?1 ^\fermata ) s4 \caes | % 8
  a'4 ^( g'4 c''1 ^\fermata ) s4 \caes | % 9

  \barNumberCheck #10
  a'4 _( d'4 e'1 ^\longfermata ) s4 \caes | % 10
  cis''4 ^( b'4 e''1 ^\fermata ) s4 \caes | % 11
  \time 3/4 \tempo 4 = 120 \tuplet 5/4 {
    as''16 ^( [ bes''16 c'''?16 es'''16 f'''16 ) ] }
  \tuplet 5/4 {
    as'''!16 ^( [ f'''16 es'''16 c'''16 bes''16 ) ] }
  s4 \caes | % 12
  \time 7/4 \tempo 4 = 80 cis''4 ^( gis'4 f''!1 ^\fermata ) s4 \caes | % 13
  \time 3/4 \tempo 4 = 120 \tuplet 5/4 {
    gis''16 ^( [ a''16 c'''?16 es'''16 f'''16 ) ] }
  \tuplet 5/4 {
    gis'''!16 ^( [ f'''16 es'''16 c'''16 a''16 ) ] }
  s4 \caes | % 14
  \time 11/4 \tempo 4 = 80 e'?4 ^( d'4 f'4 e'4 g'?8 [ f'8 b'8 g'8
  ] d''1 ^\fermata ) s4 \caes | % 15
  \time 3/4 \tempo 4 = 120 \tuplet 6/4 {
    a''16 ^( [ gis''16 e'''16 c'''16 gis'''!16 f'''16 ) ] }
  \tuplet 6/4 {
    a'''16 ^( [ gis'''16 f'''16 e'''16 c'''16 a''16 ) ] }
  s4 \caes | % 16
  \tuplet 6/4 {
    a''16 ^( [ gis''16 e'''16 b''16 gis'''!16 f'''16 ) ] }
  \tuplet 6/4 {
    a'''16 ^( [ gis'''16 f'''16 e'''16 b''16 a''16 ) ] }
  s4 \caes | % 17
  \time 7/4 gis''1 ^\trill \tuplet 6/4 {
    a''16 ^( [ gis''16 e'''16 bes''16 gis'''!16 f'''16 ) ] }
  \tuplet 6/4 {
    a'''16 ^( [ gis'''16 f'''16 e'''16 bes''16 a''16 ) ] }
  s4 \caes | % 18
  \time 7/4 \tempo 4 = 80 c'''4 ^( f''4 g''?1 ^\fermata ) s4 \caes | % 19

  \barNumberCheck #20
  \time 12/4 e''8 ^( [ dis''8 g''8 f''8 ] c'''4 ) \featherOnce g''32 ^( [ c'''32 dis'''!32
  e'''32 fis'''32 e'''32 dis'''32 c'''32 ) ] \featherOnce e''32 ^( [ fis''!32 g''32 c'''32
  dis'''32 c'''32 g''32 fis''32 ) ] e''2 ^\accTrill "♯" \once \override
  Beam.gap-count = 3 \repeat tremolo 8 { gis''32 ^( e''32 ) } \featherBackOnce gis''32 ^( [ e''32
  gis''32 e''32 gis''32 e''32 gis''32 e''32 ) ] \featherOnce as''32 ^( [ g''32 bes''32 a''32
  ) dis'''32 ^( b''32 a''32 as''32 ) g''32 ^( es''32 a''32 gis''32 ) c'''32 ^(
  bes''32 as''32 g''32 ) ] | % 20
  \time 14/4 \featherOnce f'''?32 ^( [ es'''32
  d'''?32 c'''32 bes''32 as''32 g''32 f''?32 es''!32 d''?32 c''32 bes'!32 as'!32
  g'32 f'32 es'!32 ) ] es'1 ^\trill s4 \caes b'4 _( fis'4 gis'1 ^\fermata ) s4 \caes | % 21
  \time 42/4 \once \override Score.MetronomeMark.padding = #5 \tempo 4 = 80
  s4 as'4 _( \timeField \markup \concat {
    "improvise on D" \hspace #0.15 \raise #0.4 \fontsize #-3 \flat ", E" \hspace #0.15
    \raise #0.4 \fontsize #-3 \flat ", A" \hspace #0.15 \raise #0.4 \fontsize #-3 \flat } "30″"
  des'4 es'1 ) s2 as'4 ^(
  es''!4 des''!1 ) s2. es'4 ^( des''1 ) s1. des'''!\breve \shapedTrill "♭" #'(0.2 1 0.2) s4 \stopTrillSpan
  s4*3 s4 \stopTextSpan | % 22
  \time 3/4 \tempo 4 = 120 \tuplet 5/4 {
    as''16 ^( [ bes''16 c'''16 es'''16 f'''16 ) ] }
  \tuplet 5/4 {
    as'''!16 ^( [ f'''16 es'''16 c'''16 bes''16 ) ] }
  s4 \caes | % 23
  \time 7/4 \tempo 4 = 80 cis''4 ^( gis'4 g''?1 ^\fermata ) s4 \caes | % 24
  \time 3/4 \tempo 4 = 120 \tuplet 5/4 {
    gis''16 ^( [ b''16 c'''?16 es'''16 f'''16 ) ] }
  \tuplet 5/4 {
    gis'''!16 ^( [ f'''16 es'''16 c'''16 b''16 ) ] }
  s4 \caes | % 25
  \time 11/4 \tempo 4 = 80 e'?4 _( des'4 \accelSpan as'4 g'?4 es'8 [ des'8 as'8 g'8 ) ] \tuplet 5/4 {
    des''!16 ^( [ c''16 es''!16 des''16 c'''16 ) ] }
  fis''1 \shapedTrill "♮" #'(0.2 1 0.2) | % 26
  \time 3/4 f''?16 \stopTrillSpan ^( [ e''?16 c'''16 b''16 ) ] \tuplet 6/4 {
    e'''?16 ^( [ c'''16 b''16 as''16 f''16 e''16 ) ] }
  s4 \caes | % 27
  \time 4/4 \tempo 4 = 120 \featherOnce f'''32 \stopTextSpan ^( [ e'''32 a'''?32 gis'''32 f'''32
  e'''32 c'''32 a''?32 ) ] s4 \caesTight \featherOnce f'''32 ^( [ e'''32 a'''32 gis'''32 f'''32 e'''32
  b''32 a''32 ) ] s4 \caesTight | % 28
  \time 3/4 \tuplet 5/4 {
    b'''16 ^> ^( [ a'''16 as'''16 ges'''16 f'''16 ) ] }
  \tuplet 5/4 {
    b'''16 ^> ^( [ a'''16 as'''16 ges'''16 f'''16 ) ] }
  \tuplet 5/4 {
    b'''16 ^> ^( [ a'''16 as'''16 ges'''16 f'''16 ) ] }
  | % 29

  \barNumberCheck #30
  \time 7/4 ges'''1 ^\accTrill "♭" f'''2 r4 | % 30
  e'''2 ^\accTrill "♯" \once \override Beam.gap-count = 3 \repeat tremolo 16 {
    gis''32 ^( e''32 ) } r4 | % 31
  R4*7 | % 32
  R4*7 | % 33
  R4*7 | % 34
  R4*7 | % 35
  R4*7 | % 36
  R4*7 | % 37
  R4*7 | % 38
  R4*7 | % 39

  \barNumberCheck #40
  R4*7 | % 40
  R4*7 | % 41
  R4*7 | % 42
  \time 1/4 R4 | % 43
  \time 10/4 R2*5 \bar "|."
}

% The dynamics and hairpins, apart from the notes so they can start and end anywhere
fluteDynamics = {
  s4*1/2 <>\p\< s4*2 <>\> s4*2 <>\! s4*15/2 <>\< s4*2 <>\> s4*2 <>\< s4*2 <>\> s4*2 <>\! s4*15/2 <>\< s4*2 <>\> s4*2 <>\! s4 <>\mp\< s4*2 <>\! s4 <>\mf\< s4*25/4 <>\> s4*23/4 <>\! s4*13/2 |
  % 2
  <>\f s4*2 |
  % 3
  <>\p s4*8 |
  % 4
  <>\p\< s4*7/2 <>\> s4*7/2 |
  % 5
  <>\< s4*7/2 <>\> s4*7/2 |
  % 6
  <>\< s4*6 |
  % 7
  s4*2 <>\f s4*5 |
  % 8
  <>\p\< s4*3 <>\> s4*3 <>\< s4 |
  % 9
  s4*3 <>\> s4*4 |
  % 10
  <>\< s4*2 <>\> s4*4 <>\! s4 |
  % 11
  s4*7 |
  % 12
  s4*3 |
  % 13
  <>\p s4*7 |
  % 14
  s4*3 |
  % 15
  <>\p\< s4*6 <>\f\> s4*4 <>\p s4 |
  % 16
  s4*3 |
  % 17
  s4*3 |
  % 18
  s4*7 |
  % 19
  s4*7 |
  % 20
  s4*12 |
  % 21
  <>\< s4*2 <>\> s4*4 <>\! s4*8 |
  % 22
  s4*29 <>\niente\< s4*4 <>\f\> s4*4 <>\niente s4*5 |
  % 23
  s4*3 |
  % 24
  <>\p s4*7 |
  % 25
  s4*3 |
  % 26
  <>\p s4*11 |
  % 27
  s4*3 |
  % 28
  s4*4 |
  % 29
  s4*3 |
  % 30
  s4*7 |
  % 31
  s4*7 |
  % 32
  s4*7 |
  % 33
  s4*7 |
  % 34
  s4*7 |
  % 35
  s4*7 |
  % 36
  s4*7 |
  % 37
  s4*7 |
  % 38
  s4*7 |
  % 39
  s4*7 |
  % 40
  s4*7 |
  % 41
  s4*7 |
  % 42
  s4*7 |
  % 43
  s4 |
  % 44
  s4*10
}

% The aleatoric boxes (bars 1, 3, 22), each from its first note's start to its last note's end
fluteBoxes = {
  s8 s1 \startBox \startFloor s4*15/2 \stopBox \stopFloor s1*2 \startBox \startFloor s4*15/2 \stopBox \stopFloor s4*20 \startBox \startFloor s4*13/2 \stopBox \stopFloor | % 1
  s4*2 | % 2
  s8 \startBox \startFloor s8 \stopBox \stopFloor s4 \startBox \startFloor s8 \stopBox \stopFloor s4. \startBox \startFloor s8 \stopBox \stopFloor s4*5/2 \startBox \startFloor s4 \stopBox \stopFloor | % 3
  s4*7 | % 4
  s4*7 | % 5
  s4*6 | % 6
  s4*7 | % 7
  s4*7 | % 8
  s4*7 | % 9
  s4*7 | % 10
  s4*7 | % 11
  s4*3 | % 12
  s4*7 | % 13
  s4*3 | % 14
  s4*11 | % 15
  s4*3 | % 16
  s4*3 | % 17
  s4*7 | % 18
  s4*7 | % 19
  s4*12 | % 20
  s4*14 | % 21
  s4 s4*6 \startBox \startFloor s2 \stopBox \stopFloor s4*6 \startBox \startFloor s4*3 \stopBox \stopFloor s4*5 \startBox \startFloor s4*6 \stopBox \stopFloor
  s1*2 -\tweak details.top #10 \startBox \startFloor s4*5 \stopBox \stopFloor | % 22
  s4*3 | % 23
  s4*7 | % 24
  s4*3 | % 25
  s4*11 | % 26
  s4*3 | % 27
  s4*4 | % 28
  s4*3 | % 29
  s4*7 | % 30
  s4*7 | % 31
  s4*7 | % 32
  s4*7 | % 33
  s4*7 | % 34
  s4*7 | % 35
  s4*7 | % 36
  s4*7 | % 37
  s4*7 | % 38
  s4*7 | % 39
  s4*7 | % 40
  s4*7 | % 41
  s4*7 | % 42
  s4 | % 43
  s4*10 | % 44
}

% The heavy links between the boxes, and the arrow out of the last box of each bar
fluteLinks = {
  s4*9/2 s4*15/2 \startLink s1*2 \stopLink s4*15/2 \startLink s4*20 \stopLink s4*13/2 \startArrow | % 1
  s4*2 \stopLink | % 2
  s8 s8 \startLink s4 \stopLink s8 \startLink s4. \stopLink s8 \startLink s4*5/2 \stopLink s4 \startArrow | % 3
  s4*7 \stopLink | % 4
  s4*7 | % 5
  s4*6 | % 6
  s4*7 | % 7
  s4*7 | % 8
  s4*7 | % 9
  s4*7 | % 10
  s4*7 | % 11
  s4*3 | % 12
  s4*7 | % 13
  s4*3 | % 14
  s4*11 | % 15
  s4*3 | % 16
  s4*3 | % 17
  s4*7 | % 18
  s4*7 | % 19
  s4*12 | % 20
  s4*14 | % 21
  s4*7 s2 \startLink s4*6 \stopLink s4*3 \startLink s4*5 \stopLink s4*6 \startLink s1*2 \stopLink s4*5 \startArrow | % 22
  s4*3 \stopLink | % 23
  s4*7 | % 24
  s4*3 | % 25
  s4*11 | % 26
  s4*3 | % 27
  s4*4 | % 28
  s4*3 | % 29
  s4*7 | % 30
  s4*7 | % 31
  s4*7 | % 32
  s4*7 | % 33
  s4*7 | % 34
  s4*7 | % 35
  s4*7 | % 36
  s4*7 | % 37
  s4*7 | % 38
  s4*7 | % 39
  s4*7 | % 40
  s4*7 | % 41
  s4*7 | % 42
  s4 | % 43
  s4*10 | % 44
}

% Playback: the hidden tempo changes of the Dorico score's playback, unchanged -- bar 1 at 100
% and bar 3 at 16 (the 30-second improvisations), and the holds of the fermatas and caesuras in
% bars 4-10. From bar 11 (added in LilyPond): a fermata on a whole note at 60 (4 s), the caesura
% after it at 30 (2 s); a caesura after a fast gesture at 60 (1 s). They shape the MIDI and the
% cue times (timing.ily) but are not printed.
flutePlayback = {
  \playTempo 100 s4*54 | % 1
  s4*2 | % 2
  \playTempo 16 s4*8 | % 3
  s4*2 \playTempo 60 s4*4 \playTempo 20 s4 | % 4
  \playTempo 80 s4*2 \playTempo 20 s4*2 \playTempo 60 s4*3 | % 5
  \playTempo 80 s4*6 | % 6
  s4*2 \playTempo 50 s4*4 \playTempo 10 s4 | % 7
  \playTempo 80 s4*2 \playTempo 60 s4*4 \playTempo 80 s4 | % 8
  s4*2 \playTempo 20 s4*2 \playTempo 60 s4*3 | % 9
  \playTempo 80 s4*2 \playTempo 30 s4*4 \playTempo 12 s4 | % 10   (long fermata 8 s, caesura 5 s)
  \playTempo 80 s4*2 \playTempo 60 s4*4 \playTempo 30 s4 | % 11
  s4*2 \playTempo 60 s4 | % 12
  s4*2 \playTempo 60 s4*4 \playTempo 30 s4 | % 13
  s4*2 \playTempo 60 s4 | % 14
  s4*6 \playTempo 60 s4*4 \playTempo 30 s4 | % 15
  s4*2 \playTempo 60 s4 | % 16
  \playTempo 120 s4*2 \playTempo 60 s4 | % 17
  \playTempo 120 s4*6 \playTempo 60 s4 | % 18
  s4*2 \playTempo 60 s4*4 \playTempo 30 s4 | % 19
  \playTempo 80 s4*12 | % 20
  s4*6 \playTempo 30 s4 \playTempo 80 s4*2 \playTempo 60 s4*4 \playTempo 30 s4 | % 21
  s4 \playTempo #3280/39 s4*41 | % 22   (a 30 s time field: 0.75 s + 41 beats in 29.25 s)
  s4*2 \playTempo 60 s4 | % 23
  s4*2 \playTempo 60 s4*4 \playTempo 30 s4 | % 24
  s4*2 \playTempo 60 s4 | % 25
  s4 \playAccel 80 120 #12                % 26-27: accel. from beat 2, 80 -> 120 in 12 beats
  \playTempo 60 s4 | % 27
  s4 \playTempo 60 s4 \playTempo 120 s4 \playTempo 60 s4 | % 28
  \playTempo 120 s4*3 | % 29
  s4*7 | % 30
  s4*7 | % 31
  s4*7 | % 32
  s4*7 | % 33
  s4*7 | % 34
  s4*7 | % 35
  s4*7 | % 36
  s4*7 | % 37
  s4*7 | % 38
  s4*7 | % 39
  s4*7 | % 40
  s4*7 | % 41
  s4*7 | % 42
  s4 | % 43
  s4*10 <>\improvMark "end" | % 44
}
