%% pondside-graphics.ily -- the Pondside graphics kit (LilyPond 2.24 and 2.26).
%%
%% A graphic is a spanner from one moment to another on a staff, drawn at
%% layout time so it follows the music when the spacing changes. An entry
%% only says what to draw: it is a procedure (lambda (g p) ...) that gets
%% a context `g` and its params `p` (an alist, defaults merged in) and
%% returns a list of shapes, plain data. The kit does everything else:
%% where the span is on each system, the columns, the cue times, what to
%% keep clear of, seeded randomness, the stencils, and line breaks.
%%
%% Coordinates: u runs along the whole span in staff spaces, 0 at its start,
%% as if the span were one strip; y is in staff spaces from the staff's
%% middle line (the lines of a five-line staff are at -2 ... 2). The kit
%% cuts the strip at each line break and shifts every piece into place.
%%
%% Use: \startGraphic "grain-cloud" #'((density . 0.7)) on a skip, then
%% \stopGraphic where it ends, in a voice of skips on the staff.

#(use-modules (srfi srfi-1))

#(define pondside-graphics (make-hash-table))
#(define (define-graphic! id proc) (hash-set! pondside-graphics id proc))

%% ------------------------------------------------------------- time

% Tempos and cue moments, collected while the music is interpreted, so a
% graphic can be shaped by the score's own seconds and cues.
#(define pg-tempos '())
#(define pg-cues '())
#(define (Pondside_graphics_time_engraver context)
   (make-engraver
    (listeners
     ((tempo-change-event engraver event)
      (let ((count (ly:event-property event 'metronome-count #f))
            (unit (ly:event-property event 'tempo-unit #f))
            (m (ly:moment-main (ly:context-current-moment context))))
        (if (and (number? count) unit (not (assv m pg-tempos)))
            (set! pg-tempos (cons (cons m (* count (/ (ly:moment-main (ly:duration->moment unit)) 1/4)))
                                  pg-tempos)))))
     ((text-script-event engraver event)
      (let ((cue (ly:event-property event 'cue-label #f)))
        (if (and (string? cue) (not (assoc cue pg-cues)))
            (set! pg-cues (cons (cons cue (ly:moment-main (ly:context-current-moment context))) pg-cues))))))))

\layout { \context { \Score \consists #Pondside_graphics_time_engraver } }

% Seconds at moment m (whole notes); 60 quarters a minute until a tempo, as the MIDI.
#(define (pg-moment->seconds m)
   (let loop ((ts (sort (if (assv 0 pg-tempos) pg-tempos (cons (cons 0 60) pg-tempos))
                        (lambda (a b) (< (car a) (car b)))))
              (acc 0))
     (let ((m0 (caar ts)) (q (cdar ts)))
       (if (and (pair? (cdr ts)) (>= m (caadr ts)))
           (loop (cdr ts) (+ acc (* (- (caadr ts) m0) (/ 240.0 q))))
           (+ acc (* (- m m0) (/ 240.0 q)))))))

%% ------------------------------------------------------------- the context

% One piece of the span (a line of it): its x range relative to the
% spanner, its columns as (x . moment), and where it sits on the strip.
#(define (pg-piece-info grob)
   (let* ((sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X))
          (bx (lambda (key) (- (assoc-get 'X (ly:grob-property grob key)) me)))
          (bound-left (bx 'left-bound-info))
          (right (bx 'right-bound-info))
          ; musical columns only: where the notes are, not clefs and bar lines
          (cols (sort (filter-map
                       (lambda (c)
                         (let ((x (- (ly:grob-relative-coordinate c sys X) me)))
                           (and (equal? (grob::name c) 'PaperColumn)
                                (<= (- bound-left 0.01) x (+ right 0.01))
                                (cons x (ly:moment-main (ly:grob-property c 'when))))))
                       (ly:grob-array->list (ly:grob-object sys 'columns)))
                      (lambda (a b) (< (car a) (car b)))))
          ; a piece after a line break starts at its first note, after the clef
          (continued (let ((o (ly:grob-original grob)))
                       (and o (pair? (ly:spanner-broken-into o)) (not (eq? grob (car (ly:spanner-broken-into o)))))))
          (left (if (and continued (pair? cols)) (max bound-left (- (caar cols) 0.8)) bound-left)))
     (list left right cols)))

#(define (pg-pieces grob)
   (let ((orig (ly:grob-original grob)))
     (if (and orig (ly:spanner? orig) (pair? (ly:spanner-broken-into orig)))
         (ly:spanner-broken-into orig)
         (list grob))))

% Build g for `grob`. The strip is the pieces laid end to end.
#(define (pg-make-context grob params)
   (let* ((pieces (pg-pieces grob))
          (infos (map pg-piece-info pieces))
          (widths (map (lambda (i) (- (cadr i) (car i))) infos))
          (starts (let loop ((ws widths) (acc 0) (out '()))
                    (if (null? ws) (reverse out) (loop (cdr ws) (+ acc (car ws)) (cons acc out)))))
          (index (or (list-index (lambda (p) (eq? p grob)) pieces) 0))
          (info (list-ref infos index))
          ; strip columns: (u . moment), every piece
          (columns (append-map (lambda (i u0) (map (lambda (c) (cons (+ u0 (- (car c) (car i))) (cdr c))) (caddr i)))
                               infos starts))
          (seed (let ((s (assq-ref params 'seed))) (if (integer? s) s 0))))
     `((grob . ,grob) (params . ,params) (index . ,index) (count . ,(length pieces))
       (left . ,(car info)) (right . ,(cadr info)) (u0 . ,(list-ref starts index))
       (width . ,(apply + widths)) (piece-width . ,(list-ref widths index))
       (columns . ,(delete-duplicates columns (lambda (a b) (equal? (cdr a) (cdr b)))))
       (piece-starts . ,starts) (seed . ,seed))))

#(define (g-ref g key) (assq-ref g key))

% The strip's length, in staff spaces; this piece's [u0, u1] on it.
#(define (g-width g) (g-ref g 'width))
#(define (g-piece g) (cons (g-ref g 'u0) (+ (g-ref g 'u0) (g-ref g 'piece-width))))
% Where lines break, as u (the start of each later piece).
#(define (g-breaks g) (cdr (g-ref g 'piece-starts)))
% q, 0..1 along the strip, for u.
#(define (g-q g u) (if (> (g-width g) 0) (/ u (g-width g)) 0))

% Columns as (u . moment), in order.
#(define (g-columns g) (g-ref g 'columns))

% u of moment m (whole notes), interpolated between columns; #f outside.
#(define (g-u-at g m)
   (let loop ((cs (g-columns g)))
     (cond ((or (null? cs) (null? (cdr cs)))
            (and (pair? cs) (= m (cdar cs)) (caar cs)))
           ((<= (cdar cs) m (cdadr cs))
            (let ((dm (- (cdadr cs) (cdar cs))))
              (if (zero? dm) (caar cs)
                  (+ (caar cs) (* (/ (- m (cdar cs)) dm) (- (caadr cs) (caar cs)))))))
           (else (loop (cdr cs))))))

% Moment at u, and seconds at u.
#(define (g-moment-at g u)
   (let loop ((cs (g-columns g)))
     (cond ((null? cs) 0)
           ((null? (cdr cs)) (cdar cs))
           ((<= (caar cs) u (caadr cs))
            (let ((du (- (caadr cs) (caar cs))))
              (if (< du 1e-6) (cdar cs)
                  (+ (cdar cs) (* (/ (- u (caar cs)) du) (- (cdadr cs) (cdar cs)))))))
           ((< u (caar cs)) (cdar cs))
           (else (loop (cdr cs))))))
#(define (g-seconds g u) (pg-moment->seconds (g-moment-at g u)))

% u of cue "12" (\ecue "12", or a Lexicon cue), or #f when it is not in the span.
#(define (g-u-at-cue g name)
   (let ((m (assoc-get name pg-cues #f)))
     (and m (g-u-at g m))))

% Staff line i (0 = bottom) of a five-line staff, as y.
#(define (g-staff-y g i) (- i 2))

% Boxes (u0 u1 y0 y1) of grobs with any of `interfaces` on this piece's
% staff, to keep clear of: notes, dynamics, the electronics' collections.
#(define (g-clear-of g interfaces)
   (let* ((grob (g-ref g 'grob))
          (sys (ly:grob-system grob))
          (vag (ly:grob-parent grob Y))
          (me (ly:grob-relative-coordinate grob sys X))
          (my (ly:grob-relative-coordinate grob sys Y))
          (shift (- (g-ref g 'u0) (g-ref g 'left))))
     (filter-map
      (lambda (o)
        (and (not (eq? o grob))
             (eq? (ly:grob-system o) sys)
             (any (lambda (i) (grob::has-interface o i)) interfaces)
             (let ((xe (ly:grob-extent o sys X)) (ye (ly:grob-extent o sys Y)))
               (and (interval-sane? xe) (interval-sane? ye)
                    (list (+ shift (- (car xe) me)) (+ shift (- (cdr xe) me))
                          (- (car ye) my) (- (cdr ye) my))))))
      (if (ly:grob? vag) (ly:grob-array->list (ly:grob-object vag 'elements)) '()))))

% Is (u . y) inside any of `boxes`, padded by `pad`?
#(define (g-inside? boxes u y pad)
   (any (lambda (b) (and (< (- (car b) pad) u (+ (cadr b) pad)) (< (- (caddr b) pad) y (+ (cadddr b) pad)))) boxes))

%% ------------------------------------------------------------- randomness

% The same random sequence on every compile and every piece: seeded by the
% param `seed` and `salt` (use a different salt per layer of a drawing).
#(define (g-random g . salt)
   (seed->random-state (+ (* 7919 (g-ref g 'seed)) (if (pair? salt) (car salt) 0) 1)))
#(define (g-rand rs a b) (+ a (* (- b a) (random 1.0 rs))))

%% ------------------------------------------------------------- envelopes

% An envelope is a value over q (0..1 along the span), written as data so it
% can be a param: 2, (constant 2), (linear 0.5 3), (swell peaks lo hi),
% (pulse peaks lo hi) sharper peaks, (lfo cycles depth centre),
% (points (0 . 0.5) (0.3 . 3) (1 . 0.5)), (sum e1 e2), (product e1 e2),
% (smooth e) easing between 0 and its value.
#(define (env-at e q)
   (let ((q (max 0 (min 1 q))) (pi2 (* 2 3.141592653589793)))
     (cond
      ((number? e) e)
      ((not (pair? e)) 0)
      (else
       (let ((kind (if (string? (car e)) (string->symbol (car e)) (car e))) (a (cdr e)))
         (case kind
           ((constant) (car a))
           ((linear) (+ (car a) (* q (- (cadr a) (car a)))))
           ((swell) (+ (cadr a) (* (- (caddr a) (cadr a)) (- 0.5 (* 0.5 (cos (* pi2 (car a) q)))))))
           ((pulse) (+ (cadr a) (* (- (caddr a) (cadr a)) (expt (- 0.5 (* 0.5 (cos (* pi2 (car a) q)))) 3))))
           ((lfo) (+ (caddr a) (* (cadr a) (sin (* pi2 (car a) q)))))
           ((points)
            ; each point (q . v), or (q v) as TOML arrays give it
            (let* ((v-of (lambda (pt) (if (pair? (cdr pt)) (cadr pt) (cdr pt))))
                   (ps a))
              (let loop ((ps ps))
                (cond ((null? (cdr ps)) (v-of (car ps)))
                      ((<= q (caadr ps))
                       (let ((dq (- (caadr ps) (caar ps))) (v0 (v-of (car ps))) (v1 (v-of (cadr ps))))
                         (if (< dq 1e-9) v1 (+ v0 (* (/ (- q (caar ps)) dq) (- v1 v0))))))
                      (else (loop (cdr ps)))))))
           ((sum) (apply + (map (lambda (x) (env-at x q)) a)))
           ((product) (apply * (map (lambda (x) (env-at x q)) a)))
           ((smooth) (let ((t (* q q (- 3 (* 2 q))))) (* t (env-at (car a) q))))
           (else 0)))))))

%% ------------------------------------------------------------- shapes

% Shapes are lists; an entry returns a list of them:
%   (dot u y r)                     a filled circle
%   (stroke ((u . y) ...) thick)    an open line
%   (fill ((u . y) ...))            a filled polygon
%   (curve ((u . y) ...) thick)     a smooth line through the points
%   (wedge u0 u1 h0 h1 y)           a filled wedge, half-heights h0 -> h1, centred on y
%   (text u y markup)               a markup, its left edge at u
%   (gray g shape)                  shape in grey: 0 black .. 1 white
#(define (pg-path pts closed thick)
   (if (< (length pts) 2) empty-stencil
       (make-path-stencil
        (append (list 'moveto (caar pts) (cdar pts))
                (append-map (lambda (p) (list 'lineto (car p) (cdr p))) (cdr pts))
                (if closed '(closepath) '()))
        thick 1 1 closed)))

% Catmull-Rom through the points, 8 samples per segment.
#(define (pg-smooth pts)
   (if (< (length pts) 3) pts
       (let* ((v (list->vector pts)) (n (vector-length v))
              (at (lambda (i) (vector-ref v (max 0 (min (1- n) i))))))
         (append
          (append-map
           (lambda (i)
             (map (lambda (k)
                    (let* ((t (/ k 8.0)) (t2 (* t t)) (t3 (* t2 t))
                           (p0 (at (1- i))) (p1 (at i)) (p2 (at (1+ i))) (p3 (at (+ i 2)))
                           (f (lambda (a b c d)
                                (* 0.5 (+ (* 2 b) (* (- c a) t) (* (+ (* 2 a) (* -5 b) (* 4 c) (- d)) t2)
                                          (* (+ (- a) (* 3 b) (* -3 c) d) t3))))))
                      (cons (f (car p0) (car p1) (car p2) (car p3)) (f (cdr p0) (cdr p1) (cdr p2) (cdr p3)))))
                  (iota 8)))
           (iota (1- n)))
          (list (vector-ref v (1- n)))))))

#(define (pg-stencil grob shape)
   (case (car shape)
     ((dot) (ly:stencil-translate (make-circle-stencil (cadddr shape) 0 #t) (cons (cadr shape) (caddr shape))))
     ((stroke) (pg-path (cadr shape) #f (caddr shape)))
     ((fill) (pg-path (cadr shape) #t 0))
     ((curve) (pg-path (pg-smooth (cadr shape)) #f (caddr shape)))
     ((wedge)
      (let ((u0 (list-ref shape 1)) (u1 (list-ref shape 2)) (h0 (list-ref shape 3)) (h1 (list-ref shape 4)) (y (list-ref shape 5)))
        (pg-path (list (cons u0 (+ y h0)) (cons u1 (+ y h1)) (cons u1 (- y h1)) (cons u0 (- y h0))) #t 0)))
     ((text) (ly:stencil-translate (grob-interpret-markup grob (cadddr shape)) (cons (cadr shape) (caddr shape))))
     ((gray) (let ((st (pg-stencil grob (caddr shape))) (v (cadr shape)))
               (if (<= v 0.001) st (stencil-with-color st (list v v v)))))
     (else empty-stencil)))

% The u range a shape covers, to drop the ones on other pieces.
#(define (pg-shape-range shape)
   (case (car shape)
     ((dot) (cons (- (cadr shape) (cadddr shape)) (+ (cadr shape) (cadddr shape))))
     ((stroke fill curve) (let ((us (map car (cadr shape)))) (cons (apply min us) (apply max us))))
     ((wedge) (cons (min (list-ref shape 1) (list-ref shape 2)) (max (list-ref shape 1) (list-ref shape 2))))
     ((text) (cons (cadr shape) (+ (cadr shape) 1)))
     ((gray) (pg-shape-range (caddr shape)))
     (else (cons 0 0))))

%% ------------------------------------------------------------- the spanner

% The stencil callback: run the entry over the whole strip, keep what falls
% on this piece, and shift it from strip u to the piece's x.
#(define (pg-graphic-stencil id params)
   (lambda (grob)
     (let ((proc (hash-ref pondside-graphics id #f)))
       (if (not proc)
           (begin (ly:warning "Pondside graphics: no entry ~a" id) empty-stencil)
           (let* ((g (pg-make-context grob params))
                  (piece (g-piece g))
                  (shift (- (g-ref g 'left) (car piece)))
                  (shapes (filter (lambda (s)
                                    (let ((r (pg-shape-range s)))
                                      (and (< (car r) (+ (cdr piece) 0.5)) (> (cdr r) (- (car piece) 0.5)))))
                                  (proc g params))))
             (ly:stencil-translate-axis
              (apply ly:stencil-add (cons empty-stencil (map (lambda (s) (pg-stencil grob s)) shapes)))
              shift X))))))

% Draws but takes no room: it neither pushes other things nor reserves space.
#(define pg-no-skylines
   (ly:make-unpure-pure-container (lambda (grob) (ly:skylines-for-stencil empty-stencil X))))

% Params come merged with the entry's defaults by the Lexicon's include.
#(define pondside-graphics-defaults (make-hash-table))

startGraphic =
#(define-event-function (id params) (string? list?)
   (let* ((defaults (hash-ref pondside-graphics-defaults id '()))
          (merged (append params (filter (lambda (d) (not (assq (car d) params))) defaults))))
     #{ -\tweak stencil #(pg-graphic-stencil id merged)
        -\tweak X-extent #'(0 . 0)
        -\tweak Y-offset #0
        -\tweak outside-staff-priority ##f
        -\tweak vertical-skylines #pg-no-skylines
        -\tweak bound-details.left.attach-dir #LEFT
        -\tweak bound-details.right.attach-dir #LEFT
        -\tweak bound-details.left-broken.attach-dir #LEFT
        -\tweak bound-details.right-broken.attach-dir #RIGHT
        \startTextSpan #}))

stopGraphic = \stopTextSpan
