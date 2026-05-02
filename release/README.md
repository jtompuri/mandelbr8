# Binaries

Pick the binary for your target machine:

| File                            | Machine                                              |
|---------------------------------|------------------------------------------------------|
| `mandelbr8-c64.prg`             | Commodore 64 multicolor (160×200, 16 colors)         |
| `mandelbr8-c64-contour.prg`     | Commodore 64 monochrome contour (320×200)            |
| `mandelbr8-c128.prg`            | Commodore 128 (40-col VIC-IIe or 80-col VDC)         |
| `mandelbr8-ted.prg`             | Plus/4 or C16 (64 KB required)                       |
| `mandelbr8-vic20.prg`           | VIC-20 (16 KB memory expansion required)             |
| `mandelbr8-cbm2.prg`            | CBM-II (6xx / 7xx, including B128)                   |
| `mandelbr8-pet.prg`             | PET (8 KB+)                                          |
| `mandelbr8-atari.xex`           | Atari XL/XE (64 KB required)                         |
| `mandelbr8-beeb.ssd`            | BBC Micro B (32 KB)                                  |

## C64: multicolor or contour

`mandelbr8-c64.prg` renders 160×200 in 16 colors using a per-cell color
histogram.

`mandelbr8-c64-contour.prg` renders 320×200 monochrome: each pixel is
`iter & 1` (even = black, odd = dark green), so each iter step is a
contour band. Default `max_iter = 32`.

Both use the 40-pixel stripe Mariani-Silver renderer for 27–33 %
faster rendering.

## Controls

One press, one action (edge-triggered).

| Input               | Effect                                       |
|---------------------|----------------------------------------------|
| Direction (no fire) | Pan view (~4 % per press)                    |
| Fire + Up           | Zoom in (~8 % per press)                     |
| Fire + Down         | Zoom out                                     |
| Fire + Right        | Increment max iterations (cap 255)           |
| Fire + Left         | Decrement max iterations (floor 2)           |

Joystick port:

| Target          | Port                              |
|-----------------|-----------------------------------|
| C64 / C128      | 2                                 |
| Plus/4 / C16    | 1                                 |
| VIC-20          | 1                                 |
| Atari XL/XE     | 1                                 |
| PET / CBM-II    | WASD + SHIFT (keyboard)           |
| BBC Micro       | Analog port 1 or cursor keys      |

See the project README for full details.

## VICE warp mode

In the VICE emulator, turn on warp mode while waiting for renders.
Shortcut: Alt+W (macOS) or Page Up (Windows / Linux).

## License

Creative Commons Attribution 4.0 International (CC BY 4.0).

<https://creativecommons.org/licenses/by/4.0/>

Fork of `mandelbr8` by GitHub user `0x444454`. See the project README
for full attribution.
