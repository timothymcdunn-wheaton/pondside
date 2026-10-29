# staff-ripple

The staff lines turning curly: each line becomes a trochoid whose loop size
follows `amplitude` over the span. At amplitude 0 it is the plain line, so a
`swell` grows ripples out of the staff and back. Generalized from the
ripples of bars 1–2.

- Hide the real staff lines under it (`\stopStaff` / `\startStaff`), or the
  ripples sit on top of them.
- `curl` 0 gives waves, 1 loops; `wavelength` sets how many loops fit.
