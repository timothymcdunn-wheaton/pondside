% Definitions shared by the score's music files (score.ly includes this first).

%% ------------------------------------------------------------------ geometry helpers

% X extent of a spanner's bound (LEFT or RIGHT), relative to the spanner itself
#(define (bound-x-extent grob dir)
   (let* ((b (ly:spanner-bound grob dir))
          (common (ly:grob-common-refpoint grob b X)))
     (coord-translate (ly:grob-extent b common X)
                      (- (ly:grob-relative-coordinate grob common X)))))

% Y extent of a spanner's bound, relative to the spanner
#(define (bound-y-extent grob dir)
   (let* ((b (ly:spanner-bound grob dir))
          (common (ly:grob-common-refpoint grob b Y)))
     (coord-translate (ly:grob-extent b common Y)
                      (- (ly:grob-relative-coordinate grob common Y)))))

#(define (detail grob key default)
   (assoc-get key (ly:grob-property grob 'details '()) default))

% a grob that draws but takes no room: it neither pushes other things nor reserves space
#(define no-skylines
   (ly:make-unpure-pure-container
    (lambda (grob) (ly:skylines-for-stencil empty-stencil X))))

%% ------------------------------------------------------------------ aleatoric boxes

% Boxes, the heavy links between them and the arrow out of the last one are spanners in a voice
% of their own made of skips (fluteBoxes), so each starts and ends at an exact moment: a box
% from its first note's start to its last note's end, a link from there to the next box.
%   s4*2 \startBox s4*4 \stopBox \startLink s4*2 \stopLink \startBox ...
% Tweaks (staff spaces): \tweak details.top #9 \startBox (also bottom, pad); the bottom is
% otherwise just below the box's contents (its floor).

% X of a line spanner's bound (LEFT/RIGHT), relative to the spanner
#(define (span-x grob dir)
   (let* ((info (ly:grob-property grob (if (= dir LEFT) 'left-bound-info 'right-bound-info)))
          (sys (ly:grob-system grob)))
     (- (assoc-get 'X info) (ly:grob-relative-coordinate grob sys X))))

% What a box holds: the flute's notes, rests, accidentals, flags, dots, scripts (trills,
% fermatas, wind circles) and dynamics between its moments, on its staff
#(define box-content-interfaces
   '(note-head-interface rest-interface accidental-interface flag-interface dots-interface
     script-interface text-script-interface dynamic-interface hairpin-interface
     trill-spanner-interface))

