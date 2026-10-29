% staff-ripple: each staff line as a trochoid; amplitude 0 is the line itself.
#(define-graphic! "staff-ripple"
  (lambda (g p)
    (let* ((rs (g-random g))
           (w (g-width g))
           (wl (assq-ref p (quote wavelength)))
           (curl (assq-ref p 'curl))
           (two-pi (* 2 3.141592653589793))
           (n (inexact->exact (ceiling (/ w 0.05)))))
      (map
       (lambda (i)
         (let ((y0 (g-staff-y g (- 4 i))) (phase (g-rand rs 0 two-pi)))
           (list 'stroke
                 (map (lambda (k)
                        (let* ((u (* w (/ k n))) (a (env-at (assq-ref p 'amplitude) (g-q g u)))
                               (t (+ phase (/ (* two-pi u) wl))))
                          (cons (+ u (* curl a (cos t))) (+ y0 (* a (sin t))))))
                      (iota (1+ n)))
                 (assq-ref p 'thickness))))
       (iota (assq-ref p 'lines))))))
