% swell-shape: one filled outline, top and bottom edges from the height envelope.
#(define-graphic! "swell-shape"
  (lambda (g p)
    (let* ((w (g-width g))
           (n (max 2 (inexact->exact (ceiling (/ w 0.2)))))
           (side (let ((s (assq-ref p 'side))) (if (symbol? s) (symbol->string s) s)))
           (us (map (lambda (k) (* w (/ k n))) (iota (1+ n))))
           (edge (lambda (u sign)
                   (let ((q (g-q g u)))
                     (+ (env-at (assq-ref p 'centre) q)
                        (* sign (max 0 (env-at (assq-ref p 'height) q)))))))
           (top (map (lambda (u) (cons u (if (equal? side "down") (env-at (assq-ref p 'centre) (g-q g u)) (edge u 1)))) us))
           (bottom (map (lambda (u) (cons u (if (equal? side "up") (env-at (assq-ref p 'centre) (g-q g u)) (edge u -1)))) (reverse us))))
      (list (list 'gray (assq-ref p 'gray) (list 'fill (append top bottom)))))))