% the moment a grob belongs to (a spanner: its start)
#(define (grob-when g)
   (let ((col (if (ly:spanner? g)
                  (ly:item-get-column (ly:spanner-bound g LEFT))
                  (ly:item-get-column g))))
     (and col (ly:grob-property col 'when #f))))

% a grob's X extent on its system; line spanners report none, so measure their drawing
#(define (grob-x-extent g sys)
   (if (grob::has-interface g 'line-spanner-interface)
       (let ((st (ly:grob-property g 'stencil #f)))
         (if (ly:stencil? st)
             (coord-translate (ly:stencil-extent st X) (ly:grob-relative-coordinate g sys X))
             '(+inf.0 . -inf.0)))
       (ly:grob-extent g sys X)))

% every shaped trill, as laid out (a box holds the trills in it)
#(define laid-out-trills '())
#(define (register-trill grob) (set! laid-out-trills (cons grob laid-out-trills)))

% every box, as laid out on its line (for the links to find)
#(define laid-out-boxes '())
#(define (register-box grob) (set! laid-out-boxes (cons grob laid-out-boxes)))

% The box's left and right edges, relative to it: around what it holds, padded the same on both
% sides (details.pad), so it is centred on its gesture however long the last note is. Without
% contents: from its first moment to its last.
#(define (box-edges grob)
   (let* ((sys (ly:grob-system grob))
          (x0 (ly:grob-relative-coordinate grob sys X))
          (lx (span-x grob LEFT)) (rx (span-x grob RIGHT))
          (pad (detail grob 'pad 1.0))
          (from (ly:grob-property (ly:spanner-bound grob LEFT) 'when))
          (to (ly:grob-property (ly:spanner-bound grob RIGHT) 'when))
          (inside
           (filter-map
            (lambda (g)
              (and (any (lambda (i) (grob::has-interface g i)) box-content-interfaces)
                   (not (memq g laid-out-floors))                      ; not the box's floor
                   (not (eq? (ly:grob-common-refpoint g grob Y) sys))   ; this staff
                   (let ((w (grob-when g))
                         (e (coord-translate (grob-x-extent g sys) (- x0))))
                     (and w (not (ly:moment<? w from))
                          ; up to its last moment, and a dynamic ending there (a hairpin's n)
                          (or (ly:moment<? w to)
                              (and (equal? w to) (grob::has-interface g 'dynamic-text-interface)))
                          (not (interval-empty? e))
                          ; texts: only symbols (wind circles), not words such as the
                          ; time field's label
                          (or (not (grob::has-interface g 'text-script-interface))
                              (< (interval-length e) 3))
                          e))))
            (append (ly:grob-array->list (ly:grob-object sys 'all-elements))
                    ; spanners are not among a system's elements: those registered
                    (filter (lambda (t) (eq? (ly:grob-system t) sys)) laid-out-trills)))))
     (if (null? inside)
         (cons (- lx pad) (+ rx 0.4))
         (cons (- (apply min (map car inside)) pad)
               ; no further than the box's last moment (hairpins run to it), or than
               ; a dynamic there
               (max (min (+ (apply max (map cdr inside)) pad) (+ rx 0.4))
                    (+ (apply max (cons -inf.0 (map cdr (filter (lambda (e) (> (cdr e) rx)) inside))))
                       pad))))))

% The box's bottom, relative to it: its floor's top (see \startFloor), i.e. just below what
% it holds; -7.5 if it has no floor
#(define (box-bottom grob)
   (let* ((sys (ly:grob-system grob))
          (floor (find (lambda (f) (and (eq? (ly:grob-system f) sys)
                                        (eq? (ly:spanner-bound f LEFT) (ly:spanner-bound grob LEFT))))
                       laid-out-floors)))
     (if floor
         (let ((common (ly:grob-common-refpoint floor grob Y)))
           (- (cdr (ly:grob-extent floor common Y)) (ly:grob-relative-coordinate grob common Y)))
         -7.5)))

#(define (aleatoric-box grob)
   (let* ((x (box-edges grob))
          (l (car x)) (r (cdr x))
          (top (detail grob 'top 5.5))
          (bottom (detail grob 'bottom (box-bottom grob)))
          (th (detail grob 'thickness 0.22)))
     (make-path-stencil
      (list 'moveto l bottom 'lineto r bottom 'lineto r top 'lineto l top 'closepath)
      th 1 1 #f)))

% the edge of the box a link comes from (dir LEFT: the nearest box ending at or before the
% link's start) or goes to (RIGHT: the nearest starting at or after its end), relative to the
% link; #f if there is none on this line
#(define (linked-box-edge grob dir)
   (let* ((sys (ly:grob-system grob))
          (at (ly:grob-property (ly:spanner-bound grob dir) 'when))
          (when-of (lambda (b) (ly:grob-property (ly:spanner-bound b (- dir)) 'when)))
          (boxes (filter (lambda (g) (and (eq? (ly:grob-system g) sys)
                                          (let ((w (when-of g)))
                                            (if (= dir LEFT)
                                                (not (ly:moment<? at w))
                                                (not (ly:moment<? w at))))))
                         laid-out-boxes))
          (box (and (pair? boxes)
                    (car (sort boxes (lambda (a b) (if (= dir LEFT)
                                                       (ly:moment<? (when-of b) (when-of a))
                                                       (ly:moment<? (when-of a) (when-of b)))))))))
     (and box
          (let ((e (box-edges box)))
            (+ (if (= dir LEFT) (cdr e) (car e))
               (- (ly:grob-relative-coordinate box sys X)
                  (ly:grob-relative-coordinate grob sys X)))))))

% a link or arrow broken at a line end is drawn on the first line only (an arrow out of the last
% box of a line ends there)
#(define (continuation? grob)
   (let ((orig (ly:grob-original grob)))
     (and orig
          (pair? (ly:spanner-broken-into orig))
          (not (eq? grob (car (ly:spanner-broken-into orig)))))))

#(define (box-link grob)
  (if (continuation? grob) empty-stencil (box-link-stencil grob)))

#(define (box-link-stencil grob)
   (let* ((l (or (linked-box-edge grob LEFT) (+ (span-x grob LEFT) (detail grob 'pad-left 0.4))))
          (r (or (linked-box-edge grob RIGHT) (- (span-x grob RIGHT) (detail grob 'pad-right 1.0))))
          (th (detail grob 'thickness 0.75))
          (arrow (detail grob 'arrow #f))
          (head-l 1.5) (head-w 0.7)
          (line-end (if arrow (- r head-l) r)))
     (ly:stencil-add
      (make-filled-box-stencil (cons l line-end) (cons (* -0.5 th) (* 0.5 th))) ; square ends
      (if arrow
          (make-path-stencil
           (list 'moveto line-end (- head-w) 'lineto r 0 'lineto line-end head-w 'closepath)
           0.1 1 1 #t)
          empty-stencil))))

#(define (fixed-span stencil)
   (lambda (music)
     #{ -\tweak stencil #stencil
        -\tweak Y-offset #0
        -\tweak outside-staff-priority ##f
        -\tweak vertical-skylines #no-skylines
        -\tweak bound-details.left.attach-dir #LEFT
        -\tweak bound-details.right.attach-dir #LEFT
        #music #}))

% (X-extent: so the box is drawn only once everything below the staff is placed, its floor too)
startBox = #((fixed-span aleatoric-box)
             #{ -\tweak X-extent #'(0 . 0) -\tweak after-line-breaking #register-box \startTextSpan #})
stopBox = \stopTextSpan
% links and arrows push their boxes apart to at least this length
% (X-extent: so the link is drawn only once the lines are laid out, when it can find its boxes)
startLink = #((fixed-span box-link)
              #{ -\tweak X-extent #'(0 . 0) -\tweak minimum-length #5 -\tweak springs-and-rods #ly:spanner::set-spacing-rods
                 \startTextSpan #})
startArrow = #((fixed-span box-link)
               #{ -\tweak X-extent #'(0 . 0) -\tweak details.arrow ##t -\tweak minimum-length #9
                  -\tweak springs-and-rods #ly:spanner::set-spacing-rods \startTextSpan #})
stopLink = \stopTextSpan

% The room a box needs below the staff, so the staff below clears it -- without the box itself
% taking room, which would push the dynamics out of it. An invisible floor along the box's
% bottom edge, placed after everything else below the staff (dynamics included), a little
% below the lowest of them (outside-staff-padding) and at least staff-padding below the staff;
% the box's bottom is drawn at the floor. Alongside each box:
%   \startBox \startFloor ... \stopBox \stopFloor
#(define laid-out-floors '())
#(define (register-floor grob) (set! laid-out-floors (cons grob laid-out-floors)))

#(define (box-floor grob)
   (let ((l (- (span-x grob LEFT) 1.0))
         (r (+ (span-x grob RIGHT) 0.4)))
     (ly:stencil-outline empty-stencil (make-filled-box-stencil (cons l r) '(-0.2 . 0)))))

startFloor = -\tweak stencil #box-floor
             -\tweak after-line-breaking #register-floor
             -\tweak direction #DOWN
             -\tweak staff-padding #1.2
             -\tweak outside-staff-priority #5000
             -\tweak outside-staff-padding #0.8
             -\tweak bound-details.left.attach-dir #LEFT
             -\tweak bound-details.right.attach-dir #LEFT
             \startTrillSpan
stopFloor = \stopTrillSpan

%% ------------------------------------------------------------------ time fields

% The improvisation brackets: "improvise ..." on a line with a hook at each end, its duration
% in a gap at the middle. \timeField "improvise gradually more pitch" "30″" on the first note,
% \stopTextSpan on the last.
% how far the text starts after the left hook (the line runs on before it)
#(define time-field-lead 2.5)

#(define (time-field-stencil label)
   (lambda (grob)
     (let* ((st (ly:line-spanner::print grob))
            (x (ly:stencil-extent st X))
            (left-text (ly:grob-property grob 'left-bound-info))
            (text-st (assoc-get 'stencil left-text empty-stencil))
            (text-w (if (ly:stencil-empty? text-st X) 0 (interval-length (ly:stencil-extent text-st X))))
            (mid (* 0.5 (+ (car x) text-w (cdr x))))
            (txt (grob-interpret-markup grob (markup #:fontsize -1 #:whiteout #:pad-x 0.6 label)))
            (line-th (* (ly:grob-property grob 'thickness 1) (ly:staff-symbol-line-thickness grob))))
       (ly:stencil-add
        st
        (make-line-stencil line-th (car x) 0 (+ (car x) time-field-lead -0.6) 0) ; line before the text
        (make-line-stencil 0.12 (car x) 0 (car x) -1.2)            ; the hooks
        (make-line-stencil 0.12 (cdr x) 0 (cdr x) -1.2)
        (ly:stencil-translate
         (ly:stencil-aligned-to (ly:stencil-aligned-to txt X CENTER) Y CENTER)
         (cons mid 0))))))

timeField =
#(define-event-function (text duration) (markup? markup?)
   #{ -\tweak bound-details.left.text \markup \concat { \hspace #time-field-lead #text \hspace #0.6 }
      -\tweak bound-details.left.stencil-align-dir-y #CENTER
      -\tweak bound-details.left.padding #-1.2
      -\tweak bound-details.right.padding #-1.6
      -\tweak staff-padding #5
      -\tweak style #'line
      -\tweak font-shape #'upright
      -\tweak thickness #0.8
      -\tweak stencil #(time-field-stencil duration)
      -\tweak outside-staff-priority #1000
      \startTextSpan #})

%% ------------------------------------------------------------------ wind tone

% Air in the tone: a circle, white for the air and black for the rest (1 = all air, an open
% circle; 0.75 = a black quarter; 0.5 = left half black). Above the note: c'1^\wind #0.75
#(define-markup-command (wind-circle layout props fraction) (number?)
   (let* ((r 0.48) (k 0.5523) (th 0.13)
          (ring (make-circle-stencil r th #f))
          (q (lambda (a) ; quarter arc from angle a (multiples of 90 deg, clockwise from top)
               (let* ((pts '((0 . 1) (1 . 0) (0 . -1) (-1 . 0) (0 . 1)))
                      (p0 (list-ref pts a)) (p1 (list-ref pts (+ a 1))))
                 (list 'curveto
                       (* r (+ (car p0) (* k (car p1)))) (* r (+ (cdr p0) (* k (cdr p1))))
                       (* r (+ (car p1) (* k (car p0)))) (* r (+ (cdr p1) (* k (cdr p0))))
                       (* r (car p1)) (* r (cdr p1))))))
          ; the air is the white part, the tone the black: fill what is not air, starting
          ; where the air ends (clockwise from the top)
          (n (inexact->exact (round (* 4 fraction))))
          (start (list-ref '((0 . 1) (1 . 0) (0 . -1) (-1 . 0) (0 . 1)) (min n 4)))
          (fill (cond ((>= n 4) empty-stencil)
                      ((<= n 0) (make-circle-stencil r 0 #t))
                      (else
                       (make-path-stencil
                        (append (list 'moveto 0 0 'lineto (* r (car start)) (* r (cdr start)))
                                (apply append (map q (iota (- 4 n) n))) '(closepath))
                        0 1 1 #t)))))
     (ly:stencil-add ring fill)))

% centred over its note
wind =
#(define-event-function (fraction) (number?)
   #{ -\tweak parent-alignment-X #CENTER -\tweak self-alignment-X #CENTER
      ^\markup \wind-circle #fraction #})

%% ------------------------------------------------------------------ slap tongue

% Slap tongue: an accent-shaped head (as in Dorico's "Slap Tongue" notehead set)
slapOn = {
  \override NoteHead.stencil = #ly:text-interface::print
  \override NoteHead.text = \markup \musicglyph "scripts.sforzato"
  \override NoteHead.stem-attachment = #'(1.0 . 0.0)
}
slapOff = {
  \revert NoteHead.stencil
  \revert NoteHead.text
  \revert NoteHead.stem-attachment
}

%% ------------------------------------------------------------------ caesura, niente

% "//" before the barline
caes = {
  \once \override BreathingSign.text = \markup \musicglyph "scripts.caesura.straight"
  \once \override BreathingSign.Y-offset = 2.5
  \once \override BreathingSign.extra-offset = #'(-1.6 . 0)   % clear of the barline
  \breathe
}

% the same where the gesture is followed closely (little room before the next note)
caesTight = {
  \once \override BreathingSign.text = \markup \musicglyph "scripts.caesura.straight"
  \once \override BreathingSign.Y-offset = 2.5
  \once \override BreathingSign.extra-offset = #'(-0.4 . 0)
  \breathe
}

niente = #(make-dynamic-script (markup #:normal-text #:bold #:italic "n"))

%% ------------------------------------------------------------------ electronics

% A cue for the electronics at its rhythmic position: \ecue "12" -> a boxed "12" with a
% hairline down to the staff, marking the exact moment. The timing log reads it as "cue 12"
% (its cue-label), which is where the patch's cue times come from; keep the label a number.
ecue =
#(define-event-function (label) (string?)
   (let ((ev #{ -\tweak outside-staff-priority ##f
                -\tweak Y-offset #4.2
                -\tweak X-offset #-0.1
                -\tweak self-alignment-X #LEFT
                ^\markup \combine
                  \translate #'(0 . -2.2) \with-dimensions #'(0 . 0) #'(0 . 0)
                    \draw-line #'(0 . 2.2)
                  \box \pad-x #0.2 \fontsize #2 \bold #label #}))
     (ly:music-set-property! ev 'cue-label label)
     ev))

% \ecueToCaesura "9": the same cue, moved sideways to sit right below the flute's caesura
% nearest to it (the cue falls in that pause), with a vertical dotted line from the top of its
% box up to the caesura. Both are placed only once the page is laid out (cross-staff): the
% cue's extents and skylines are those of the box where it was entered.
#(define (ecue-caesura-stencil grob)
   (let* ((box (ly:text-interface::print grob))
          (sys (ly:grob-system grob))
          (bx (interval-center (ly:stencil-extent box X)))
          (by (cdr (ly:stencil-extent box Y)))
          (me-x (+ (ly:grob-relative-coordinate grob sys X) bx))
          (signs (filter (lambda (g) (and (grob::has-interface g 'breathing-sign-interface)
                                          (eq? (ly:grob-system g) sys)))
                         (ly:grob-array->list (ly:grob-object sys 'all-elements))))
          (dist (lambda (g) (abs (- (interval-center (ly:grob-extent g sys X)) me-x))))
          (sign (and (pair? signs) (fold (lambda (g b) (if (< (dist g) (dist b)) g b)) (car signs) signs))))
     (if (not sign) box
         (let* ((eo (ly:grob-property sign 'extra-offset '(0 . 0)))
                (common (ly:grob-common-refpoint grob sign Y))
                (tx (+ (- (interval-center (ly:grob-extent sign sys X)) (ly:grob-relative-coordinate grob sys X))
                       (car eo)))
                (ty (+ (- (car (ly:grob-extent sign common Y)) (ly:grob-relative-coordinate grob common Y))
                       (cdr eo) -0.5))
                (y0 (+ by 0.5))
                (n (max 1 (inexact->exact (floor (/ (abs (- ty y0)) 0.45)))))
                (dots (map (lambda (k)
                             (ly:stencil-translate (make-circle-stencil 0.075 0 #t)
                                                   (cons tx (+ y0 (* (/ k n) (- ty y0))))))
                           (iota (1+ n)))))
           (ly:stencil-add (ly:stencil-translate-axis box (- tx bx) X)
                           (ly:make-stencil (ly:stencil-expr (apply ly:stencil-add dots)) '(0 . 0) '(0 . 0)))))))

ecueToCaesura =
#(define-event-function (label) (string?)
   (let ((ev #{ -\tweak stencil #ecue-caesura-stencil
                -\tweak cross-staff ##t
                -\tweak X-extent #(lambda (g) (ly:stencil-extent (ly:text-interface::print g) X))
                -\tweak Y-extent #(lambda (g) (ly:stencil-extent (ly:text-interface::print g) Y))
                -\tweak vertical-skylines #ly:grob::simple-vertical-skylines-from-extents
                -\tweak horizontal-skylines #ly:grob::simple-horizontal-skylines-from-extents
                \ecue #label #}))
     (ly:music-set-property! ev 'cue-label label)
     ev))

% An electronics effect, in a word or two, under the treble staff (above the bass staff when
% there is one), every one on the same line just clear of middle C (the collections' lowest
% notes)
edesc = #(define-event-function (text) (markup?)
           #{ -\tweak outside-staff-priority ##f
              -\tweak Y-offset #-5.6
              _\markup \italic #text #})

% The pitch collections. \collection { c'32 d' e' fis' a' } is one chord at the first note's
% moment, as long as the notes together, so only that moment takes part in the score's
% spacing: the flute is spaced as if the collection were one note. The heads are then laid out
% left to right in written order, each with its accidental, at fixed distances from the first
% (collection-gap staff spaces apart), in parentheses. The timing log still reads every note
% and the \startGroup/\stopGroup around them (~ec).
#(define collection-gap 0.8)

collection =
#(define-music-function (music) (ly:music?)
   (let* ((notes (extract-typed-music music 'note-event))
          (len (ly:music-length music))
          (r (ly:moment-main len))
          (dur (ly:make-duration 0 0 (numerator r) (denominator r)))
          (n (length notes)))
     (make-music 'EventChord
                 'elements
                 (append
                  (map (lambda (note i)
                         (make-music 'NoteEvent
                                     'pitch (ly:music-property note 'pitch)
                                     'duration dur
                                     'collection-index i
                                     'collection-size n))
                       notes (iota n))
                  (list (make-music 'NoteGroupingEvent 'span-direction START)
                        (make-music 'NoteGroupingEvent 'span-direction STOP))))))

#(define (collection-index head)
   (ly:event-property (event-cause head) 'collection-index 0))

#(define (collection-accidental head)
   (let ((acc (ly:grob-object head 'accidental-grob #f)))
     (and acc (ly:accidental-interface::print acc))))

% the head's own glyph, its accidental to the left and the parenthesis, if it is first or last
#(define (collection-head-stencil head)
   (let* ((st (ly:note-head::print head))
          (acc (collection-accidental head))
          (i (collection-index head))
          (last? (= i (1- (ly:event-property (event-cause head) 'collection-size 1))))
          (paren (lambda (s) (ly:stencil-aligned-to
                              (grob-interpret-markup head (markup #:fontsize 1 s)) Y CENTER)))
          (with-acc (if acc (ly:stencil-combine-at-edge st X LEFT acc 0.2) st))
          (with-open (if (zero? i) (ly:stencil-combine-at-edge with-acc X LEFT (paren "(") 0.15) with-acc)))
     (if last? (ly:stencil-combine-at-edge with-open X RIGHT (paren ")") 0.15) with-open)))

% each head's place: after the heads (and accidentals) before it, the first at the chord's moment
#(define (collection-head-x head)
   (let* ((col (ly:grob-parent head X))
          (heads (sort (ly:grob-array->list (ly:grob-object col 'note-heads))
                       (lambda (a b) (< (collection-index a) (collection-index b)))))
          (width (lambda (h) (interval-length (ly:stencil-extent (ly:note-head::print h) X))))
          (acc-width (lambda (h) (let ((a (collection-accidental h)))
                                   (if a (+ 0.2 (interval-length (ly:stencil-extent a X))) 0)))))
     (let loop ((hs heads) (x 0) (first #t))
       (let* ((h (car hs))
              (hx (if first x (+ x (acc-width h)))))
         (if (eq? h head)
             hx
             (loop (cdr hs) (+ hx (width h) collection-gap) #f))))))

% the whole fan, parentheses included, relative to the chord's column: given to the (hidden)
% stem, so spacing keeps the next collection clear of it, and otherwise ignores the fan
#(define (collection-fan-extent stem)
   (let* ((col (ly:grob-parent stem X))
          (heads (ly:grob-array->list (ly:grob-object col 'note-heads))))
     (reduce interval-union '(0 . 0)
             (map (lambda (h) (coord-translate (ly:stencil-extent (collection-head-stencil h) X)
                                               (collection-head-x h)))
                  heads))))

collectionStyle = {
  \override Stem.X-offset = 0
  \override Stem.X-extent = #collection-fan-extent
  \override NoteHead.duration-log = 2                 % filled heads, whatever the chord's length
  \override NoteHead.stencil = #collection-head-stencil
  \override NoteHead.X-offset = #collection-head-x
  % spacing and ledger lines see only the head itself, not its accidental or parenthesis
  \override NoteHead.X-extent = #(lambda (head) (ly:stencil-extent (ly:note-head::print head) X))
  \override Accidental.stencil = ##f
  \override Accidental.X-extent = #'(0 . 0)
}

%% ------------------------------------------------------------------ shaped trills

% A trill whose speed changes: "tr" (with its upper note's accidental) and a wavy line whose
% waves are long where the trill is slow and short where it is fast.
%   fis''1 \shapedTrill "♮" #'(0.25 1 0.25) ... (next note) \stopTrillSpan
% speeds: relative speeds at evenly spaced points along the note (1 = fastest), interpolated;
% '(0.25 1 0.25) starts slow, gets fast, ends slow. "" for no accidental. \midiTrills plays it.

% the speed (0..1) at fraction t (0..1) of the way through
#(define (shape-speed speeds t)
   (let* ((n (1- (length speeds)))
          (x (* t n))
          (i (min (inexact->exact (floor x)) (max 0 (1- n))))
          (f (- x i)))
     (if (zero? n)
         (car speeds)
         (+ (* (- 1 f) (list-ref speeds i)) (* f (list-ref speeds (1+ i)))))))

#(define (shaped-trill-stencil grob)
   (let* ((speeds (detail grob 'speeds '(1)))
          (label (detail grob 'label (markup #:musicglyph "scripts.trill")))
          (txt (ly:stencil-aligned-to (grob-interpret-markup grob label) Y CENTER))
          (x0 (span-x grob LEFT))
          (x1 (- (span-x grob RIGHT) 0.6))
          (start (+ x0 (cdr (ly:stencil-extent txt X)) 0.3))
          (amp 0.3)
          (long 3.4) (short 0.45)           ; wavelengths at speed 0 and 1
          (dx 0.04))
     (let loop ((x start) (phase 0) (pts '()))
       (if (> x x1)
           (ly:stencil-add
            (ly:stencil-translate-axis txt x0 X)
            (make-path-stencil
             (append (list 'moveto start 0)
                     (apply append (map (lambda (p) (list 'lineto (car p) (cdr p))) (reverse pts))))
             0.16 1 1 #f))
           (let* ((t (/ (- x start) (max 0.01 (- x1 start))))
                  (wl (- long (* (- long short) (shape-speed speeds t))))
                  (ph (+ phase (/ (* 2 3.14159265 dx) wl))))
             (loop (+ x dx) ph (cons (cons x (* amp (sin phase))) pts)))))))

shapedTrill =
#(define-event-function (acc speeds) (string? list?)
   (let ((ev #{ -\tweak stencil #shaped-trill-stencil
                -\tweak after-line-breaking #register-trill
                -\tweak details.speeds #speeds
                -\tweak details.label
                  \markup \override #'((acc-dir . -1.3) (acc-padding . -0.4))
                    \acc-ornament #acc "scripts.trill" ""
                -\tweak bound-details.left.attach-dir #LEFT
                -\tweak bound-details.right.attach-dir #LEFT
                \startTrillSpan #}))
     (if (not (string-null? acc)) (ly:music-set-property! ev 'trill-upper acc))
     (ly:music-set-property! ev 'trill-shape speeds)
     ev))

%% ------------------------------------------------------------------ fanned beams

% Feathered beams: \featherOnce before a beamed group (accelerando: the beams fan out to the
% right), \featherBackOnce (ritardando); \featherOn ... \featherOff for several groups
featherOnce = \once \override Beam.grow-direction = #RIGHT
featherBackOnce = \once \override Beam.grow-direction = #LEFT
featherOn = \override Beam.grow-direction = #RIGHT
featherOff = \revert Beam.grow-direction

%% ------------------------------------------------------------------ playback

% An invisible text the timing log reads (timing.ily): "improv 1", "improv end"
improvMark =
#(define-event-function (text) (string?)
   #{ -\tweak stencil ##f ^\markup #text #})

% A flute improvisation: \improvisation 1 { ... } marks "improv 1" at its start and
% "improv end" at its end for the patch (its improvisation is rendered in SuperCollider and
% mixed into the audio), and is silent in the MIDI: the MIDI score removes the 'printed music
% and keeps a skip as long, the printed score does the opposite.
improvisation =
#(define-music-function (n music) (index? ly:music?)
   (let ((len (ly:music-length music)))
     #{ <>\improvMark #(format #f "improv ~a" n)
        << \tag #'printed #music
           \tag #'played #(make-music 'SkipMusic
                                      'duration (ly:make-duration 0 0 (ly:moment-main len))) >>
        <>\improvMark "improv end" #}))

% A tempo change for playback only (MIDI and cue times), not printed: \playTempo 60
playTempo =
#(define-music-function (bpm) (number?)
   #{ \once \omit Score.MetronomeMark \tempo 4 = #bpm #})

% A gradual tempo change for playback only: \playAccel 80 120 #13 plays the next 13 beats
% stepping evenly from 80 (the tempo already in force, printed or not) towards 120, one
% \playTempo per sixteenth after the first; the next \tempo / \playTempo after them is where
% it arrives. (No tempo of its own on the first sixteenth: \playTempo hides any printed mark
% at the same moment.)
playAccel =
#(define-music-function (from to beats) (number? number? integer?)
   (let ((n (* 4 beats)))
     (make-sequential-music
      (cons #{ s16 #}
            (map (lambda (i) #{ \playTempo #(+ from (* (- to from) (/ i n))) s16 #})
                 (iota (- n 1) 1))))))

% A printed "accel." with a dashed line, from the note it follows to the next \stopTextSpan;
% ending on the first note after a line break, it stops at the end of the line before (no
% "accel." again on the new line)
accelSpan = -\tweak bound-details.left.text \markup \italic "accel."
            -\tweak after-line-breaking #ly:spanner::kill-zero-spanned-time
            -\tweak bound-details.left.stencil-align-dir-y #CENTER
            -\tweak direction #UP
            \startTextSpan

% Trills in the MIDI: \midiTrills { ... } (in the MIDI score only) plays every note marked
% ^\trill, or with a post-event carrying trill-upper ("♯" "♭" "♮", as \accTrill does), as 32nds
% alternating with its upper neighbour (a diatonic step; natural unless trill-upper says
% otherwise), starting on the written note. A \shapedTrill follows its speeds: 32nds at speed
% 1, eighths at speed 0.
#(define (trill-upper-alteration note)
   (let loop ((arts (ly:music-property note 'articulations '())))
     (cond ((null? arts) #f)
           ((let ((t (ly:music-property (car arts) 'articulation-type #f)))
              (and t (equal? (if (symbol? t) (symbol->string t) t) "trill")))
            0)
           ((ly:music-property (car arts) 'trill-upper #f)
            => (lambda (a) (cond ((string=? a "♯") 1/2) ((string=? a "♭") -1/2) (else 0))))
           ((ly:music-property (car arts) 'trill-shape #f) 0)
           (else (loop (cdr arts))))))

% the trill's speed shape (\shapedTrill), or #f for an even trill
#(define (trill-shape note)
   (any (lambda (a) (ly:music-property a 'trill-shape #f))
        (ly:music-property note 'articulations '())))

% note lengths (whole notes) filling len: 1/32 at speed 1, 1/8 at speed 0, following shape
#(define (trill-lengths len shape)
   (let loop ((at 0) (out '()))
     (let* ((sp (if shape (shape-speed shape (/ at len)) 1))
            (d (/ (inexact->exact (round (* 128 (+ 1/32 (* (- 1/8 1/32) (- 1 sp)))))) 128)))
       (if (>= (+ at d) len)
           (reverse (cons (- len at) out))
           (loop (+ at d) (cons d out))))))

#(define (upper-neighbour p alt)
   (let* ((n (1+ (ly:pitch-notename p)))
          (o (+ (ly:pitch-octave p) (if (> n 6) 1 0))))
     (ly:make-pitch o (modulo n 7) alt)))

midiTrills =
#(define-music-function (music) (ly:music?)
   (map-some-music
    (lambda (m)
      (and (music-is-of-type? m 'note-event)
           (let ((alt (trill-upper-alteration m)))
             (and alt
                  (let* ((p (ly:music-property m 'pitch))
                         (len (ly:moment-main (ly:music-length m)))
                         (lens (trill-lengths len (trill-shape m)))
                         (dur (lambda (r) (ly:make-duration 0 0 (numerator r) (denominator r)))))
                    (make-sequential-music
                     (map (lambda (d i)
                            (make-music 'NoteEvent
                                        'pitch (if (even? i) p (upper-neighbour p alt))
                                        'duration (dur d)))
                          lens (iota (length lens)))))))))
    music))

