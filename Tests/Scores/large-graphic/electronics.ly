% Migrated from Dorico's MusicXML by build.py; edited by hand from here on
% Electronics: the pitch collections (\startGroup ... \stopGroup, numbered as ~ec)
% the cues and the effect names. Needs defs.ily (\ecue, \edesc).

electronics = {
  \clef treble
  % ec 0: C D E G A
  \collection { c'4 d'4 e'4 g'4 a'4 } s4*49 |
  % 2
  s4*2 |
  % 3
  s4*8 |
  % 4
  s4*2 % ec 1: C D E F# A
  \collection { c'32 d'32 e'32 fis'32 a'32 } s4*35/8 |
  % 5
  % ec 2: D E F# A B
  \collection { d'4*2/5 e'4*2/5 fis'4*2/5 a'4*2/5 b'4*2/5 } s4*2 % ec 3: F# Ab Bb C# Eb
  \collection { fis'32 gis'32 ais'32 cis''32 dis''32 } s4*19/8 |
  % 6
  s4*2 % ec 4: E F# Ab Bb C#
  \collection { e'8 fis'8 gis'16 ais'16 cis''16 } s4*1/4 % ec 5: E F# Ab B C#
  \collection { e'32 fis'32 gis'32 b'32 cis''32 } s4*11/8 |
  % 7
  s4*2 % ec 6: Ab Bb C Eb F
  \collection { aes'32 bes'32 c''32 ees''32 f''32 } s4*3/8 % ec 7: F# Ab Bb C Eb
  \collection { ges'32 aes'32 bes'32 c''32 ees''32 } s4*3/8 % ec 8: F# Ab Bb C# Eb
  \collection { ges'32 aes'32 bes'32 des''32 ees''32 } s4*19/8 |
  % 8
  s4*2 % ec 9: C D E G A
  \collection { c'32 d'32 e'32 g'32 a'32 } s4*35/8 |
  % 9
  s4*4 % ec 10: C D E F# A
  \collection { c'32 d'32 e'32 fis'32 a'32 } s4*19/8 |
  % 10
  % ec 11: D E F# A B
  \collection { d'32 e'32 fis'32 a'32 b'32 } s4*51/8 |
  % 11
  % ec 12: C# E F# Ab B
  \collection { cis'8 e'8 fis'8 gis'8 b'8 } s4*9/2 |
  % 12
  % ec 13: C Eb F Ab Bb
  \collection { c'16 ees'16 f'16 aes'16 bes'16 } s4*7/4 |
  % 13
  % ec 14: C# E F Ab B
  \collection { cis'8 e'8 f'8 gis'8 b'8 } s4*9/2 |
  % 14
  % ec 15: C Eb F Ab A
  \collection { c'16 ees'16 f'16 gis'16 a'16 } s4*7/4 |
  % 15
  % ec 16: D E F Ab B
  \collection { d'16 e'16 f'16 gis'16 b'16 } s4*11/4 % ec 17: D E F G B
  \collection { d'16 e'16 f'16 g'16 b'16 } s4*23/4 |
  % 16
  % ec 18: C E F Ab A
  \collection { c'16 e'16 f'16 gis'16 a'16 } s4*7/4 |
  % 17
  % ec 19: E F Ab A B
  \collection { e'16 f'16 gis'16 a'16 b'16 } s4*7/4 |
  % 18
  s4*4 % ec 20: E F Ab A Bb
  \collection { e'16 f'16 gis'16 a'16 bes'16 } s4*7/4 |
  % 19
  % ec 21: C D E F G
  \collection { c'16 d'16 e'16 f'16 g'16 } s4*23/4 |
  % 20
  % ec 22: C Eb E F G
  \collection { c'16 dis'16 e'16 f'16 g'16 } s4*7/4 % ec 23: C Eb E F# G
  \collection { c'16 dis'16 e'16 fis'16 g'16 } % ec 24: C D E F# G
  \collection { c'16 d'16 e'16 fis'16 g'16 } s4*1/2 % ec 25: C D E F# Ab
  \collection { c'16 d'16 e'16 fis'16 gis'16 } s4*1/2 % ec 26: D E F# Ab B
  \collection { d'16 e'16 fis'16 gis'16 b'16 } % ec 27: C# E F# Ab B
  \collection { cis'16*4/5 e'16*4/5 fis'16*4/5 gis'16*4/5 b'16*4/5 } s4*2 |
  % 21
  % ec 28: C Eb F Ab Bb
  \collection { c'16*4/5 ees'16*4/5 f'16*4/5 aes'16*4/5 bes'16*4/5 } s4*6 % ec 29: C# Eb F# Ab Bb
  \collection { cis'16 ees'16 fis'16 gis'16 bes'16 } s4*23/4 |
  % 22
  s4*42 |
  % 23
  % ec 30: C Eb F Ab Bb
  \collection { c'16 ees'16 f'16 aes'16 bes'16 } s4*7/4 |
  % 24
  % ec 31: C# E G Ab B
  \collection { cis'8 e'8 g'8 aes'8 b'8 } s4*9/2 |
  % 25
  % ec 32: C Eb F Ab B
  \collection { c'16 ees'16 f'16 gis'16 b'16 } s4*7/4 |
  % 26
  % ec 33: C C# E G Ab
  \collection { c'16 des'16 e'16 g'16 aes'16 } s4*11/4 % ec 34: C C# Eb G Ab
  \collection { c'16 des'16 ees'16 g'16 aes'16 } s4*3/4 % ec 35: C C# Eb F# G
  \collection { c'16*4/5 cis'16*4/5 dis'16*4/5 fis'16*4/5 g'16*4/5 } s4 % ec 36: C D Eb F# G
  \collection { c'16 d'16 dis'16 fis'16 g'16 } s4*7/4 |
  % 27
  % ec 37: C E F Ab B
  \collection { c'16 e'16 f'16 gis'16 b'16 } s4*7/4 |
  % 28
  % ec 38: C E F Ab A
  \collection { c'16 e'16 f'16 gis'16 a'16 } s4*3/4 % ec 39: E F Ab A B
  \collection { e'16 f'16 gis'16 a'16 b'16 } s4*3/4 |
  % 29
  % ec 40: F F# Ab A B
  \collection { f'16*4/5 fis'16*4/5 gis'16*4/5 a'16*4/5 b'16*4/5 } s4*2 |
  % 30
  % ec 41: E F# Ab A B
  \collection { e'16*4/5 fis'16*4/5 gis'16*4/5 a'16*4/5 b'16*4/5 } % ec 42: E F# Ab Bb B
  \collection { e'16*4/5 fis'16*4/5 gis'16*4/5 ais'16*4/5 b'16*4/5 } % ec 43: Eb F# Ab Bb B
  \collection { dis'16*4/5 fis'16*4/5 gis'16*4/5 ais'16*4/5 b'16*4/5 } % ec 44: C Eb F# Ab Bb
  \collection { c'16*4/5 ees'16*4/5 ges'16*4/5 aes'16*4/5 bes'16*4/5 } % ec 45: C Eb F Ab Bb
  \collection { c'16*4/5 ees'16*4/5 f'16*4/5 aes'16*4/5 bes'16*4/5 } s4*2 |
  % 31
  % ec 46: C D E F# G
  \collection { c'16*4/5 d'16*4/5 e'16*4/5 fis'16*4/5 g'16*4/5 } % ec 47: D E F# G B
  \collection { d'16*4/5 e'16*4/5 fis'16*4/5 g'16*4/5 b'16*4/5 } % ec 48: D E G Ab B
  \collection { d'16*4/5 e'16*4/5 g'16*4/5 gis'16*4/5 b'16*4/5 } % ec 49: D E F# Ab B
  \collection { d'16*4/5 e'16*4/5 fis'16*4/5 gis'16*4/5 b'16*4/5 } % ec 50: C# E F# Ab B
  \collection { cis'16*4/5 e'16*4/5 fis'16*4/5 gis'16*4/5 b'16*4/5 } s4*2 |
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

electronicsBass = {
  \clef bass
  s4*54 | % 1
  s4*2 | % 2
  s4*8 | % 3
  s4*7 | % 4
  \hideStaff \omit Staff.Clef s4*7 | % 5      (no staff lines until cue 6)
  s4*6 | % 6
  s4*5/4 \showStaff s4*1/4 \undo \omit Staff.Clef   % lines a little before the clef
  \once \set Staff.forceClef = ##t \clef bass
  r4*1/4 \hideStaff r4*21/4 | % 7    (hidden rests keep the staff; its lines are drawn from here)
  R4*7 | % 8
  R4*7 | % 9
  R4*7 | % 10
  R4*7 | % 11      (to bar 31 its lines are drawn: \startLowSwell)
  R4*3 | % 12
  R4*7 | % 13
  R4*3 | % 14
  R4*11 | % 15
  R4*3 | % 16
  R4*3 | % 17
  R4*7 | % 18
  R4*7 | % 19
  R4*12 | % 20
  R4*14 | % 21
  R4*42 | % 22
  R4*3 | % 23
  R4*7 | % 24
  R4*3 | % 25
  R4*11 | % 26
  R4*3 | % 27
  R4*4 | % 28
  R4*3 | % 29
  R4*7 | % 30
  R4*7 | % 31
  \showStaff R4*7 | % 32
  R4*7 | % 33
  R4*7 | % 34
  R4*7 | % 35
  R4*7 | % 36
  R4*7 | % 37
  R4*7 | % 38
  R4*7 | % 39
  R4*7 | % 40
  R4*7 | % 41
  R4*7 | % 42
  R4 | % 43
  R4*10 | % 44
}

electronicsCues = {
  s4*0\ecue "1" \edesc "ripples" s4*38 s4*0\edesc "reverse tongue rams" s4*16 |
  % 2
  s4*2 |
  % 3
  s4*0\ecue "2" \edesc "ocean, shimmer" s4*8 |
  % 4
  s4*2 s4*0\ecue "3" \edesc "swells" s4*5 |
  % 5
  s4*2 s4*0\ecue "4" s4*5 |
  % 6
  s4*3/2 s4*0\ecue "5" s4*9/2 |
  % 7
  s4*3/2 s4*0\ecue "6" \edesc "low swells" s4*11/2 |
  % 8
  s4*3/2 s4*0\ecue "7" \edesc "decimation" s4*11/2 |
  % 9
  s4*2 s4*0\ecue "8" s4*5 |
  % 10
  s4*13/2 s4*0\ecueToCaesura "9" s4*1/2 |   % (in the caesura's pause)
  % 11
  s4*11/2 s4*0\ecue "10" \edesc "echo burst" s4*3/2 |
  % 12
  s4*2 s4*0\ecue "11" s4 |
  % 13
  s4*11/2 s4*0\ecue "12" \edesc "tongue rams, granulator" s4*3/2 |
  % 14
  s4*2 s4*0\ecue "13" s4 |
  % 15
  s4*10 s4*0\ecue "14" s4 |
  % 16
  s4*2 s4*0\ecue "15" s4 |
  % 17
  s4*2 s4*0\ecue "16" s4 |
  % 18
  s4*6 s4*0\ecue "17" s4 |
  % 19
  s4*7 |
  % 20
  s4*0\ecue "18" \edesc "slap tongue" s4*11/2 s4*0\ecue "19" \edesc "thinning, wind tones" s4*13/2 |
  % 21
  s4*0\ecue "20" s4*7 s4*0\ecue "21" s4*7 |
  % 22
  s4*0\ecue "22" \edesc "random swells, freeze" s4*42 |
  % 23
  s4*0\ecue "23" \edesc "granulator" s4*2 s4*0\ecue "24" s4 |
  % 24
  s4*11/2 s4*0\ecue "25" s4*3/2 |
  % 25
  s4*2 s4*0\ecue "26" s4 |
  % 26
  s4*10 s4*0\ecue "27" s4 |
  % 27
  s4*3 |
  % 28
  s4*0\ecue "28" s4*4 |
  % 29
  s4*3 |
  % 30
  s4*0\ecue "29" s4*7 |
  % 31
  s4*0\ecue "30" s4*7 |
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

% The graphic notation (graphics.ily), bars 1-4; the staff lines stop where the ripples begin
% (they turn into them) and return at cue 3's pentachord.
electronicsGraphics = {
  s4*5 \hideStaff s4*49 \startRipples | % 1
  s4*15/8 s4*1/8 \stopGraphic | % 2    (to just before the barline: fading out behind the arc)
  s4*8 \startWedges | % 3
  s4*2 \stopGraphic \startGrains s4*5 \stopGraphic \startSwell | % 4
  s4*7 \stopGraphic \startSwells | % 5
  s4*6 | % 6
  s4*7 | % 7
  s4*7 | % 8
  s4*7 | % 9
  s4*55/8 s4*1/8 \stopGraphic | % 10   (ends just before the system's end)
  s4*7 \startTexture s4*153 | % 11-30   (cues 9-30, at the patch's real times)
  s4*55/8 s4*1/8 \stopGraphic | % 31
  \showStaff s4*0   % the staff lines back from bar 32
}
% the bass staff: only from cue 6 (pb5's low swells) in its first system
electronicsLowGraphics = {
  s4*71 | % 1-4
  s4*13 | % 5-6
  s4*3/2 s4*11/2 \startLowSwell | % 7
  s4*7 | % 8
  s4*7 | % 9
  s4*7 | % 10
  s4*160 | % 11-30
  s4*55/8 s4*1/8 \stopGraphic | % 31
}
electronicsArc = {
  s4*54 | % 1
  s4*2 \startArc | % 2
  s4*8 | % 3
  s4*0 \stopGraphic
}

% staff lines under each collection where the staff is hidden (bars 4-10)
electronicsFanStaff = {
  s4*64 | % 1-3
  s4*7 \startFanStaff | % 4
  s4*7 | s4*6 | s4*7 | s4*7 | s4*7 | % 5-9
  s4*7 | % 10
  s4*160 | % 11-30
  s4*55/8 s4*1/8 \stopGraphic | % 31
}

% echo bursts (cues 10, 12, 14, 23, 25), behind the grains
electronicsBursts = {
  s4*112 | % 1-10
  s4*7 \startBursts s4*153 | % 11-30
  s4*55/8 s4*1/8 \stopGraphic | % 31
}
