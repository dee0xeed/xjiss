# Just Intonation Synthesizer

![xjiss-picture](https://repository-images.githubusercontent.com/553664893/79559718-09db-4c89-b7c6-e80121ddf164)

`xjiss` is a software synthesizer written for Linux in Zig programming language.
It was written as

* experiment with just intonation (music)
* event driven state machines demo (programming)

## How to build

* make sure you have `libasound2-dev` and `libx11-dev` installed
* `zig build`

## How to run

### Server mode

`xjiss s <port>`

### Client mode

`xjiss c <host> <port>`

## Controls

* Esc - exit

### Server mode only
* F1 - decrease volume
* F2 - increase volume
* F3 - adjust timbre
* F4 - adjust timbre
* F5 - decrease attack
* F6 - increase attack
* F7 - decrease release
* F8 - increase release
* Space - toggle octaves

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
 SO - note/pitch (G in usual notation for this case)
3:2 - frequency ratio (pure/just fifth for this case)
```

## Trouble shooting

### No sound (or `pcmOpen()` fails)

By default `xjiss` uses `/dev/snd/pcmC0D0p` playback device, which might not present
on some particular system. In this case do the following

* Find out which playback devices you have:

```
$ ls -l /dev/snd | grep p$
crw-rw----+ 1 root audio 116,  3 Nov 30 20:08 pcmC0D3p
crw-rw----+ 1 root audio 116,  6 Nov 30 20:21 pcmC1D0p
```

* Run `xjiss` with environment variable `XJIS_PLAYBACK_DEVICE` set:

```
XJIS_PLAYBACK_DEVICE="plughw:0,3" xjiss s 3333
XJIS_PLAYBACK_DEVICE="plughw:1,0" xjiss s 3333
```

`plughw:0,3` corresponds to `pcmC0D3p`, `plughw:1,0` to `pcmC1D0p` and so on.

## Links

* [Introduction to Sound Programming with ALSA](https://www.linuxjournal.com/article/6735)
* [A Close Look at ALSA](https://www.volkerschatz.com/noise/alsa.html)
* [Just Tuning](https://www.sfu.ca/sonic-studio-webdav/handbook/Just_Tuning.html)
* [X Window System Basics](https://magcius.github.io/xplain/article/x-basics.html)
* [Learning to Use X11](https://www.linuxjournal.com/article/4879)
