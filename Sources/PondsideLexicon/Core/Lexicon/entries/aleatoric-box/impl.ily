% aleatoric-box: a rectangle around the span (open at line breaks), with a label.
#(define-graphic! "aleatoric-box"
  (lambda (g p)
    (let* ((w (g-width g)) (pad (assq-ref p 'padding))
           ; a span stops at its last note's left side: reach past that note's head
           (u0 (- pad)) (u1 (+ w pad 1.3))
           (t (assq-ref p 'top)) (b (assq-ref p 'bottom)) (th (assq-ref p 'thickness))
           (label (assq-ref p 'label))
           (box (list (list 'stroke (list (cons u0 b) (cons u0 t) (cons u1 t) (cons u1 b) (cons u0 b)) th))))
      (if (and (string? label) (not (string-null? label)))
          (cons (list 'text u0 (+ t 0.6) (markup #:italic label)) box)
          box))))
