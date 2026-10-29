% pitch-band: a filled band between two edges given in staff positions.
#(define-graphic! "pitch-band"
  (lambda (g p)
    (let* ((w (g-width g)) (n (max 2 (inexact->exact (ceiling (/ w 0.25)))))
           (us (map (lambda (k) (* w (/ k n))) (iota (1+ n))))
           (edge (lambda (key u) (* 0.5 (env-at (assq-ref p key) (g-q g u)))))
           (top (map (lambda (u) (cons u (edge 'high u))) us))
           (bottom (map (lambda (u) (cons u (edge 'low u))) us))
           (band (list 'gray (assq-ref p 'gray) (list 'fill (append top (reverse bottom))))))
      (if (assq-ref p 'outline)
          (list band (list 'stroke top 0.1) (list 'stroke bottom 0.1))
          (list band)))))
