A single source file is used for all 6502-based machines.

# SELECT THE TARGET MACHINE

Open the ```mandelbr8.asm``` file. At the beginning, you will find the following lines:

```asm
; Enable only the build you need (set to 1).
BUILD_C64   = 1 ; Commodore 64 (or C128 in C64 mode).
BUILD_C128  = 0 ; Commodore 128.
BUILD_TED   = 0 ; Commodore TED machines: Plus/4 and C16 with 64 KB.
BUILD_VIC20 = 0 ; Commodore VIC-20 (16 KB required).
BUILD_PET   = 0 ; Commodore PET (8 KB required).
BUILD_B128  = 0 ; Commodore B128 (CBM 610).
BUILD_ATARI = 0 ; Atari XL/XE (GTIA required).
BUILD_BEEB  = 0 ; BBC Micro B (32 KB required).
```

Enable **only** one build at a time.

Optional flags below the target list (all default-on except where
noted):

```asm
BUILD_LUMA_PALETTE         = 1   ; Luma-ordered palette (smoother gradient)
BUILD_MARIANI_SILVER_STRIPE = 1  ; 40-pixel stripe MS (C64 only)
BUILD_HIRES_CONTOUR        = 0   ; 320x200 monochrome contour mode (C64 only)
BUILD_PERIODICITY          = 0   ; Periodic-orbit detection (off by default)
BUILD_BENCHMARK            = 0   ; Render-time measurement
```

# BUILD THE BINARY

### Commodore machines:

Build with TASS:

```64tass -o "mandelbr8.prg" -L "mandelbr8.lst" -a "mandelbr8.asm"```

### Atari machines:

Build with TASS:

```64tass --output-exec=main --atari-xex -o "mandelbr8.xex" -L "mandelbr8.lst" -a "mandelbr8.asm"```

### BBC Micro B:

Build with TASS:

```64tass -b -o "mandelbr8.ssd" -L "mandelbr8.lst" -a "mandelbr8.asm"```

This will create a minimalistic bootable SSD file.

# LOAD AND RUN

### Commodore machines:
```
LOAD"mandelbr8",8,1
RUN
```

### Atari machines:
Run the XEX file.


### BBC Micro:
Autoboot the floppy disk image.


# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

Please add a link to this github project.

# THIRD-PARTY CODE

This program uses the ```smult16.a``` fast 6502 multiplication algorithm from:
https://github.com/TobyLobster/multiply_test

