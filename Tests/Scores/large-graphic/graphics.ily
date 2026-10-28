% Graphic notation for the electronics (bars 1-31), drawn by LilyPond at the size the layout
% gives each passage, so it follows the music when the spacing changes. Each graphic is a
% spanner in a voice of skips on the Electronics staff (electronicsGraphics, electronics.ly),
% from one moment to another; its drawing is a Scheme procedure below. Everything is in staff
% spaces, y relative to the staff's middle line (the staff lines are at -2 ... 2). The staff
% lines stop where the ripples begin (they turn into them) and start again at cue 3's
% pentachord. Random choices come from fixed seeds: the same drawing on every compile.
%
%   bars 1-2   \startRipples  the five staff lines turning curly: loops whose size swells and
%                             subsides (three times), denser as it goes, broken, with echoes,
%                             fading out behind the arc in bar 2; reverse tongue rams as notes
%                             on them, ever closer together, louder, some accented
%   bars 2-3   \startArc      the flute's arc (bar 2) with echo copies that run on into bar 3,
%                             fainter and curlier as they go
%   bar 3      \startWedges   three wedges, light to black, dissolving into grains at the end
%                             -- with forward tongue rams over them (slap-tongue echoes)
%   bar 4      \startGrains   grains over the whole staff gathering into three registers, up to
%                             the pentachord; then
%   bar 4      \startSwell    the same grains through cue 3's swell (3 s up, 8 s down): denser
%                             and taller to the peak, then thinner and sparser
%   bars 5-10  \startSwells   the same texture through cues 4-8 (their swells, the density LFOs,
%                             the overall level), clear of the collections; from cue 7 the
%                             decimation pixelizes it, all together, on one slow sinusoid
%   bars 7-31  \startLowSwell pb5's low swells on the bass staff from cue 6: solid shapes, the
%                             upper staff lines pinching against them; tongue rams at cues
%                             16-18; the two lowest lines are the ocean's waves
%   bars 11-31 \startTexture  the grains go on with the patch's cues 9-30 (real times from the
%                             score: Graphics_time_engraver): swells, tongue rams (12-18),
%                             rows of dots where pitched, thinning (19), wind tones (19-21),
%                             random swells and the freeze (22), the granulator's splinters
%                             (12, 23, 27), pixels where the decimation shows
%   bars 11-31 \startBursts   the echo bursts (cues 10, 14, 25, 28) as staff lines rippling
% End each with \stopGraphic.

%% ------------------------------------------------------------------ drawing helpers

#(define (g-rand rs a b) (+ a (* (- b a) (random 1.0 rs))))

#(define (smoothstep e0 e1 x)
   (let ((t (max 0 (min 1 (/ (- x e0) (- e1 e0))))))
     (* t t (- 3 (* 2 t)))))

% grey 0 = black .. 1 = white
#(define (in-grey st g)
   (if (<= g 0.001) st (stencil-with-color st (list g g g))))

