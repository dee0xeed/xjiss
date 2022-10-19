# Just Intonation Synthesizer

`xjiss` is a software synthesizer written for Linux in Zig programming language.
It is written as

* experiment with just intonation (music)
* event driven state machines demo (programming)

## How to build

* make sure you have `libasound2-dev` and `libx11-dev` installed
* `zig build`

## Tone system

```
1     2    3    4    5     6    7    8     9    0    -    =    \
D+    R-   Mb   M+   F+    Lb   Sb   d+    r-   mb   m+   f+   do
36:17 20:9 12:5 18:7 45:16 16:5 18/5 72:17 40:9 24:5 36:7 45:8 8:1

q     w    e    r    t     y    u    i     o    p    [    ]
Do    Re   Mi   Fa   So    La   Si   do    re   mi   fa   so
2:1   9:4  5:2  8:3  3:1   10:3 15:4 4:1   9:2  5:1  16:3 6:1

a     s    d    f    g     h    j    k     l    ;    '
D+    RE-  Mb   M+   F+    Lb   Sb   D+    R-   Mb   M+
18:17 10:9 6:5  9:7  45:32 8:5  9:5  36:17 20:9 12:5 18:7

z     x    c    v    b     n    m    ,     .    /
DO    RE   MI   FA   SO    LA   SI   Do    Re   Mi
1:1   9:8  5:4  4:3  3:2   5:3  15:8 2:1   9:4  5:2

Legend

  b - key on the keyboard
 SO - note/pitch (G in western notation in this case)
3:2 - frequency ratio (pure/just fifth in this case)
```

## Controls

* Esc - exit
* F1 - decrease volume
* F2 - increase volume
* F3 - adjust timbre
* F4 - adjust timbre
* F5 - decrease attack
* F6 - increase attack
* F7 - decrease release
* F8 - increase release
* Space - toggle octaves
