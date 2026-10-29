% squiggle: a sine-like line whose amplitude and period wander with jitter.
#(define-graphic! "squiggle"
  (lambda (g p)
    (let* ((rs (g-random g)) (w (g-width g))
           (pace (assq-ref p 'pace)) (jitter (assq-ref p 'jitter))
           (step (/ 0.25 pace))
           (n (inexact->exact (ceiling (/ w step)))))
      (let loop ((k 0) (phase 0) (pts '()))
        (if (> k n)
            (list (list 'curve (reverse pts) (assq-ref p 'thickness)))
            (let* ((u (min w (* k step))) (q (g-q g u))
                   (a (* (env-at (assq-ref p 'width) q) (+ 1 (* jitter (g-rand rs -0.6 0.6)))))
                   (y (+ (env-at (assq-ref p 'centre) q) (* a (sin phase)))))
              (loop (1+ k) (+ phase (* 1.5707963 (+ 1 (* jitter (g-rand rs -0.5 0.5))))) (cons (cons u y) pts))))))))