#(define (polyline pts lw)
   (if (< (length pts) 2)
       empty-stencil
       (make-path-stencil
        (append (list 'moveto (caar pts) (cdar pts))
                (append-map (lambda (p) (list 'lineto (car p) (cdr p))) (cdr pts)))
        lw 1 1 #f)))

#(define (polygon pts)
   (make-path-stencil
    (append (list 'moveto (caar pts) (cdar pts))
            (append-map (lambda (p) (list 'lineto (car p) (cdr p))) (cdr pts))
            (list 'closepath))
    0 1 1 #t))

#(define (dot x y r)
   (ly:stencil-translate (make-circle-stencil r 0 #t) (cons x y)))

#(define (stack sts) (apply ly:stencil-add (cons empty-stencil sts)))

% Pixels (the decimation): collected with pixel! while a drawing is made, then drawn as one
% filled path (pixels-stencil) -- every square a subpath of a single shape, so a viewer fills
% them in one pass and no hairline seams show where squares meet (as they do between separate
% shapes, each anti-aliased on its own, at some zoom levels)
#(define g-pixels '())
#(define (pixel! xa xb ya yb) (set! g-pixels (cons (list xa xb ya yb) g-pixels)) empty-stencil)
#(define (pixels-stencil)
   (let ((bs g-pixels))
     (set! g-pixels '())
     (if (null? bs) empty-stencil
         (make-path-stencil
          (append-map (lambda (b)
                        (let ((xa (car b)) (xb (cadr b)) (ya (caddr b)) (yb (cadddr b)))
                          (list 'moveto xa ya 'lineto xb ya 'lineto xb yb 'lineto xa yb 'closepath)))
                      bs)
          0 1 1 #t))))

% the spanner's drawing area on this line: (left . right), relative to it
#(define (g-span grob)
   (cons (span-x grob LEFT) (span-x grob RIGHT)))

%% ------------------------------------------------------------------ reverse tongue rams

% A reverse tongue ram as a note on the ripple staff: its head a horn growing exponentially out
% of nothing to a hard vertical cut (solid black, no stem), tilted by `tilt` degrees, maybe with
% an accent above it, and fainter, smaller echo heads after it.
#(define (ram-head x y len h tilt)       ; filled horn, tip at x, cut at x + len, centre y
   (let* ((k 2.6) (n 16)
          (edge (lambda (t) (* h (/ (- (exp (* k t)) 1) (- (exp k) 1)))))
          (top (map (lambda (j) (let ((t (/ j n))) (cons (+ x (* len t)) (+ y (edge t))))) (iota (1+ n))))
          (bottom (map (lambda (q) (cons (car q) (- (* 2 y) (cdr q)))) (reverse top))))
     (ly:stencil-rotate-absolute (polygon (append top bottom)) tilt (+ x len) y)))

% echo heads: (dx in lengths, size, grey)
#(define ram-echoes '((1.0 0.68 0.45) (1.7 0.48 0.62) (2.2 0.34 0.76)))

#(define (ram-note grob x y len h tilt accent? dyn)
   (let* ((cut (+ x len))
          (up (< y 0))
          (accent (if accent?
                      (ly:stencil-translate
                       (ly:stencil-aligned-to (ly:stencil-aligned-to
                                               (grob-interpret-markup grob (make-musicglyph-markup "scripts.sforzato"))
                                               X CENTER) Y CENTER)
                       (cons (+ x (* 0.6 len)) (+ y h 0.75)))
                      empty-stencil))
          (dynamic (if dyn
                       (ly:stencil-translate
                        (ly:stencil-aligned-to (grob-interpret-markup grob
                                                (make-fontsize-markup -1 (make-dynamic-markup dyn)))
                                               X CENTER)
                        (cons (+ x (* 0.5 len)) -3.4))
                       empty-stencil)))
     (stack (append
             (list (ram-head x y len h tilt) accent dynamic)
             ; ledger lines for a head above or below the staff
             (map (lambda (l)
                    (make-filled-box-stencil (cons (- x 0.3) (+ x len 0.3)) (cons (- l 0.05) (+ l 0.05))))
                  (cond ((>= y 3) (map (lambda (k) (+ 3 k)) (iota (1+ (inexact->exact (floor (- y 3)))))))
                        ((<= y -3) (map (lambda (k) (- -3 k)) (iota (1+ (inexact->exact (floor (- -3 y)))))))
                        (else '())))
             (map (lambda (e)
                    (in-grey (ram-head (+ x (* (car e) len)) y (* (cadr e) len) (* (cadr e) h) tilt)
                             (caddr e)))
                  ram-echoes)))))

%% ------------------------------------------------------------------ bar 1: ripples

% curl (0..1) of staff line i at fraction p of bar 1: none at first, then swelling and
% subsiding three times (the send LFO's swells), each swell larger
#(define (ripple-curl p i)
   (* (smoothstep 0.02 0.6 p)
      (expt (- 0.5 (* 0.5 (cos (+ (* 2 3.14159265 3 p) (* 0.35 i))))) 0.8)))

% the rams' tilt (degrees) at fraction p: rising and falling like the curl, a quarter cycle
% out of phase with it
#(define (ram-tilt p rs) (+ (* 16 (sin (* 2 3.14159265 3 p))) (g-rand rs -4 4)))

% echoes: (dx, rise, grey, line-width factor)
#(define ripple-echoes '((0.9 0.12 0.5 0.8) (1.9 0.24 0.68 0.65) (3.0 0.36 0.8 0.5)))

% where this staff's lines end, before the spanner (the ripples continue them), relative to it
#(define (staff-end-before grob)
   (let* ((sys (ly:grob-system grob))
          (vag (ly:grob-parent grob Y))
          (me (ly:grob-relative-coordinate grob sys X))
          (ends (filter-map
                 (lambda (g)
                   (and (grob::has-interface g 'staff-symbol-interface)
                        (eq? (ly:grob-system g) sys)
                        (let ((r (- (cdr (ly:grob-extent g sys X)) me)))
                          (and (< r 1.0) r))))
                 (ly:grob-array->list (ly:grob-object vag 'elements)))))
     (if (null? ends) #f (apply max ends))))

% X of the column at moment m (whole notes) on the spanner's line, relative to it
#(define (column-x grob m)
   (let* ((sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X))
          (cols (filter (lambda (c) (equal? (ly:moment-main (ly:grob-property c 'when)) m))
                        (ly:grob-array->list (ly:grob-object sys 'columns)))))
     (and (pair? cols) (- (ly:grob-relative-coordinate (car cols) sys X) me))))

#(define (ripples-stencil grob)
   (let* ((rs (seed->random-state 23))
          (sp (g-span grob))
          (x0 (- (or (staff-end-before grob) (car sp)) 0.15))   ; overlaps the staff's end: no seam
          (xf (or (column-x grob (detail grob 'fade-at 0)) (cdr sp)))  ; bar 2: fading out
          (w (- xf x0))                                      ; bar 1's length: p = 0..1
          (wall (- (cdr sp) x0))
          (fade (lambda (s) (if (< s w) 0 (min 1 (* 1.05 (/ (- s w) (max 0.1 (- wall w))))))))
          (ds 0.04)
          (segments '()))                 ; (points mean-curl mid-p grey)
     ; each staff line: a trochoid around the line, its loop size following the curl, its
     ; loops getting closer together along the bar; broken into segments where curly. In
     ; bar 2 they go on curling and fade out behind the arc.
     (for-each
      (lambda (i)
        (let ((y0 (- i 2)))
          (let loop ((s 0) (phi (* i 1.3)) (down #t) (left (g-rand rs 3 7)) (pts '()) (cs '()))
            (let ((flush (lambda (pts cs p)
                           (if (pair? pts)
                               (set! segments (cons (list (reverse pts) (/ (apply + cs) (length cs)) p
                                                          (fade (- (caar pts) x0)))
                                                    segments))))))
              (if (> s wall)
                  (if down (flush pts cs 1))
                  (let* ((p (/ s w))
                         (c (ripple-curl p i))
                         (lambda-len (max 0.85 (- 2.0 (* 1.1 p))))
                         (a (* 0.5 c))
                         ; a prolate trochoid: loops where a*2pi/lambda > 1
                         (pt (cons (+ x0 (- s (* a (sin phi)))) (- y0 (* a (cos phi)))))
                         (phi2 (+ phi (/ (* 2 3.14159265 ds) lambda-len)))
                         (left2 (- left ds)))
                    (cond
                     ((< c 0.2)              ; (nearly) straight: no breaks
                      (loop (+ s ds) phi2 #t left2 (if down (cons pt pts) (list pt)) (if down (cons c cs) (list c))))
                     ((> s w)                ; bar 2: unbroken short segments, so the fade is smooth
                      (if (> left2 0)
                          (loop (+ s ds) phi2 #t left2 (cons pt pts) (cons c cs))
                          (begin (flush (cons pt pts) (cons c cs) p)
                                 (loop (+ s ds) phi2 #t 0.6 (list pt) (list c)))))
                     ((> left2 0) (loop (+ s ds) phi2 down left2 (if down (cons pt pts) pts)
                                        (if down (cons c cs) cs)))
                     (down                   ; end a segment, start a gap
                      (flush (cons pt pts) (cons c cs) p)
                      (loop (+ s ds) phi2 #f (* (g-rand rs 0.25 0.8) (+ 0.5 c)) '() '()))
                     (else                   ; end a gap
                      (loop (+ s ds) phi2 #t (* (g-rand rs 2.5 7) (- 1 (* 0.45 (min p 1)))) (list pt) (list c))))))))))
      (iota 5))
     (let* ((lines
             (map (lambda (seg)
                    (let* ((pts (car seg)) (c (cadr seg)) (p (min 1 (caddr seg))) (g (cadddr seg))
                           (lw (+ 0.1 (* 0.07 c))))
                      (stack
                       (cons (in-grey (polyline pts lw) g)
                             ; echoes: fainter, thinner copies to the right, more where curly
                             ; and later
                             (let ((n (if (< c 0.25) 0
                                          (min 3 (1+ (inexact->exact (floor (* 3 c (+ 0.3 p)))))))))
                               (map (lambda (e)
                                      (let ((dx (car e)) (rise (cadr e)))
                                        (in-grey
                                         (polyline (filter (lambda (q) (< (car q) (+ x0 wall)))
                                                           (map (lambda (q) (cons (+ (car q) dx) (+ (cdr q) (* rise c))))
                                                                pts))
                                                   (* (cadddr e) lw))
                                         (+ (caddr e) (* (- 1 (caddr e)) g)))))
                                    (list-head ripple-echoes n)))))))
                  segments))
            ; reverse tongue rams: from early on, ever closer together; tilting with the
            ; curl, out of phase; accents now and then; louder as they go (cue 1 glides
            ; their amp up over 30 s)
            ; the rams, and where their dynamics go: (x . dynamic) for each change
            (placed
             (let loop ((s 2.5) (j 0) (last-dyn #f) (out '()) (dyns '()) (lows '()))
               (let ((p (/ s w)))
                 (if (> s (- w 3)) (list out (reverse dyns) lows)
                     (let* ((size (* 1.4 (g-rand rs 0.55 1.15)))   ; sizes vary
                            (len (* size (g-rand rs 2.5 3.0)))
                            (h (* size (g-rand rs 0.7 0.8)))
                            (y (let ((r (* 0.5 (- (inexact->exact (floor (g-rand rs 0 7))) 3))))   ; -1.5 .. 1.5
                                 (cond ((= j 3) 4)       ; on the second ledger line above
                                       ((= j 1) -3)      ; on the first ledger line below
                                       (else r))))
                            (dyn (cond ((< p 0.25) "pp") ((< p 0.5) "p") ((< p 0.75) "mp") (else "mf")))
                            (show (not (equal? dyn last-dyn)))
                            (note (ram-note grob (+ x0 s) y len h (ram-tilt p rs) (< (random 1.0 rs) 0.3) #f)))
                       (loop (+ s (* (g-rand rs 0.8 1.25) (/ 10.0 (+ 0.9 (* 2.2 p))))) (1+ j)
                             (if show dyn last-dyn) (cons note out)
                             (if show (cons (cons (+ x0 s (* 0.5 len)) dyn) dyns) dyns)
                             (if (< y -2.5) (cons (cons (+ x0 s) (+ x0 s len)) lows) lows)))))))
            (rams (car placed))
            ; the dynamics under the rams, a little higher or lower each time (lower still
            ; under a ram below the staff), joined by crescendo hairpins at the angle between
            ; them
            (dyn-xs (map car (cadr placed)))
            (dyns (map (lambda (d k)
                         (let* ((x (car d))
                                ; a ram below the staff near it, or between it and a neighbour:
                                ; this dynamic (and so the hairpin) goes below the ram
                                (prev (if (> k 0) (list-ref dyn-xs (1- k)) x))
                                (next (if (< k (1- (length dyn-xs))) (list-ref dyn-xs (1+ k)) x))
                                (under-low (any (lambda (lo) (< (- prev 2.5) (car lo) (+ next 2.5)))
                                                (caddr placed)))
                                (y (if under-low -5.0 (if (even? k) -3.4 -3.9))))
                           (cons (ly:stencil-translate
                                  (ly:stencil-aligned-to
                                   (grob-interpret-markup grob (make-fontsize-markup -1 (make-dynamic-markup (cdr d))))
                                   X CENTER)
                                  (cons x y))
                                 y)))
                       (cadr placed) (iota (length (cadr placed)))))
            (dyn-sts (map car dyns))
            (hairpins
             (if (< (length dyns) 2) '()
                 (map (lambda (a b)
                        (let* ((l (+ (cdr (ly:stencil-extent (car a) X)) 0.6))
                               (r (- (car (ly:stencil-extent (car b) X)) 0.6))
                               (ya (+ (cdr a) 0.45)) (yb (+ (cdr b) 0.45)))
                          (if (< (- r l) 1.5) empty-stencil
                              (stack (list (make-line-stencil 0.1 l ya r (+ yb 0.45))
                                           (make-line-stencil 0.1 l ya r (- yb 0.45)))))))
                      (list-head dyns (1- (length dyns))) (cdr dyns)))))
       (stack (append lines rams dyn-sts hairpins)))))

% Dynamics under a prominent swell: p < f > p below the staff, the f lower than the p's and
% the second p a little higher than the first, the hairpins at the angles between them
#(define (swell-dynamics grob xs xp xe yp)
   (let* ((mk (lambda (d x y)
                (cons (ly:stencil-translate
                       (ly:stencil-aligned-to
                        (grob-interpret-markup grob (make-fontsize-markup -1 (make-dynamic-markup d)))
                        X CENTER)
                       (cons x y))
                      y)))
          (a (mk "p" xs yp)) (b (mk "f" xp (- yp 0.65))) (c (mk "p" xe (+ yp 0.3)))
          (pin (lambda (u v cresc?)
                 (let* ((l (+ (cdr (ly:stencil-extent (car u) X)) 0.5))
                        (r (- (car (ly:stencil-extent (car v) X)) 0.5))
                        (ya (+ (cdr u) 0.45)) (yb (+ (cdr v) 0.45)))
                   (cond ((< (- r l) 1.2) empty-stencil)
                         (cresc? (stack (list (make-line-stencil 0.1 l ya r (+ yb 0.42))
                                              (make-line-stencil 0.1 l ya r (- yb 0.42)))))
                         (else (stack (list (make-line-stencil 0.1 l (+ ya 0.42) r yb)
                                            (make-line-stencil 0.1 l (- ya 0.42) r yb)))))))))
     (stack (list (car a) (car b) (car c) (pin a b #t) (pin b c #f)))))

%% ------------------------------------------------------------------ bars 2-3: the arc

% the flute's contour in bar 2 (c'' d'' e'' g'' a'' c''' a'' g'' e'' d''), staff positions
% mapped into the staff
#(define arc-points '(0.5 1 1.5 2.5 3 4 3 2.5 1.5 1))
#(define (arc-y p)                      ; p 0..1 along the arc
   (let* ((n (1- (length arc-points)))
          (x (* p n)) (i (min (inexact->exact (floor x)) (1- n))) (f (- x i))
          (f2 (- 0.5 (* 0.5 (cos (* 3.14159265 f)))))
          (v (+ (* (- 1 f2) (list-ref arc-points i)) (* f2 (list-ref arc-points (1+ i))))))
     (+ -1.5 (* (- v 0.5) (/ 3.0 3.5)))))

% echo copies: (offset along the music in staff spaces, grey, line-width factor); the later
% ones curl
#(define arc-copies
   '((3 0.38 0.85) (7 0.5 0.75) (12 0.58 0.68) (18 0.65 0.6) (25 0.71 0.55) (33 0.76 0.5)
     (42 0.8 0.45) (52 0.84 0.4) (63 0.87 0.38)))

#(define (arc-curve u0 u1 dy curl)      ; points from u0 to u1 (staff spaces along the arc)
   (let ((len (- u1 u0)))
     (map (lambda (j)
            (let* ((s (* len (/ j 120))) (p (/ s len))
                   (phi (* 2 3.14159265 (/ s 1.1)))
                   (a (* 0.3 curl)))
              (cons (+ u0 s (- (* a (sin phi)))) (+ (arc-y p) dy (* a (cos phi))))))
          (iota 121))))

#(define (arc-stencil grob)
   (let* ((orig (ly:grob-original grob))
          (pieces (if orig (ly:spanner-broken-into orig) '()))
          (first (or (null? pieces) (eq? grob (car pieces))))
          (sp (g-span grob)) (x0 (car sp)) (w (- (cdr sp) (car sp)))
          ; the arc's own length: the first line's span
          (w1 (if first w (let ((s1 (g-span (car pieces)))) (- (cdr s1) (car s1)))))
          (arc-len (- w1 1.0))
          ; this line shows u from `from` (music staff spaces since the arc's start)
          (from (if first 0 w1))
          (shift (lambda (pts) (map (lambda (q) (cons (+ x0 0.4 (- (car q) from)) (cdr q))) pts)))
          (clip (lambda (pts) (filter (lambda (q) (and (>= (car q) x0) (<= (car q) (+ x0 w)))) pts)))
          (main (if first (polyline (shift (arc-curve 0 arc-len 0 0)) 0.32) empty-stencil))
          (copies
           (map (lambda (c k)
                  (let* ((off (car c)) (g (cadr c)) (f (caddr c))
                         (curl (max 0 (/ (- k 2) 6)))
                         (pts (clip (shift (arc-curve off (+ off arc-len) (* 0.1 k) curl)))))
                    (in-grey (polyline pts (* 0.32 f)) g)))
                arc-copies (iota (length arc-copies)))))
     (stack (cons main copies))))

%% ------------------------------------------------------------------ bar 3: wedges

% the grains from bar 3 to the swell (bar 4)
#(define grain-bands '(1.333 0 -1.333))
#(define grain-density 32)          % dots per staff space of length, all bands together
#(define band-gathered 0.32)        % a band's half-height at the pentachord (0.667: touching)


% (entry fraction, centre y): low enters first, high a third in, middle two thirds in
#(define wedge-layers '((0 . -1.333) (0.333 . 1.333) (0.667 . 0)))
% the fraction of the bar where the fill turns to grains
#(define wedge-solid 0.85)

% Over the wedges, echoes of the slap tongues (the flute's, and the texture's own): tongue rams
% the size of cue 1's reverse ones, but forward -- a hard cut, then the tail dying away
% exponentially (fwd-ram-head) -- each with fainter, smaller echoes after it (ram-echoes),
% between the wedges' lines, closer together as cue 2 goes on
#(define (slap-sprinkles rs x0 w)
   (let loop ((p 0.07) (out '()))
     (if (> p 0.8) out
         (let* ((size (* 1.4 (g-rand rs 0.55 1.1)))
                (len (* size (g-rand rs 2.5 3.0)))
                (h (* size (g-rand rs 0.7 0.8)))
                (x (+ x0 (* w p)))
                (y (+ (list-ref '(-2 -0.667 0.667 2) (inexact->exact (floor (g-rand rs 0 3.999))))
                      (g-rand rs -0.15 0.15)))
                (tilt (g-rand rs -10 -2)))
           (loop (+ p (* (g-rand rs 0.75 1.25) (- 0.13 (* 0.07 (/ p 0.8)))))
                 (append (cons (fwd-ram-head x y len h tilt)
                               (map (lambda (e)
                                      (in-grey (fwd-ram-head (+ x (* (car e) len)) y (* (cadr e) len)
                                                             (* (cadr e) h) tilt)
                                               (caddr e)))
                                    ram-echoes))
                         out))))))

#(define (wedges-stencil grob)
   (let* ((rs (seed->random-state 5)) (rs2 (seed->random-state 7))
          (sp (g-span grob)) (x0 (+ (car sp) 0.3)) (w (- (cdr sp) (car sp) 0.3))
          (half (lambda (p entry) (* 0.667 (expt (max 0 (/ (- p entry) (- 1 entry))) 1.0))))
          (n 30))
     (stack
      (append
      (append-map
       (lambda (layer)
         (let* ((entry (car layer)) (yc (cdr layer))
                (solid-from entry) (solid-to wedge-solid))
           (append
            ; the fill, in slices from light at the entry to black
            (map (lambda (j)
                   (let* ((p0 (+ solid-from (* (- solid-to solid-from) (/ j n))))
                          (p1 (+ solid-from (* (- solid-to solid-from) (/ (1+ j) n))))
                          (h0 (half p0 entry)) (h1 (half p1 entry))
                          (g (* 0.85 (- 1 (/ (+ j 0.5) n)))))
                     (in-grey (polygon (list (cons (+ x0 (* w p0)) (+ yc h0))
                                             (cons (+ x0 (* w p1) 0.01) (+ yc h1))
                                             (cons (+ x0 (* w p1) 0.01) (- yc h1))
                                             (cons (+ x0 (* w p0)) (- yc h0))))
                              g)))
                 (iota n))
            ; then grains within the wedge, thinning out towards the barline to the density
            ; of the grains that follow (grain-density over the whole staff), so the texture
            ; carries on without a step
            (let* ((xa (* w wedge-solid)) (len (- w xa)) (dx 0.05))
              (let loop ((x 0) (out '()))
                (if (> x len) out
                    (let* ((q (/ x len))
                           (p (+ wedge-solid (* q (- 1 wedge-solid))))
                           (h (half p entry))
                           ; per band: from 6x down to 1x the following grains' density
                           (d (* (/ grain-density 3) (- 6 (* 5 (smoothstep 0 1 q)))))
                           (n (* dx d))
                           (k (+ (inexact->exact (floor n)) (if (< (random 1.0 rs) (- n (floor n))) 1 0))))
                      (loop (+ x dx)
                            (append (map (lambda (_)
                                           (dot (+ x0 xa x (g-rand rs 0 dx)) (+ yc (g-rand rs (- h) h))
                                                (g-rand rs 0.035 0.07)))
                                         (iota k))
                                    out)))))))))
       wedge-layers)
      (slap-sprinkles rs2 x0 w)))))

%% ------------------------------------------------------------------ bar 4: grains, swell

% One texture from bar 3's dissolving wedges to the end of cue 3's swell: grains over the whole
% staff that gather, towards the pentachord, into three registers (the three patterns ~swell
% acts on); after the pentachord the swell (+15 dB, 3 s up, 8 s down) makes each band denser and
% taller to its peak, then thinner and sparser than before.

% the bands' centres when spread by s (staff spaces): the outer two move apart at a swell
#(define (band-centres s) (list (+ 1.333 s) 0 (- -1.333 s)))

#(define* (grains-at rs x0 w x-step hw-of dens-of size-of #:optional (spread-of (lambda (q) 0)))
   (let loop ((x 0) (out '()))
     (if (> x w) out
         (let* ((q (/ x w)) (hw (hw-of q)) (n (* x-step (dens-of q)))
                (centres (band-centres (spread-of q)))
                (k (+ (inexact->exact (floor n)) (if (< (random 1.0 rs) (- n (floor n))) 1 0))))
           (loop (+ x x-step)
                 (append (map (lambda (_)
                                (dot (+ x0 x (g-rand rs 0 x-step))
                                     (+ (list-ref centres (inexact->exact (floor (g-rand rs 0 2.999))))
                                        (g-rand rs (- hw) hw))
                                     (size-of q rs)))
                              (iota k))
                         out))))))

% where this staff's lines start again, after the spanner's start, relative to it
#(define (staff-start-after grob)
   (let* ((sys (ly:grob-system grob))
          (vag (ly:grob-parent grob Y))
          (me (ly:grob-relative-coordinate grob sys X))
          (starts (filter-map
                   (lambda (g)
                     (and (grob::has-interface g 'staff-symbol-interface)
                          (eq? (ly:grob-system g) sys)
                          (let ((l (- (car (ly:grob-extent g sys X)) me)))
                            (and (> l 1.0) l))))
                   (ly:grob-array->list (ly:grob-object vag 'elements)))))
     (if (null? starts) #f (apply min starts))))

#(define (grains-stencil grob)
   (let* ((rs (seed->random-state 11))
          (sp (g-span grob)) (x0 (car sp))
          ; flush up to the pentachord's stretch of staff
          (lefts (filter (lambda (l) (> l (+ x0 1))) (map caar (fan-boxes grob))))
          (w (- (if (pair? lefts) (- (apply min lefts) 0.1) (- (cdr sp) 1.0)) x0 0.08)))
     (stack (grains-at rs x0 w 0.05
                       (lambda (q) (- 0.667 (* (- 0.667 band-gathered) (expt q 1.2))))
                       (lambda (q) grain-density)
                       (lambda (q rs) (g-rand rs 0.035 0.07))))))

% the swell's shape (cue 3: +15 dB): 0 -> 1 at 3/11 of the way (3 s), back to 0 (8 s)
#(define swell-peak 3/11)
#(define (swell-env p)
   (if (< p swell-peak)
       (expt (/ p swell-peak) 1.6)
       (expt (/ (- 1 p) (- 1 swell-peak)) 1.3)))

% the right end of a \collection fan at the spanner's start, relative to it (via the hidden
% stem that carries the fan's width)
#(define (fan-end grob)
   (let* ((sys (ly:grob-system grob))
          (col (ly:spanner-bound grob LEFT))
          (me (ly:grob-relative-coordinate grob sys X))
          (ends (filter-map
                 (lambda (g)
                   (and (grob::has-interface g 'stem-interface)
                        (eq? (ly:item-get-column g) col)
                        (not (eq? (ly:grob-common-refpoint g grob Y) sys))   ; this staff
                        (let ((e (ly:grob-extent g sys X)))
                          (and (not (interval-empty? e)) (- (cdr e) me)))))
                 (ly:grob-array->list (ly:grob-object sys 'all-elements)))))
     (and (pair? ends) (apply max ends))))

#(define (swell-stencil grob)
   (let* ((rs (seed->random-state 3))
          (sp (g-span grob))
          (x0 (+ (or (fan-end grob) (car sp)) 0.8))     ; after the pentachord's fan
          (w (- (cdr sp) x0 0.6)))
     (ly:stencil-add
      empty-stencil
      (stack (grains-at rs x0 w 0.05
                       ; half-height: from the gathered bands up to 1.06 at the peak (cue 6's
                       ; +16 dB reaches 1.15), down to 0.12
                       (lambda (q) (let ((e (swell-env q)))
                                     (if (< q swell-peak) (+ band-gathered (* (- 1.06 band-gathered) e))
                                         (+ 0.12 (* 0.94 e)))))
                       ; density: from the grains' density to solid black at the peak, down to
                       ; almost nothing
                       (lambda (q) (let* ((e (swell-env q)) (peak (* grain-density (+ (* 6 e) (* 28 (expt e 4))))))
                                     (if (< q swell-peak) (+ grain-density peak)
                                         (+ 3 peak))))
                       (lambda (q rs) (+ 0.035 (* 0.045 (swell-env q)) (g-rand rs 0 0.035)))
                       ; the outer bands move apart at the peak
                       (lambda (q) (* 0.72 (swell-env q))))))))

%% ------------------------------------------------------------------ bars 5-7: the swells go on

% The texture of bar 4 carries on through the next system, drawn against the patch's real
% times (the score's moments anchored to the cue times): three bands of grains (pb1-pb3),
% each band's density rising and falling with its own LFO (8, 9, 10 s), all three swelling at
% cues 3 (+15 dB, 3 s up, 8 s down), 4 (+12 dB, drawn by place: see place-swells) and 6
% (+16 dB, 3 s up, 9 s down) -- denser and taller -- with the overall level (pbAmp) up at
% cue 5 and down 9 s after cue 6. The grains leave room around the collections' notes.
% anchors: (moment in whole notes . seconds in the render), the seconds from the score's own
% tempo map (moment->sec), so they follow any change of timing
#(define swells-anchor-moments '(71/4 73/4 159/8 171/8 91/4 185/8 25 221/8 28))
#(define (swells-anchors)
   (map (lambda (m) (cons m (moment->sec m))) swells-anchor-moments))
% swells: (start dB up down)
% (cues 4, 7 and 8 are drawn by place instead: see place-swells)
#(define swells-events '((64.9 15 3 8) (88.025 16 3 9)))

% Cues 7 and 8 (the decimation), drawn by place rather than time: each swell fills the open
% stretch between the collection right after its cue and the next collection (0 -> 1 -> 0,
% peaking at `peak` of the way), while the texture pixelizes -- at cue 7 from fully pixelated
% back to grains (down), at cue 8 from grains to fully pixelated (up), staying pixelated to
% the end of the system.
% Cue 4's swell is drawn the same way, nearly centred in its stretch, without pixels (none).
% (cue moment, dB, peak position, pixelation direction)
#(define place-swells '((73/4 12 9/20 none) (185/8 12 1/2 down) (25 14 1/3 up)))

% (from . to): the stretch between the first collection after the cue at moment m and the
% next one, on the spanner's line, relative to it; #f where the cue is not on the line
#(define (gap-after grob m)
   (let ((cx (column-x grob m)))
     (and cx
          (let* ((boxes (sort (map car (fan-boxes grob)) (lambda (a b) (< (car a) (car b)))))
                 (after (filter (lambda (b) (>= (car b) (- cx 1))) boxes)))
            (and (pair? after) (pair? (cdr after))
                 (cons (cdr (car after)) (car (cadr after))))))))

% Cue 9's first swell (+16 dB, 0.5 s up, in the caesura): drawn short, right under the cue's
% box -- which stands below the flute's caesura (\ecueToCaesura) -- rising over 3.6 staff
% spaces before it and gone by the end of the system, in grains among the pixels ('grains). (Its later swells are drawn on the next line: see
% late-swells.) ((from . to) dB peak direction), or #f when cue 9 is not on this line.
#(define (cue9-gap grob)
   (let* ((m (assoc-get "9" g-cue-moments #f))
          (cx (and m (column-x grob m))))
     (and cx
          (let* ((sys (ly:grob-system grob))
                 (me (ly:grob-relative-coordinate grob sys X))
                 (signs (filter (lambda (g) (and (grob::has-interface g 'breathing-sign-interface)
                                                 (eq? (ly:grob-system g) sys)))
                                (ly:grob-array->list (ly:grob-object sys 'all-elements))))
                 (sx (lambda (g) (+ (- (interval-center (ly:grob-extent g sys X)) me)
                                    (car (ly:grob-property g 'extra-offset '(0 . 0))))))
                 (x (if (null? signs) cx
                        (sx (fold (lambda (g b) (if (< (abs (- (sx g) cx)) (abs (- (sx b) cx))) g b))
                                  (car signs) signs)))))
            (list (cons (- x 3.6) (+ x 2.1)) 16 (/ 3.6 5.7) 'grains)))))

% the place-swells on this line: ((from . to) dB peak direction)
#(define (place-gaps grob)
   (append (filter-map (lambda (p) (let ((g (gap-after grob (car p)))) (and g (cons g (cdr p)))))
                       place-swells)
           (let ((g (cue9-gap grob))) (if g (list g) '()))))

#(define (gap-q gap x) (/ (- x (car gap)) (max 0.1 (- (cdr gap) (car gap)))))
#(define (in-gap? gap x) (< (car gap) x (cdr gap)))
% 0 -> 1 at `peak` -> 0
#(define (peak-env q peak)
  (if (< q peak) (expt (/ q peak) 1.6) (expt (/ (- 1 q) (- 1 peak)) 1.3)))

% pixelation at x: (pixels? . amount 0..1); none in a 'grains gap
#(define (pixelation gaps x)
   (let loop ((gs (if (any (lambda (g) (and (eq? (cadddr g) 'grains) (in-gap? (car g) x))) gaps)
                      '() gaps)))
     (if (null? gs) '(#f . 0)
         (let* ((g (car gs)) (gap (car g)) (dir (cadddr g)))
           (cond ((memq dir '(none grains)) (loop (cdr gs)))
                 ((in-gap? gap x)
                  (cons #t (if (eq? dir 'up) (gap-q gap x) (- 1 (gap-q gap x)))))
                 ((and (eq? dir 'up) (>= x (cdr gap))) '(#t . 1))
                 (else (loop (cdr gs))))))))

% the place-swells' gain at x (1 = +12 dB)
#(define (gap-gain gaps x)
   (apply + (map (lambda (g)
                   (if (in-gap? (car g) x)
                       (* (/ (cadr g) 12) (peak-env (gap-q (car g) x) (caddr g)))
                       0))
                 gaps)))

% x (relative to the spanner) <-> seconds, piecewise linear between the anchors on this line
#(define (time-map grob anchors)
   (filter-map (lambda (a) (let ((x (column-x grob (car a)))) (and x (cons x (cdr a))))) anchors))
#(define (x->t pts x)
   (let loop ((ps pts))
     (cond ((null? (cdr ps)) (cdar ps))
           ((<= x (car (cadr ps)))
            (let* ((a (car ps)) (b (cadr ps)) (f (/ (- x (car a)) (max 0.001 (- (car b) (car a))))))
              (+ (cdr a) (* f (- (cdr b) (cdr a))))))
           (else (loop (cdr ps))))))

% the sum of the swells' envelopes at t, 1 = +12 dB
#(define (swell-gain t)
   (apply + (map (lambda (e)
                   (let* ((t0 (car e)) (db (cadr e)) (up (caddr e)) (down (cadddr e)) (d (- t t0)))
                     (* (/ db 12)
                        (cond ((< d 0) 0)
                              ((< d up) (expt (/ d up) 1.6))
                              ((< d (+ up down)) (expt (- 1 (/ (- d up) down)) 1.3))
                              (else 0)))))
                 swells-events)))

% pbAmp at t: 0.5, up to 1 at cue 5 (3 s), down to 0.5 at cue 6 + 9 s (2 s)
#(define (pb-amp t)
   (cond ((< t 83.525) 0.5)
         ((< t 86.525) (+ 0.5 (* 0.5 (/ (- t 83.525) 3))))
         ((< t 97.025) 1)
         ((< t 99.025) (- 1 (* 0.5 (/ (- t 97.025) 2))))
         (else 0.5)))

% boxes around the \collection fans on this staff and line, relative to the spanner (the
% whole staff's height):
% ((x-from . x-to) . (y-from . y-to)), the parentheses and a little room included
#(define (fan-boxes grob)
   (let* ((sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X)))
     (filter-map
      (lambda (g)
        (and (grob::has-interface g 'stem-interface)
             (not (eq? (ly:grob-common-refpoint g grob Y) sys))
             (let ((e (ly:grob-extent g sys X)))
               (and (not (interval-empty? e)) (> (interval-length e) 2)
                    (let* ((heads (ly:grob-array->list
                                   (ly:grob-object (ly:grob-parent g X) 'note-heads)))
                           (ys (map (lambda (h)
                                      (let ((c (ly:grob-common-refpoint h grob Y)))
                                        (coord-translate (ly:grob-extent h c Y)
                                                         (- (ly:grob-relative-coordinate grob c Y)))))
                                    heads))
                           (ylo (apply min (map car ys))) (yhi (apply max (map cdr ys))))
                      ; the whole staff height: no grains above or below a collection either
                      (cons (cons (- (car e) me 0.25) (+ (- (cdr e) me) 0.25))
                            (cons -8 8)))))))
      (ly:grob-array->list (ly:grob-object sys 'all-elements)))))

% the left end of this staff's (hidden) lines on the line, at the system's start line,
% relative to the grob
#(define (staff-left grob)
   (let* ((sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X))
          (lefts (filter-map (lambda (g)
                               (and (grob::has-interface g 'staff-symbol-interface)
                                    (eq? (ly:grob-system g) sys)
                                    (- (car (ly:grob-extent g sys X)) me)))
                             (ly:grob-array->list (ly:grob-object (ly:grob-parent grob Y) 'elements)))))
     (if (null? lefts) (car (g-span grob)) (apply min lefts))))

% A collection this close to the start of a line (staff spaces from the system's start line)
% takes the space before it: its staff lines reach back to the start line, and nothing else
% is drawn there (too little room for a graphic to read).
#(define lead-room 12)
% fan-boxes, sorted, the first one reaching back to the start line when it is that close
#(define (fan-boxes-lead grob)
   (let ((bs (sort (fan-boxes grob) (lambda (a b) (< (caar a) (caar b)))))
         (sl (staff-left grob)))
     (if (and (pair? bs) (< (- (caar (car bs)) sl) lead-room))
         (cons (cons (cons (- sl 50) (cdar (car bs))) (cdr (car bs))) (cdr bs))
         bs)))

% the places grains keep clear of: every collection (the whole staff's height), and any
% stretch narrower than 6 staff spaces between two collections
#(define (fan-exclusions grob)
   (let* ((bs (fan-boxes-lead grob))
          (between (filter-map (lambda (a b)
                                 (and (< (- (caar b) (cdar a)) 6)
                                      (cons (cons (cdar a) (caar b)) '(-8 . 8))))
                               (if (pair? bs) (list-head bs (1- (length bs))) '())
                               (if (pair? bs) (cdr bs) '()))))
     (append bs between)))

% one band's state at x: (centre half-height density), for band i (0 top .. 2 bottom); at a
% swell the band gets taller and denser, and the outer bands move apart
#(define (band-state tm x i gap)
   (let* ((t (x->t tm x))
          (g (+ (swell-gain t) (gap-gain gap x)))
          (period (list-ref '(8 9 10) i))
          (lfo (+ 0.2 (* 0.8 (- 0.5 (* 0.5 (cos (/ (* 2 3.14159265 t) period)))))))
          (hw (min 1.15 (+ 0.18 (* 0.77 g))))                  ; +12 dB: 0.95, as at cue 3
          (gg (min g 1.1))
          ; denser and denser to the peak, where the band turns solid black
          (d (* (/ grain-density 3) (/ (pb-amp t) 0.5) (+ 0.6 lfo) (+ 1 (* 2.5 gg) (* 28 (expt gg 4)))))
          (yc (list-ref (band-centres (* 0.65 (min g 1.2))) i)))
     (list yc hw d)))

#(define (swells-stencil grob)
   (let* ((rs (seed->random-state 17))
          (rs2 (seed->random-state 19))            ; the stray pixels' own choices
          (sp (g-span grob)) (x0 (car sp)) (x1 (- (cdr sp) 0.6))
          (tm (time-map grob (swells-anchors)))
          (fans (fan-exclusions grob))
          (gap (place-gaps grob))
          (free (lambda (x y) (not (any (lambda (f) (and (< (caar f) x (cdar f)) (< (cadr f) y (cddr f))))
                                        fans))))
          (dx 0.05)
          ; every band's grains: (x y r), in x order
          (dots
           (sort
            (append-map
             (lambda (i)
               (let loop ((x x0) (out '()))
                 (if (> x x1) out
                     (let* ((st (band-state tm x i gap)) (yc (car st)) (hw (cadr st)) (d (caddr st))
                            (n (* dx d))
                            (k (+ (inexact->exact (floor n)) (if (< (random 1.0 rs) (- n (floor n))) 1 0)))
                            (big (min 1 (/ d (* 4 grain-density)))))
                       (loop (+ x dx)
                             (append (map (lambda (_) (list (+ x (g-rand rs 0 dx)) (+ yc (g-rand rs (- hw) hw))
                                                            (+ 0.035 (* 0.045 big) (g-rand rs 0 0.03))))
                                          (iota k))
                                     out))))))
             '(0 1 2))
            (lambda (a b) (< (car a) (car b))))))
     ; Grains until the pixelation starts (the cue 8 gap); from there the texture is drawn as
     ; pixels only: a grid of squares sized k * 2^n (0.08, 0.16, 0.32, 0.64 staff spaces), so
     ; every size's rows fit exactly inside the next one's. Column by column, left to right,
     ; each column as wide as its pixels; the size steps up with the amount. A pixel is black
     ; when the grains under it would cover enough of it (the texture downsampled): the
     ; smallest look like grains, the largest turn the dense swell into solid blocks.
     (let loop ((ds dots) (x x0)
                (out (append
                      (map (lambda (g)        ; cue 8's swell: p < f > p
                            (let ((a (caar g)) (b (cdar g)))
                              (swell-dynamics grob (+ a 0.5) (+ a (* (caddr g) (- b a))) (- b 0.5) -4.2)))
                          (filter (lambda (g) (eq? (cadddr g) 'up)) gap))
                     '())))
       (if (or (null? ds) (> x x1)) (stack (cons (pixels-stencil) out))
           (if (not (car (pixelation gap x)))
               ; grains: the next stretch up to the next change (or a step of 0.25)
               (let* ((xe (let ((edges (filter (lambda (e) (> e x))
                                               (append-map (lambda (g) (list (caar g) (cdar g))) gap))))
                            (min (+ x 0.25) (if (pair? edges) (apply min edges) (+ x 0.25)))))
                      (in (take-while (lambda (d) (< (car d) xe)) ds))
                      (rest (list-tail ds (length in))))
                 (loop rest xe (append (filter-map (lambda (d) (and (free (car d) (cadr d))
                                                                    (dot (car d) (cadr d) (caddr d))))
                                                   in)
                                       out)))
               ; pixels
               (let* ((a (cdr (pixelation gap x)))
                      (n (min 3 (inexact->exact (floor (* a 4)))))
                      (c (* 0.08 (expt 2 n)))
                      (xe (+ x c))
                      (in (take-while (lambda (d) (< (car d) xe)) ds))
                      (rest (list-tail ds (length in)))
                      (cover (make-hash-table)))      ; row -> area of grains in it
                 (for-each (lambda (d)
                             (let ((row (inexact->exact (floor (/ (cadr d) c)))))
                               (hash-set! cover row (+ (hash-ref cover row 0)
                                                       (* 3.14159 (caddr d) (caddr d))))))
                           in)
                 (loop rest xe
                       (append (filter-map
                                (lambda (kv)
                                  (let* ((row (car kv)) (frac (/ (cdr kv) (* c c)))
                                         (y0 (* row c)))
                                    (and (< (random 1.0 rs) (min 1 (* 1.3 frac)))
                                         (free (+ x (* 0.5 c)) (+ y0 (* 0.5 c)))
                                         (pixel! x (+ xe 0.005) y0 (+ y0 c 0.005)))))
                                (hash-map->list cons cover))
                               (pixel-scatter rs2 x xe c a tm gap free)
                               out))))))))

% A few stray pixels (of the column's size) around the bands while the pixels grow, so the
% sparse large pixels at the end of a pixelation come in gradually rather than all at once
#(define (pixel-scatter rs x xe c a tm gap free)
   (let ((p (* 0.5 (smoothstep 0.3 0.7 a) (- 1 (smoothstep 0.85 1.0 a)))))
     (if (>= (random 1.0 rs) p) '()
         (let* ((st (band-state tm x (inexact->exact (floor (g-rand rs 0 2.999))) gap))
                (y (+ (car st) (g-rand rs (- -0.3 (cadr st)) (+ 0.3 (cadr st)))))
                (y0 (* c (floor (/ y c)))))
           (if (free (+ x (* 0.5 c)) (+ y0 (* 0.5 c)))
               (begin (pixel! x (+ xe 0.005) y0 (+ y0 c 0.005)) '())
               '())))))

%% ------------------------------------------------------------------ real time

% The score's time in seconds, as the MIDI and the patch have it: every tempo change (printed,
% and hidden \playTempo) and every \ecue's moment, collected while the score is engraved, so
% the drawings from bar 11 on follow the patch's real times and move with them.
% ((moment . quarter notes per minute) ...), (("12" . moment) ...)
#(define g-tempos '())
#(define g-cue-moments '())
#(define (Graphics_time_engraver context)
   (make-engraver
    (listeners
     ((tempo-change-event engraver event)
      (let ((count (ly:event-property event 'metronome-count #f))
            (unit (ly:event-property event 'tempo-unit #f))
            (m (ly:moment-main (ly:context-current-moment context))))
        (if (and (number? count) unit (not (assv m g-tempos)))
            (set! g-tempos
                  (cons (cons m (* count (/ (ly:moment-main (ly:duration->moment unit)) 1/4)))
                        g-tempos)))))
     ((text-script-event engraver event)
      (let ((cue (ly:event-property event 'cue-label #f)))
        (if (and cue (not (assoc cue g-cue-moments)))
            (set! g-cue-moments
                  (cons (cons cue (ly:moment-main (ly:context-current-moment context)))
                        g-cue-moments))))))))

\layout { \context { \Voice \consists #Graphics_time_engraver } }

#(define g-tempo-table #f)
#(define (moment->sec m)
   (if (not g-tempo-table)
       (set! g-tempo-table (sort g-tempos (lambda (a b) (< (car a) (car b))))))
   (let loop ((ts g-tempo-table) (acc 0))
     (let ((m0 (caar ts)) (q (cdar ts)))
       (if (and (pair? (cdr ts)) (>= m (caadr ts)))
           (loop (cdr ts) (+ acc (* (- (caadr ts) m0) (/ 240.0 q))))
           (+ acc (* (- m m0) (/ 240.0 q)))))))

% cue n's time (s)
#(define g-cue-cache (make-hash-table))
#(define (cue n)
   (or (hash-ref g-cue-cache n)
       (let ((t (moment->sec (assoc-get (number->string n) g-cue-moments 0))))
         (hash-set! g-cue-cache n t)
         t)))

% this line's time map: a vector of (x . seconds), x relative to the spanner, through the
% line's first and last columns and every cue on it -- linear between cues, as in bars 5-10,
% so that what changes in time is drawn evenly rather than squeezed into the held notes and
% stretched over the fast figures
#(define (line-times grob)
   (let* ((sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X))
          (cols (sort (map (lambda (c) (cons (- (ly:grob-relative-coordinate c sys X) me)
                                             (ly:moment-main (ly:grob-property c 'when))))
                           (ly:grob-array->list (ly:grob-object sys 'columns)))
                      (lambda (a b) (< (car a) (car b)))))
          (m0 (cdar cols)) (m1 (cdr (last cols)))
          (cues (filter-map (lambda (c)
                              (let ((m (cdr c)))
                                (and (< m0 m m1)
                                     (let ((x (column-x grob m))) (and x (cons x m))))))
                            g-cue-moments))
          (pts (sort (append (list (car cols) (last cols)) cues) (lambda (a b) (< (car a) (car b))))))
     (list->vector (map (lambda (p) (cons (car p) (moment->sec (cdr p)))) pts))))

#(define (vx->t v x)
   (let ((n (vector-length v)))
     (cond ((<= x (car (vector-ref v 0))) (cdr (vector-ref v 0)))
           ((>= x (car (vector-ref v (1- n)))) (cdr (vector-ref v (1- n))))
           (else
            (let loop ((lo 0) (hi (1- n)))
              (if (<= (- hi lo) 1)
                  (let* ((a (vector-ref v lo)) (b (vector-ref v hi)) (dx (- (car b) (car a))))
                    (if (< dx 1e-6) (cdr b)
                        (+ (cdr a) (* (/ (- x (car a)) dx) (- (cdr b) (cdr a))))))
                  (let ((mid (quotient (+ lo hi) 2)))
                    (if (< x (car (vector-ref v mid))) (loop lo mid) (loop mid hi)))))))))

% the x where time t falls on this line, or #f when it is not on it
#(define (vt->x v t)
   (let ((n (vector-length v)))
     (if (or (< t (cdr (vector-ref v 0))) (> t (cdr (vector-ref v (1- n))))) #f
         (let loop ((lo 0) (hi (1- n)))
           (if (<= (- hi lo) 1)
               (let* ((a (vector-ref v lo)) (b (vector-ref v hi)) (dt (- (cdr b) (cdr a))))
                 (if (< dt 1e-9) (car a)
                     (+ (car a) (* (/ (- t (cdr a)) dt) (- (car b) (car a))))))
               (let ((mid (quotient (+ lo hi) 2)))
                 (if (< t (cdr (vector-ref v mid))) (loop lo mid) (loop mid hi))))))))

%% ------------------------------------------------------------------ bars 11-31: the patch, cues 9-30

% What the patch does from cue 9 on, as the drawings read it. Bands 0-2 are the treble's grain
% bands (pb3 top, pb2 middle, pb1 bottom), band 3 the bass's low swell (pb5).

#(define (ramp t t0 dur) (max 0 (min 1 (/ (- t t0) dur))))
#(define (swell-env-at d up down)
   (cond ((< d 0) 0)
         ((< d up) (expt (/ d up) 1.6))
         ((< d (+ up down)) (expt (- 1 (/ (- d up) down)) 1.3))
         (else 0)))

% ~swell calls: (cue bands dB up down)
#(define late-swells
   '((9 (0 1 2 3) 16 3 10) (11 (0 1 2 3) 12 3 6) (17 (0 1 2) 12 3 6) (18 (2) 12 3 6) (19 (2) 12 3 6)
     (21 (0 1 2) 12 3 6) (24 (0 1 2) 12 3 6)))

% ~randomSwells from cue 22 to cue 23: every 7-25 s each pattern swells with a chance of 0.75
% (+12 dB, 3 s up, 12 s down): ((time band) ...)
#(define g-random-swells #f)
#(define (random-swells)
   (or g-random-swells
       (let ((rs (seed->random-state 41)) (t1 (cue 23)))
         (set! g-random-swells
               (let loop ((t (+ (cue 22) 0.5)) (out '()))
                 (if (>= t t1) out
                     (loop (+ t (g-rand rs 7 12))
                           (append (filter-map (lambda (b) (and (< (random 1.0 rs) 0.75) (list t b)))
                                               '(0 1 2 3))
                                   out)))))
         g-random-swells)))

% A swell whose peak falls in (or just before) a brief stretch between collections -- under
% place-room staff spaces -- is drawn whole in that stretch, nearly centred (rising from
% place-from of the way, peaking at place-peak, gone by place-to), rather than by its times:
% otherwise only its tail would show, coming out of a collection. In a longer stretch it keeps
% its times (cue 19). g-swell-places, for the line being drawn: ((cue from . to) ...)
#(define place-room 30)
#(define place-from 0.08)
#(define place-peak 0.45)
#(define place-to 0.94)
#(define g-swell-places '())

% the collections on this line as stretches (from . to), overlapping ones merged
#(define (fan-spans grob)
   (let loop ((xs (map car (fan-boxes-lead grob))) (out '()))
     (cond ((null? xs) (reverse out))
           ((and (pair? out) (< (caar xs) (+ (cdar out) 1)))
            (loop (cdr xs) (cons (cons (caar out) (max (cdar out) (cdar xs))) (cdr out))))
           (else (loop (cdr xs) (cons (car xs) out))))))

#(define (swell-places grob lt x1)
   (let ((spans (fan-spans grob)) (t-start (cdr (vector-ref lt 0))))
     (filter-map
      (lambda (e)
        (let* ((t0 (cue (car e))) (tp (+ t0 (cadddr e)))
               ; a swell peaking on the line before, still sounding here (cue 9, drawn in the
               ; stretch before cue 10): placed in this line's first stretch between collections
               (carried (and (< tp t-start) (< t-start (+ tp (list-ref e 4))) (pair? spans)
                             (+ (cdr (car spans)) 0.01)))
               (xp (or (vt->x lt tp) carried)))
          (and xp
               ; the stretch after the last collection starting before the peak
               (let* ((before (filter (lambda (sp) (< (car sp) xp)) spans))
                      (from (if (pair? before) (cdr (last before)) #f))
                      (after (filter (lambda (sp) (and from (> (car sp) from))) spans))
                      (to (if (pair? after) (car (car after)) x1)))
                 (and from (> to (+ from 3)) (< (- to from) place-room)
                      (cons (car e) (cons from to)))))))
      late-swells)))

% swell e's envelope at time t, or by place at x when it is placed on this line
#(define (late-swell-env e t x)
   (let ((pl (and x (assv (car e) g-swell-places))))
     (if pl
         (let* ((from (cadr pl)) (to (cddr pl))
                (q (/ (- x from) (- to from))) (up (cadddr e)) (down (list-ref e 4)))
           (cond ((or (< q place-from) (> q place-to)) 0)
                 ((< q place-peak) (swell-env-at (* up (/ (- q place-from) (- place-peak place-from))) up down))
                 (else (swell-env-at (+ up (* down (/ (- q place-peak) (- place-to place-peak)))) up down))))
         (swell-env-at (- t (cue (car e))) (cadddr e) (list-ref e 4)))))

% 1 = +12 dB (x: where on the line, for the swells drawn by place)
#(define* (band-gain t b #:optional x)
   (+ (apply + (map (lambda (e)
                      (if (memv b (cadr e))
                          (* (/ (caddr e) 12) (late-swell-env e t x))
                          0))
                    late-swells))
      (apply + (map (lambda (r) (if (= (cadr r) b) (swell-env-at (- t (car r)) 3 12) 0))
                    (random-swells)))))

% density (1 = as before): all thin out to nothing at cue 19 (4 s); pb3 back at cue 20 (2 s);
% at cue 22 pb2 (2 s), pb1 (8 s), pb5 (20 s)
#(define (band-density t b)
   (let ((c19 (cue 19)) (c20 (cue 20)) (c22 (cue 22)))
     (cond ((< t c19) 1)
           ((and (= b 0) (>= t c20)) (ramp t c20 2))
           ((>= t c22) (ramp t c22 (list-ref '(2 2 8 20) b)))
           (else (- 1 (ramp t c19 4))))))

% pitched (0 noise .. 1 pitch): 0.5; to 0 at cue 13 (5 s), 1 at cue 16 (3 s), 0 at cue 19
% (4 s), pb3 0.5 at cue 20 (4 s), all 1 at cue 22 (6 s)
#(define (band-pitched t b)
   (let ((c13 (cue 13)) (c16 (cue 16)) (c19 (cue 19)) (c20 (cue 20)) (c22 (cue 22)))
     (cond ((< t c13) 0.5)
           ((< t c16) (* 0.5 (- 1 (ramp t c13 5))))
           ((< t c19) (ramp t c16 3))
           ((< t c22) (if (and (= b 0) (>= t c20)) (* 0.5 (ramp t c20 4)) (- 1 (ramp t c19 4))))
           (else (let ((p0 (if (= b 0) 0.5 0))) (+ p0 (* (- 1 p0) (ramp t c22 6))))))))

% tongue rams instead of slaps: pb1 from cue 12, pb2 13, pb3 14, pb5 16, all slaps again at 18
#(define (band-ram? t b)
   (and (< t (cue 18)) (>= t (cue (list-ref '(14 13 12 16) b)))))

% the decimation (always on, its mix swept by slow LFOs), drawn as pixelation in three
% stretches: relaxing from the pixels at the end of bar 10 to cue 10; growing through the end
% of the random swells (bar 22); and a slow sinusoid (16 s) from cue 26 on
#(define (texture-pixelation t)
   (let ((c9 (cue 9)) (c10 (cue 10)) (c22 (cue 22)) (c23 (cue 23)) (c26 (cue 26)))
     (max (if (< t (+ c10 1)) (- 1 (smoothstep (+ c9 4) (+ c10 1) t)) 0)
          (* (smoothstep (+ c22 8) (- c23 4) t) (- 1 (smoothstep (- c23 3) c23 t)))
          (if (> t c26) (max 0 (sin (* 2 3.14159265 (/ (- t c26) 16)))) 0))))

% ~randomSets from cue 22: a new five-note chord every 0.1-0.5 s: ((time steps ...) ...),
% latest first; steps are diatonic (0 = C .. 6 = B)
#(define (random-steps rs n)
   (let loop ((out '()))
     (if (= (length out) n) out
         (let ((k (inexact->exact (floor (g-rand rs 0 6.999)))))
           (loop (if (memv k out) out (cons k out)))))))
#(define g-random-sets #f)
#(define (random-sets)
   (or g-random-sets
       (let ((rs (seed->random-state 43)) (t1 (cue 23)))
         (set! g-random-sets
               (let loop ((t (cue 22)) (out '()))
                 (if (>= t t1) out
                     (loop (+ t (g-rand rs 0.1 0.5)) (cons (cons t (random-steps rs 5)) out)))))
         g-random-sets)))
#(define (random-set-at t)
   (and (>= t (cue 22)) (< t (cue 23))
        (let ((seg (find (lambda (s) (<= (car s) t)) (random-sets)))) (and seg (cdr seg)))))

% the collections on this line: ((x-from x-to staff-positions) ...), in order
#(define (fan-chords grob)
   (let* ((sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X)))
     (sort
      (filter-map
       (lambda (g)
         (and (grob::has-interface g 'stem-interface)
              (not (eq? (ly:grob-common-refpoint g grob Y) sys))
              (let ((e (ly:grob-extent g sys X)))
                (and (not (interval-empty? e)) (> (interval-length e) 2)
                     (list (- (car e) me) (- (cdr e) me)
                           (map (lambda (h) (ly:grob-property h 'staff-position))
                                (ly:grob-array->list
                                 (ly:grob-object (ly:grob-parent g X) 'note-heads))))))))
       (ly:grob-array->list (ly:grob-object sys 'all-elements)))
      (lambda (a b) (< (car a) (car b))))))

% the chord sounding at x: the last collection before it (or the line's first)
#(define (chord-at chords x)
   (let ((before (filter (lambda (c) (<= (car c) x)) chords)))
     (caddr (if (pair? before) (last before) (car chords)))))
#(define (chord-steps chords x)
   (map (lambda (sp) (modulo (+ sp 6) 7)) (chord-at chords x)))

% a grain's height when the sound is pitched: drawn towards the nearest of the chord's notes,
% laid out over the band (low to high), so at pitched 1 the band turns into dotted lines
#(define (pitch-y rs y yc hw steps p)
   (if (or (<= p 0.5) (not steps)) y
       (let* ((r (max hw 0.55))
              (rows (map (lambda (k) (+ yc (* r (/ (- k 3) 3)))) steps))
              (near (fold (lambda (a b) (if (< (abs (- a y)) (abs (- b y))) a b)) (car rows) rows))
              (s (* 0.6 (min 1 (* 2 (- p 0.5))))))
         (+ y (* s (- near y)) (* s (g-rand rs -0.06 0.06))))))

% a band at t: (centre half-height density pitched ram? gain lfo)
#(define* (texture-band t i #:optional x)
   (let* ((g (band-gain t i x)) (gg (min g 1.1))
          (lfo (if (< t (cue 19))
                   (+ 0.2 (* 0.8 (- 0.5 (* 0.5 (cos (/ (* 2 3.14159265 t) (list-ref '(8 9 10) i)))))))
                   0.6))
          (d (* (/ grain-density 3) (+ 0.6 lfo) (+ 1 (* 2.5 gg) (* 28 (expt gg 4)))
                (band-density t i)))
          (hw (min 1.15 (+ 0.18 (* 0.77 g))))
          (yc (list-ref (band-centres (* 0.65 (min g 1.2))) i)))
     (list yc hw d (band-pitched t i) (band-ram? t i) gg lfo)))

% A tongue ram (forward): a hard vertical cut, then the horn tapering exponentially to nothing,
% tilted a little down (the sample starts sharp and settles); a fainter echo after it
#(define (fwd-ram-head x y len h tilt)
   (let* ((k 4.5) (n 20)
          (edge (lambda (t) (* h (/ (- (exp (* k t)) 1) (- (exp k) 1)))))
          (top (map (lambda (j) (let ((t (/ j n))) (cons (+ x (* len (- 1 t))) (+ y (edge t)))))
                    (iota (1+ n))))
          (bottom (map (lambda (q) (cons (car q) (- (* 2 y) (cdr q)))) (reverse top))))
     (ly:stencil-rotate-absolute (polygon (append top bottom)) tilt x y)))
#(define (fwd-ram x y len h tilt)
   (fwd-ram-head x y len h tilt))

% Wind tones (pbs1 as \windSynth, cue 19 into cue 21, fading over 7 s): short breathy notes at
% the chord's pitches, each an open circle (air, as the flute's wind tones) and a line that
% starts as air -- grey stipple -- and only begins to find its pitch (a thin tapered stroke)
% before it ends
#(define (wind-stroke xa xb y)
   (let* ((r 0.32)
          (xs (+ xa (* 2 r) 0.12))
          (xt (+ xs (* 0.5 (- xb xs))))
          (air (map (lambda (k) (in-grey (dot (+ xs (* 0.14 k)) y 0.032) 0.35))
                    (iota (max 0 (inexact->exact (floor (/ (- xt xs) 0.14)))))))
          (tone (if (< (- xb xt) 0.3) empty-stencil
                    (let ((xm (+ xt (* 0.55 (- xb xt)))))
                      (polygon (list (cons xt y) (cons xm (+ y 0.055)) (cons xb y) (cons xm (- y 0.055))))))))
     (stack (cons* (stencil-with-color
                    (stack (list (ly:stencil-translate (make-circle-stencil (+ r 0.12) 0 #t) (cons (+ xa r) y))
                                 (make-filled-box-stencil (cons (+ xa r) xb) (cons (- y 0.14) (+ y 0.14)))))
                    white)
                   (ly:stencil-translate (make-circle-stencil r 0.07 #f) (cons (+ xa r) y))
                   tone air))))

% boxes: the collections' (x-from . x-to); a stroke stops short of the next one (and of x1)
#(define (wind-strokes lt chords boxes x1)
   (let ((rs (seed->random-state 47)) (c19 (cue 19)) (c20 (cue 20)) (c21 (cue 21)))
     (if (null? chords) '()
         (let loop ((t (+ c19 0.3)) (out '()))
           (if (> t (+ c21 7)) out
               (let* ((dur (g-rand rs 0.5 1.0))
                      ; fading from cue 21 over 7 s, quickly at first (as the patch)
                      (level (* (ramp t c19 2.0) (expt (- 1 (ramp t c21 7)) 2.5)))
                      (xa (vt->x lt t))
                      (in-box (and xa (any (lambda (f) (< (- (car f) 0.3) xa (+ (cdr f) 0.3))) boxes)))
                      (stop (and xa (apply min (cons x1 (filter (lambda (l) (> l xa))
                                                                 (map (lambda (f) (- (car f) 0.4)) boxes))))))
                      (xb (and xa (min stop (or (vt->x lt (+ t dur)) x1))))
                      (y (and xa (+ (/ (list-ref (chord-at chords xa)
                                                 (inexact->exact (floor (g-rand rs 0 4.999))))
                                       2)
                                    (* 0.5 (inexact->exact (floor (g-rand rs 0 2.999)))))))
                      (ok (and xa (not in-box) (> (- xb xa) 2) (< (random 1.0 rs) level))))
                 (loop (+ t (g-rand rs 0.12 0.3))
                       (if ok (cons (wind-stroke xa xb y) out) out))))))))

% The freeze (cue 22: the flute's sound held until cue 23, then let go over 2 s): a clear lane
% at the pitch it caught (the A-flat), outlined, with a light hatching, closing to a point as it
% fades, bending with the held sound's pitch. On this line: (x-from x-to y x-fade-start
% starts-here? y-at-x) or #f.
#(define freeze-y -0.5)
#(define (freeze-lane lt x0 x1)
   (let* ((n (vector-length lt))
          (tl0 (cdr (vector-ref lt 0))) (tl1 (cdr (vector-ref lt (1- n))))
          (ta (+ (cue 22) 0.15)) (tb (cue 23)) (tc (+ tb 2)))
     (and (< tl0 tc) (< ta tl1)
          (list (if (> ta tl0) (vt->x lt ta) x0)
                (if (< tc tl1) (vt->x lt tc) x1)
                freeze-y
                (cond ((<= tb tl0) x0) ((< tb tl1) (vt->x lt tb)) (else x1))
                (> ta tl0)
                ; its height at x, bent (the freeze's `bend` LFO: -1 .. 0.5 semitones, drifting)
                (lambda (x) (+ freeze-y (* 0.45 (freeze-bend (vx->t lt x)))))))))
#(define (freeze-bend t)
   (let ((d (- t (cue 22))))
     (* (smoothstep 0 1.5 d)
        (+ -0.25 (* 0.75 (+ (* 0.6 (sin (/ (* 2 3.14159265 d) 9)))
                            (* 0.4 (sin (+ 1 (/ (* 2 3.14159265 d) 4.1))))))))))
#(define (freeze-stencil frz)
   (if (not frz) empty-stencil
       (let* ((xa (car frz)) (xc (cadr frz)) (xb (cadddr frz)) (hh 0.36) (yf (list-ref frz 5))
              (half (lambda (x) (if (<= x xb) hh
                                    (* hh (max 0 (- 1 (/ (- x xb) (max 0.1 (- xc xb)))))))))
              (n (max 2 (inexact->exact (ceiling (/ (- xc xa) 0.2)))))
              (xs (map (lambda (k) (+ xa (* (- xc xa) (/ k n)))) (iota (1+ n)))))
         (stack (append
                 (list (polyline (map (lambda (x) (cons x (+ (yf x) (half x)))) xs) 0.07)
                       (polyline (map (lambda (x) (cons x (- (yf x) (half x)))) xs) 0.07)
                       (if (list-ref frz 4)
                           (make-line-stencil 0.07 xa (- (yf xa) hh) xa (+ (yf xa) hh))
                           empty-stencil))
                 (map (lambda (k)
                        (let* ((x (+ xa 0.7 (* 0.9 k))) (h (* 0.75 (half x))) (y (yf x)))
                          (in-grey (make-line-stencil 0.04 x (- y h) (+ x 0.12) (+ y h)) 0.45)))
                      (iota (max 0 (inexact->exact (floor (/ (- xc xa 0.8) 0.9)))))))))))

% The grains from bar 11 to the end of bar 31: bands as in bars 5-10 that follow the patch
% above -- swelling, thinning out (cue 19) and coming back, rows of dots where the sound is
% pitched (the chord of the moment; at cue 22 a new chord every fraction of a second), more
% scattered where it is noise; tongue rams in place of a band's grains while it plays them
% (cues 12-18); pixels where the decimation shows (pixel sizes k * 2^n, one size per column,
% as at cue 8); and the wind tones and the freeze over them.
#(define (texture-stencil grob)
   (let* ((rs (seed->random-state 29)) (rs2 (seed->random-state 31)) (rs3 (seed->random-state 37))
          (sp (g-span grob)) (x0 (car sp)) (x1 (- (cdr sp) 0.6))
          (lt (line-times grob))
          (places (begin (set! g-swell-places (swell-places grob lt x1)) g-swell-places))
          (tx (lambda (x) (vx->t lt x)))
          (chords (fan-chords grob))
          (fans (fan-exclusions grob))
          ; the freeze (going on from the line before) stays out of a leading collection's room
          (frz (freeze-lane lt (let ((bs (fan-boxes-lead grob)))
                                 (if (and (pair? bs) (< (caar (car bs)) (- (staff-left grob) 10)))
                                     (max x0 (+ (cdar (car bs)) 0.3))
                                     x0))
                            x1))
          (free (lambda (x y)
                  (not (or (any (lambda (f) (and (< (caar f) x (cdar f)) (< (cadr f) y (cddr f)))) fans)
                           (and frz (< (- (car frz) 0.2) x (+ (cadr frz) 0.2))
                                (< (- ((list-ref frz 5) x) 0.45) y (+ ((list-ref frz 5) x) 0.45)))))))
          (dx 0.05)
          (rams '())
          (dots
           (sort
            (append-map
             (lambda (i)
               (let loop ((x x0) (out '()))
                 (if (> x x1) out
                     (let* ((t (tx x)) (st (texture-band t i x))
                            (yc (car st)) (hw0 (cadr st)) (d (caddr st)) (p (list-ref st 3))
                            (gg (list-ref st 5)) (lfo (list-ref st 6))
                            (u (max 0 (* 2 (- 0.5 p))))            ; noise
                            (hw (+ (* hw0 (+ 1 (* 0.8 u))) (* 0.25 u)))
                            (steps (or (random-set-at t) (and (pair? chords) (chord-steps chords x)))))
                       (if (list-ref st 4)
                           ; tongue rams
                           (begin
                             (if (< (random 1.0 rs3) (* dx 0.32 (band-density t i) (+ 0.6 lfo) (+ 1 (* 1.5 gg))))
                                 (let* ((len (* (g-rand rs3 2.2 3.6) (+ 1 (* 0.4 gg))))
                                        (h (* (g-rand rs3 0.38 0.55) (+ 1 (* 0.4 gg))))
                                        (y (pitch-y rs3 (+ yc (g-rand rs3 (- hw) hw)) yc hw0 steps p)))
                                   (if (every (lambda (q) (free q y)) (list x (+ x (* 0.5 len)) (+ x len)))
                                       (set! rams (cons (fwd-ram x y len h (g-rand rs3 -9 -3)) rams)))))
                             (loop (+ x dx) out))
                           ; grains
                           (let* ((n (* dx d))
                                  (k (+ (inexact->exact (floor n)) (if (< (random 1.0 rs) (- n (floor n))) 1 0)))
                                  (big (min 1 (/ d (* 4 grain-density)))))
                             (loop (+ x dx)
                                   (append (map (lambda (_)
                                                  (list (+ x (g-rand rs 0 dx))
                                                        (pitch-y rs (+ yc (g-rand rs (- hw) hw)) yc hw0 steps p)
                                                        (* (- 1 (* 0.35 u)) (+ 0.035 (* 0.045 big) (g-rand rs 0 0.03)))))
                                                (iota k))
                                           out))))))))
             '(0 1 2))
            (lambda (a b) (< (car a) (car b)))))
          (boxes (fan-boxes-lead grob))
          (extras (append rams
                          (wind-strokes lt chords (map car boxes) x1)
                          (list (freeze-stencil frz))
                          (grain-fragments lt x0 x1 free)
                          ; p < f > p under the swells of cues 17, 21 and 24 (3 s up, 6 down)
                          (filter-map (lambda (d)
                                        (let ((pl (assv (car d) places)))
                                         (if pl
                                          (let* ((from (cadr pl)) (w (- (cddr pl) from)))
                                            (swell-dynamics grob (+ from (* w place-from) 0.8)
                                                            (+ from (* w place-peak))
                                                            (- (+ from (* w place-to)) 0.8) (cdr d)))
                                        (let* ((t0 (cue (car d)))
                                               ; the p and f clear of the collections
                                               (clear (lambda (x) (and x (let ((b (find (lambda (b) (< (- (car b) 1.8) x (+ (cdr b) 0.6))) (map car boxes))))
                                                                           (if b (+ (cdr b) 1.0) x)))))
                                               (xs (clear (vt->x lt (+ t0 0.3))))
                                               (xp (let ((x (clear (vt->x lt (+ t0 3))))) (and x xs (clear (max x (+ xs 4))))))
                                               (xe (or (vt->x lt (+ t0 8.5)) (and xp (- x1 0.5)))))
                                          (and xs xp xe (> (- xe xp) 3)
                                               (swell-dynamics grob xs xp xe (cdr d)))))))
                                      '((17 . -4.0) (21 . -4.25) (24 . -3.9)))))
          ; after bar 10 the pixels relax by place, as at cue 7: largest at the first stretch
          ; between collections, back to grains at the next collection
          (gap0 (and (>= (length chords) 2) (< (cdr (vector-ref lt 0)) (cue 10))
                     (cons (cadr (car chords)) (car (cadr chords)))))
          (pix (lambda (x)
                 (let ((t (tx x)))
                   (cond ((not gap0) (texture-pixelation t))
                         ; (gone by 40% of the way, so cue 9's swell, peaking at 45%, shows)
                         ((< x (cdr gap0)) (- 1 (smoothstep 0 0.4 (gap-q gap0 x))))
                         ((< t (+ (cue 10) 1)) 0)
                         (else (texture-pixelation t)))))))
     ; grains, or pixels where the decimation shows (as in swells-stencil)
     (let loop ((ds dots) (x x0) (out '()))
       (if (or (null? ds) (> x x1)) (stack (append (list (pixels-stencil)) out extras))
           (let ((a (pix x)))
             (if (< a 0.04)
                 (let* ((xe (+ x 0.25))
                        (in (take-while (lambda (d) (< (car d) xe)) ds))
                        (rest (list-tail ds (length in))))
                   (loop rest xe (append (filter-map (lambda (d) (and (free (car d) (cadr d))
                                                                      (dot (car d) (cadr d) (caddr d))))
                                                     in)
                                         out)))
                 (let* ((n (min 3 (inexact->exact (floor (* a 4)))))
                        (c (* 0.08 (expt 2 n)))
                        (xe (+ x c))
                        (in (take-while (lambda (d) (< (car d) xe)) ds))
                        (rest (list-tail ds (length in)))
                        (cover (make-hash-table)))
                   (for-each (lambda (d)
                               (let ((row (inexact->exact (floor (/ (cadr d) c)))))
                                 (hash-set! cover row (+ (hash-ref cover row 0)
                                                         (* 3.14159 (caddr d) (caddr d))))))
                             in)
                   (loop rest xe
                         (append (filter-map
                                  (lambda (kv)
                                    (let* ((row (car kv)) (frac (/ (cdr kv) (* c c))) (y0 (* row c)))
                                      (and (< (random 1.0 rs) (min 1 (* 1.3 frac)))
                                           (free (+ x (* 0.5 c)) (+ y0 (* 0.5 c)))
                                           (pixel! x (+ xe 0.005) y0 (+ y0 c 0.005)))))
                                  (hash-map->list cons cover))
                                 (texture-scatter rs2 x xe c a (tx x) free)
                                 out)))))))))

% The granulator (~grainBurst at cues 12, 23, 27: the flute's last seconds as a cloud of
% grains for 5 s, fading over 3): splinters of line -- short dashes at small angles, scattered
% over the staff, among the dots
#(define grain-bursts '((12 . 1) (23 . 0) (27 . 0)))
#(define (grain-env t)
   (apply max 0 (map (lambda (c)
                       (let ((d (- t (+ (cue (car c)) (cdr c)))))
                         (cond ((< d 0) 0) ((< d 0.3) (/ d 0.3)) ((< d 5) 1)
                               ((< d 8) (- 1 (/ (- d 5) 3))) (else 0))))
                     grain-bursts)))
#(define (grain-fragments lt x0 x1 free)
   (let ((rs (seed->random-state 59)))
     (let loop ((x x0) (out '()))
       (if (> x x1) out
           (let* ((n (* 0.1 3.5 (grain-env (vx->t lt x))))
                  (k (+ (inexact->exact (floor n)) (if (< (random 1.0 rs) (- n (floor n))) 1 0))))
             (loop (+ x 0.1)
                   (append
                    (filter-map
                     (lambda (_)
                       (let* ((xa (+ x (g-rand rs 0 0.1))) (y (g-rand rs -2.7 2.7))
                              (len (g-rand rs 0.3 0.9)) (a (* (g-rand rs -16 16) (/ 3.14159265 180)))
                              (xb (+ xa (* len (cos a)))) (yb (+ y (* len (sin a)))))
                         ; on a thin white ground, so they read among the dots
                         (and (free xa y) (free xb yb)
                              (stack (list (stencil-with-color (make-line-stencil 0.26 xa y xb yb) white)
                                           (make-line-stencil 0.1 xa y xb yb))))))
                     (iota k))
                    out)))))))

#(define (texture-scatter rs x xe c a t free)
   (let ((p (* 0.5 (smoothstep 0.3 0.7 a) (- 1 (smoothstep 0.85 1.0 a)))))
     (if (>= (random 1.0 rs) p) '()
         (let* ((st (texture-band t (inexact->exact (floor (g-rand rs 0 2.999))) x))
                (y (+ (car st) (g-rand rs (- -0.3 (cadr st)) (+ 0.3 (cadr st)))))
                (y0 (* c (floor (/ y c)))))
           (if (and (> (caddr st) 1) (free (+ x (* 0.5 c)) (+ y0 (* 0.5 c))))
               (begin (pixel! x (+ xe 0.005) y0 (+ y0 c 0.005)) '())
               '())))))

% Echo bursts (cues 10, 14, 25, 28): the hidden staff lines come back as ripples -- curling
% (as in bar 1) while the burst listens (1 s), then rippling out over 15 s, smaller and
% fainter, broken, with echoes. Between two collections where a burst sounds, the lines run
% the whole way: out of the collection's staff as its five black lines, curling and echoing
% gradually over several staff spaces, and back to the five lines into the next collection's
% staff (as the ripples in bar 1 come out of the staff). Behind the grains.
#(define bursts '((10 . 1) (14 . 1) (25 . 1) (28 . 0)))
#(define (burst-env t)
   (apply + (map (lambda (b)
                   (let ((d (- t (+ (cue (car b)) (cdr b)))))
                     (cond ((< d 0) 0) ((< d 1) d) ((< d 16) (exp (/ (- 1 d) 3.2))) (else 0))))
                 bursts)))

% staff spaces from a collection's staff to full curl; drawn in short pieces (staff spaces),
% so grey and width change smoothly
#(define burst-join 11)
#(define burst-piece 0.35)

% the stretches between collections on this line: (from from-staff? to to-staff?), from-staff?
% when it starts at a collection's staff (fan-staff-stencil: its ")" + 0.1), to-staff? when it
% ends at one
#(define (burst-gaps grob x0 x1)
   (let loop ((fs (fan-boxes-lead grob))
              (from x0) (from-staff? #f) (out '()))
     (if (null? fs)
         (reverse (if (< from x1) (cons (list from from-staff? x1 #f) out) out))
         (let ((l (- (caar (car fs)) 0.1)) (r (+ (cdar (car fs)) 0.1)))
           (loop (cdr fs) (max from r) #t
                 (if (< from l) (cons (list from from-staff? l #t) out) out))))))

#(define (bursts-stencil grob)
   (let* ((rs (seed->random-state 53))
          (sp (g-span grob)) (x0 (car sp)) (x1 (- (cdr sp) 0.6))
          (lt (line-times grob))
          (th (ly:staff-symbol-line-thickness grob))
          (env (lambda (x) (min 1 (burst-env (vx->t lt x)))))
          (ds 0.04)
          (pieces '()))                 ; (points curl grey width echo-limit)
     (for-each
      (lambda (gap)
        (let* ((ga (car gap)) (gb (caddr gap))
               (jl (min burst-join (* 0.45 (- gb ga))))  ; shorter between close collections
               ; the echoes stay out of the straight lines going into a collection's staff
               (echo-limit (if (cadddr gap) (- gb (* 0.6 jl)) x1))
               ; 1 at a collection's staff, 0 from jl on
               (joined (lambda (x)
                         (max (if (cadr gap) (- 1 (smoothstep ga (+ ga jl) x)) 0)
                              (if (cadddr gap) (smoothstep (- gb jl) gb x) 0))))
               ; where the burst first shows in this stretch (#f: it doesn't)
               (x-on (find (lambda (x) (> (env x) 0.12))
                           (map (lambda (k) (+ ga (* k 0.25)))
                                (iota (inexact->exact (ceiling (/ (- gb ga) 0.25)))))))
               ; out of a collection's staff the lines curl at once, even where the burst
               ; starts a little later (1 s after its cue)
               (curl-at (lambda (x) (env (if (and x-on (cadr gap)) (max x x-on) x)))))
          (if x-on
              (for-each
               (lambda (i)
                 (let ((y0 (- i 2)))
                   (let loop ((x ga) (phi (* i 1.7)) (on #t) (left (g-rand rs 2.5 6)) (pts '()) (ks '())
                              (js '()) (af 1) (lf 1))
                     (let* ((flush (lambda ()
                                     (if (> (length pts) 1)
                                         (set! pieces
                                               (cons (let* ((k (/ (apply + ks) (length ks)))
                                                            (j (/ (apply + js) (length js)))
                                                            (g (* (- 1 j) (+ 0.3 (* 0.5 (- 1 k))))))
                                                       (list (reverse pts) k g
                                                             (+ (* j th) (* (- 1 j) (+ 0.07 (* 0.05 k))))
                                                             echo-limit))
                                                     pieces)))))
                            (c (curl-at x)) (j (joined x)) (k (* c (- 1 j)))
                            (a (* 0.42 k af))
                            (lam (* lf (+ 1.1 (* 1.6 (- 1 c)))))
                            (pt (cons (- x (* a (sin phi))) (- y0 (* a (cos phi)))))
                            (phi2 (+ phi (/ (* 2 3.14159265 ds) lam)))
                            ; unbroken near a collection's staff and where (nearly) straight;
                            ; the length of the piece counts from where it curls
                            (keep (or (> j 0.05) (< k 0.12)))
                            (left2 (if keep left (- left ds)))
                            ; the next point of a drawn line; a new piece every burst-piece
                            (draw (lambda (left3 af2 lf2)
                                    (if (and (pair? pts) (> (- (car pt) (caar (last-pair pts))) burst-piece))
                                        (begin (flush)
                                               (loop (+ x ds) phi2 #t left3 (list pt (car pts)) (list k) (list j) af2 lf2))
                                        (loop (+ x ds) phi2 #t left3 (cons pt pts) (cons k ks) (cons j js) af2 lf2)))))
                       (cond ((> x gb) (if on (begin (set! pts (cons (cons gb y0) pts)) (flush))))
                             ((not on)
                              (cond (keep (draw (g-rand rs 1.5 5) af lf))
                                    ((> left2 0) (loop (+ x ds) phi2 #f left2 '() '() '() af lf))
                                    ; a new piece: its own loop size and pace, and sometimes a line stays quiet
                                    ((< (random 1.0 rs) 0.3) (loop (+ x ds) phi2 #f (g-rand rs 1 3) '() '() '() af lf))
                                    (else (set! phi2 (+ phi2 (g-rand rs 0 3)))
                                          (loop (+ x ds) phi2 #t (* (g-rand rs 1.5 5) (+ 0.4 c))
                                                (list pt) (list k) (list j) (g-rand rs 0.5 1.15) (g-rand rs 0.8 1.6)))))
                             ((or keep (> left2 0)) (draw left2 af lf))
                             (else (flush) (loop (+ x ds) phi2 #f (* (g-rand rs 0.6 2.5) (- 1.6 c)) '() '() '() af lf)))))))
               (iota 5)))))
      (burst-gaps grob x0 x1))
     (stack
      (map (lambda (pc)
             (let ((pts (car pc)) (k (cadr pc)) (g (caddr pc)) (lw (cadddr pc)) (lim (list-ref pc 4)))
               (stack (cons (in-grey (polyline pts lw) g)
                            (map (lambda (e)
                                   (in-grey (polyline (filter (lambda (q) (< (car q) lim))
                                                              (map (lambda (q) (cons (+ (car q) (* (car e) k 1.6)) (+ (cdr q) (* (cadr e) k))))
                                                                   pts))
                                                      (* lw (cadddr e)))
                                            (+ (caddr e) (* (- 1 (caddr e)) g))))
                                 (cond ((> k 0.5) (list-head ripple-echoes 2))
                                       ((> k 0.12) (list-head ripple-echoes 1))
                                       (else '())))))))
           pieces))))

%% ------------------------------------------------------------------ the bass staff: low swells, ocean

% where the bass staff's drawn lines start: where the real ones end (after the clef at cue 6),
% or at the start of the line (later systems)
#(define (bass-line-start grob)
   (let* ((sp (g-span grob))
          (sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X))
          (vag (ly:grob-parent grob Y))
          (symbols (filter (lambda (g) (and (grob::has-interface g 'staff-symbol-interface)
                                            (eq? (ly:grob-system g) sys)))
                           (ly:grob-array->list (ly:grob-object vag 'elements))))
          ; a visible stretch of staff ending inside the spanner (the one up to the clef)
          (visible-ends (filter-map (lambda (g) (and (not (ly:grob-property g 'transparent #f))
                                                     (let ((r (- (cdr (ly:grob-extent g sys X)) me)))
                                                       (and (< (car sp) r (cdr sp)) r))))
                                    symbols))
          (lefts (map (lambda (g) (- (car (ly:grob-extent g sys X)) me)) symbols)))
     (cond ((pair? visible-ends) (- (apply max visible-ends) 0.05))   ; overlap a hair
           ((pair? lefts) (apply min lefts))
           (else (car sp)))))

% pb5 at t: 1 = its swells as at cue 6; fading out where the rams take over (cues 16-18),
% thinning to nothing at cue 19, back over 20 s from cue 22
#(define (bass-level t)
   (let ((c16 (cue 16)) (c18 (cue 18)) (c19 (cue 19)) (c22 (cue 22)))
     (cond ((< t c16) 1)
           ((< t c18) (- 1 (smoothstep c16 (+ c16 1.5) t)))
           ((< t c19) (smoothstep c18 (+ c18 1.5) t))
           ((< t c22) (* (smoothstep c18 (+ c18 1.5) t) (- 1 (ramp t c19 4))))
           (else (ramp t c22 20)))))

% pb5's low swells (from cue 6, on the bass staff): not grains -- solid black shapes, slowly
% swelling and relaxing (an 11 s sinusoid, nudged by the swells), gone where pb5 is silent;
% tongue rams in their place from cue 16 to cue 18. The staff's lines are drawn with it,
% bending the opposite way: at their places where the swell is thinnest, pinched together to
% the middle line where it is fullest. The two lowest are the ocean's waves (ocean-lines), drawn
% in with the others: waves where the swell is thin, flat at the middle where it is full. (The
% real staff lines stop just after the clef; these carry them on.)
#(define (lowswell-stencil grob)
   (let* ((rs (seed->random-state 67))
          (sp (g-span grob))
          (line-start (bass-line-start grob))
          (x0 (+ (car sp) 0.3)) (x1 (- (cdr sp) 0.4))
          (lt (line-times grob))
          (tx (lambda (x) (vx->t lt (max x0 (min x x1)))))
          (t6 (cue 6))
          (swell (lambda (t) (- 0.5 (* 0.5 (cos (/ (* 2 3.14159265 (- t t6)) 11))))))   ; 0 .. 1
          (half (lambda (t) (* 1.5 (+ 0.08 (* 0.92 (swell t)))
                               (+ 1 (* 0.25 (+ (swell-gain t) (band-gain t 3))))
                               (bass-level t))))
          (yc 0)
          ; where the drawn lines continue the real ones (cue 6: after the clef), they start
          ; exactly on them and only then begin to be drawn in, over 3 staff spaces
          (joined? (> line-start (+ (car sp) 1)))
          ; how far the lines are drawn in to the middle at x (0 .. 1)
          (squeeze (lambda (x) (if (< x x0) 0
                                   (let ((t (tx x)))
                                     (* (swell t) (bass-level t)
                                        (if joined? (smoothstep line-start (+ line-start 3) x) 1))))))
          (th (ly:staff-symbol-line-thickness grob))
          (shapes
           (let loop ((x x0) (top '()) (bottom '()) (out '()))
             (let ((close (lambda () (if (< (length top) 2) out
                                         (cons (polygon (append (reverse top) bottom)) out)))))
               (if (> x x1) (close)
                   (let ((h (half (tx x))))
                     (if (< h 0.02)
                         (loop (+ x 0.1) '() '() (close))
                         (loop (+ x 0.1) (cons (cons x (+ yc h)) top) (cons (cons x (- yc h)) bottom) out)))))))
          (rams
           (let loop ((x (+ x0 (g-rand rs 0.3 1.2))) (out '()))
             (if (> x (- x1 1.5)) out
                 (let ((t (tx x)))
                   (if (band-ram? t 3)
                       (let* ((size (* (+ 0.6 (* 0.7 (swell t))) (+ 0.3 (* 0.7 (smoothstep (cue 16) (+ (cue 16) 1.5) t)))))
                              (len (+ 2.6 (* 2.6 size)))
                              (h (* (+ 0.5 (* 0.5 size)) (g-rand rs 0.8 1.1))))
                         (loop (+ x (* len (g-rand rs 1.1 1.7)))
                               (cons (fwd-ram x (+ yc (g-rand rs -0.6 0.6)) len h (g-rand rs -9 -3)) out)))
                       (loop (+ x 0.4) out))))))
          (lines
           (map (lambda (i)
                  (polyline (map (lambda (k)
                                   (let ((x (+ line-start (* 0.1 k))))
                                     (cons x (* (- i 2) (- 1 (squeeze x))))))
                                 (iota (max 0 (1+ (inexact->exact (floor (/ (- (cdr sp) line-start) 0.1)))))))
                            th))
                (iota 3 2)))
          ; the two lowest lines are the ocean: waves, drawn in to the middle with the others
          (waves (map (lambda (pl) (polyline (map (lambda (q) (cons (car q) (* (cdr q) (- 1 (squeeze (car q)))))) pl)
                                             (* 1.2 th)))
                      (ocean-lines lt line-start x0 (cdr sp)))))
     (stack (append waves shapes rams lines))))

% The ocean (from cue 6 to the end of bar 31): the bass staff's two lowest lines turn into
% waves -- a clear line drawing: the lowest line's larger crests curl over and break, the line
% above it rolls more gently and is hidden where the front waves stand in front of it. The
% waves grow out of the straight lines and rise and settle with the ocean's level (its 30 s
% LFO).
#(define (ocean-lfo t) (- 0.5 (* 0.5 (cos (/ (* 2 3.14159265 (- t (cue 2))) 30)))))

% one line of waves from xs to xe around base: a list of polylines (broken behind each curl)
#(define* (wave-line rs lt xs xe base scale break? #:optional (lscale scale) (grow 0))
   (let loop ((x xs) (cur (list (cons xs base))) (out '()))
     (let* ((wb (* lscale (g-rand rs 3.5 7.5))) (wf (* lscale (g-rand rs 2.0 3.6)))
            (xk (+ x wb)))
       (if (> (+ xk wf) xe)
           (reverse (cons (reverse (cons (cons xe base) cur)) out))
           (let* ((a (* scale (+ 0.45 (* 0.9 (ocean-lfo (vx->t lt xk)))) (g-rand rs 0.6 1.25)
                        (if (> grow 0) (smoothstep xs (+ xs grow) xk) 1)))
                  (top (+ base a))
                  (back (map (lambda (j) (let ((u (/ j 14)))
                                           (cons (+ x (* wb u))
                                                 (+ base (* a (expt (- 0.5 (* 0.5 (cos (* 3.14159265 u)))) 1.2))))))
                             (iota 14 1))))
             (if (and break? (> a (* scale 0.75)))
                 ; the crest curls forward into a spiral; the face starts again under it
                 (let* ((r (* 0.42 a)) (cy (- top r))
                        (lip (map (lambda (j)
                                    (let* ((th (- (* 0.5 3.14159265) (* (/ j 24) 1.45 3.14159265)))
                                           (rr (* r (- 1 (* 0.55 (/ j 24))))))
                                      (cons (+ xk (* rr (cos th))) (+ cy (* rr (sin th))))))
                                  (iota 25)))
                        (fx (+ xk (* 0.8 r))) (fy (- top (* 2.0 r)))
                        (face (map (lambda (j) (let ((u (/ j 12)))
                                                 (cons (+ fx (* (- (+ xk wf) fx) u))
                                                       (+ base (* (- fy base) (expt (- 1 u) 1.6))))))
                                   (iota 13))))
                   (loop (+ xk wf) (reverse face)
                         (cons (append (reverse cur) back lip) out)))
                 ; a rounded swell
                 (let ((front (map (lambda (j) (let ((u (/ j 12)))
                                                 (cons (+ xk (* wf u))
                                                       (+ base (* a (expt (+ 0.5 (* 0.5 (cos (* 3.14159265 u)))) 1.2))))))
                                   (iota 12 1))))
                   (loop (+ xk wf) (append (reverse front) (reverse back) cur) out))))))))

% (a list of polylines, as point lists)
#(define (ocean-lines lt line-start xs xe)
   (let* ((rs (seed->random-state 61)) (rs2 (seed->random-state 71))
          (xe (- xe 0.4))
          ; straight from the start of the line (through the clef) to where the waves begin
          (front (cons (list (cons line-start -2) (cons xs -2))
                       (wave-line rs lt xs xe -2 0.75 #t 0.9 4)))
          (back (cons (list (cons line-start -1) (cons (+ xs 1.5) -1))
                      (wave-line rs2 lt (+ xs 1.5) xe -1 0.5 #f 0.8 4)))
          ; the highest point of the front line at each 0.1
          (x0 (min line-start xs))
          (bins (make-vector (+ 2 (inexact->exact (ceiling (* 10 (- xe x0))))) -100))
          (bin (lambda (x) (max 0 (min (- (vector-length bins) 1) (inexact->exact (floor (* 10 (- x x0)))))))))
     (for-each (lambda (pl) (for-each (lambda (q) (let ((b (bin (car q))))
                                                    (vector-set! bins b (max (vector-ref bins b) (cdr q)))))
                                      pl))
               front)
     (let* ((hidden? (lambda (q) (< (cdr q) (+ 0.12 (max (vector-ref bins (bin (car q)))
                                                         (vector-ref bins (min (- (vector-length bins) 1) (1+ (bin (car q)))))
                                                         (vector-ref bins (max 0 (1- (bin (car q))))))))))
            ; the upper line, broken where it passes behind the front
            (back-visible
             (append-map (lambda (pl)
                           (let loop ((ps pl) (cur '()) (out '()))
                             (cond ((null? ps) (if (> (length cur) 1) (cons (reverse cur) out) out))
                                   ((hidden? (car ps)) (loop (cdr ps) '() (if (> (length cur) 1) (cons (reverse cur) out) out)))
                                   (else (loop (cdr ps) (cons (car ps) cur) out)))))
                         back)))
       (append front back-visible))))

%% ------------------------------------------------------------------ staff lines under the collections

% Where the staff lines are hidden under the grains (bars 4-10), each collection keeps a short
% stretch of staff: five lines from just before its "(" to just after its ")".
#(define (fan-staff-stencil grob)
   (let ((th (ly:staff-symbol-line-thickness grob)) (sl (staff-left grob)))
     (stack
      (append-map
       (lambda (f)
         (map (lambda (i)
                (make-filled-box-stencil (cons (max sl (- (caar f) 0.1)) (+ (cdar f) 0.1))
                                         (cons (- i 2 (* 0.5 th)) (+ (- i 2) (* 0.5 th)))))
              (iota 5)))
       (fan-boxes-lead grob)))))

%% ------------------------------------------------------------------ the spanners

% (layer: the arc draws on top of the ripples)
#(define* (graphic-span stencil #:optional (layer -1))
   #{ -\tweak stencil #stencil
      -\tweak X-extent #'(0 . 0)
      -\tweak Y-offset #0
      -\tweak outside-staff-priority ##f
      -\tweak vertical-skylines #no-skylines
      -\tweak bound-details.left.attach-dir #LEFT
      -\tweak bound-details.right.attach-dir #LEFT
      -\tweak layer #layer
      \startTextSpan #})

% (fade-at: the moment, in whole notes, where bar 2 begins and the ripples start fading)
startRipples = -\tweak details.fade-at #27/2 #(graphic-span ripples-stencil)
startArc = #(graphic-span arc-stencil 0)
startWedges = #(graphic-span wedges-stencil)
startGrains = #(graphic-span grains-stencil)
startSwell = #(graphic-span swell-stencil)
startSwells = #(graphic-span swells-stencil)
startLowSwell = #(graphic-span lowswell-stencil)
startTexture = #(graphic-span texture-stencil)
startBursts = #(graphic-span bursts-stencil -2)
startFanStaff = #(graphic-span fan-staff-stencil)
stopGraphic = \stopTextSpan

% Staff lines hidden under the graphics, but the staff still there: so the system's start line
% and the electronics brace still reach it. (\stopStaff alone removes the staff, and with it
% the brace and the line joining the staves at the start of the system.)
hideStaff = {
  \stopStaff
  \override Staff.StaffSymbol.transparent = ##t
  \override Staff.BarLine.transparent = ##t
  \startStaff
}
showStaff = {
  \stopStaff
  \revert Staff.StaffSymbol.transparent
  \revert Staff.BarLine.transparent
  \startStaff
}
