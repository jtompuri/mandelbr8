; Mandelbr8 (6502 version).
; DDT's fixed-point Mandelbrot 8-bit generator.
;
; https://github.com/0x444454/mandelbr8
;
; Use 64TASS Assembler.
;
; Revision history [authors in square brackets]:
;   2024-11-07: First simple test loop. [DDT]
;   2024-11-08: Unoptimized C64 version. [DDT]
;   2024-11-09: Added support for C128 and 80x50 VDC mode. [DDT]
;   2024-11-10: Added Q5.9 squares table for speedup. [DDT]
;   2024-11-12: VIC-II Kawari: Support HW multiplier. [DDT]
;   2024-11-13: Support Commodore Plus/4. [DDT]
;   2024-11-15: Support C64 multicolor bitmap (second-pass). [DDT]
;   2024-11-16: Multicolor histogram optimized rendering. [DDT]
;   2024-11-17: Added C64 tile-skip heuristics. [DDT]
;   2024-11-18: Support TED multicolor bitmap (second-pass). [DDT]
;   2024-11-20: Support Kawari custom palette. [DDT]
;   2024-11-23: Support Atari XL/XE. [DDT]
;   2024-11-27: Studied BBC Micro system arch. [DDT]
;   2024-11-28: Support BBC Micro. [DDT]
;   2024-12-02: Minor bugs fixed. [DDT]
;   2024-12-06: Support VIC-20. [DDT]
;   2024-12-17: Studied Commodore PET system arch. [DDT]
;   2024-12-18: Support Commodore PET (mono and color). [DDT]
;   2025-02-13: Changed format to Q5.11 for increased zoom range. Fixed comments. [DDT]
;   2025-02-15: Added support for C128 VDC 160x100 (64KB VDC VRAM required). [DDT]
;   2025-02-24: Studying CBM2 machines and 6509 CPU to support B128. [DDT]
;   2025-02-25: Support for B128. [DDT]
;   2026-05-01: 320x200 monochrome contour mode for C64 (BUILD_HIRES_CONTOUR). [jtompuri]
;   2026-05-02: 40-pixel stripe Mariani-Silver for C64 (multicolor -27 %, contour -33 %). [jtompuri]
;   2026-05-02: Edge-triggered input (one press = one action, warp-safe). [jtompuri]
;   2026-05-02: Pan/zoom UX (~4 % pan, ~8 % zoom); recenter math fix. [jtompuri]
;   2026-05-02: Vertical-centring fix for C64 multicolor + contour and C128 (VIC-IIe + VDC). [jtompuri]
;   2026-05-02: C128 VDC clear-screen black (was bright white). [jtompuri]
;   2026-05-02: Default max_iter = 32 for contour mode. [jtompuri]
;   2026-05-02: TED uniform-luma palette (TED_HI_LUMA, default 4). [jtompuri]
;   2026-05-02: VIC-20 4-color palette reordered for luma-ordered gradient. [jtompuri]


; Enable *only* the build you need (set to 1).
BUILD_C64   = 1 ; Commodore 64 (or C128 in C64 mode).
BUILD_C128  = 0 ; Commodore 128.
BUILD_TED   = 0 ; Commodore TED machines: Plus/4 and C16 with 64 KB.
BUILD_VIC20 = 0 ; Commodore VIC-20 (16 KB required).
BUILD_PET   = 0 ; Commodore PET (8 KB required).
BUILD_B128  = 0 ; Commodore B128 (CBM 610).
BUILD_ATARI = 0 ; Atari XL/XE (GTIA required).
BUILD_BEEB  = 0 ; BBC Micro B (32 KB required).

;==============================================================================
; C64 MEMORY LAYOUT (single source of truth — keep in sync with code below)
;==============================================================================
; Each named region below has a BASE and an END address. Code that's placed
; at one of these regions (via `* = MEM_x_BASE`) MUST be followed by a
; `.cerror * > MEM_x_END+1, "..."` bounds check. The assembler will then
; refuse to build if any region overflows, preventing silent corruption.
;
; Layout                Range           Size  Purpose
; -------------------   -------------   ----  --------
; (BASIC stub)          $0801-$0BD2     978   Auto-generated SYS xxxx loader
; CARDIOID region       $0C00-$0CFF     256   test_cardioid routine
; STRIPEMS region       $0D00-$1DFF    4352   stripe-wise MS code+tables
; BENCH region          $1E00-$1FFF     512   bench routines + tables (legacy name MIRRORBENCH)
; (VIC-II bitmap)       $2000-$3F3F    8000   Cleared at hi-res init — DO NOT place code here
; (gap)                 $3F40-$3FFF     192   Inside bitmap area, also cleared
; (Mandelbrot main)     $4000-$46FF    1792   Main calculation; runtime check at line ~4894
; (smult12 tables+code) $4700-$4FA0     673   Multiplication routines; explicit `* =` in source
; (gap)                 $4FA1-$4FFF      95   Free
; (Squares table)       $5000-$CFFF   32768   Built at runtime — DO NOT place code here
; (Iter buffers)        $E000-$EFFF    4096   Lo-res / hi-res iter buffers
;
; INVARIANTS:
; - Anything added to CARDIOID or BENCH must fit in its region.
;   If you grow a region's content, also bump its END constant.
; - Code at $2000-$3FFF is wiped by `clear_bitmap`. Don't put code there.
; - Code at $5000-$CFFF is overwritten by `init_squares_q4_10`. Don't either.
; - Mandelbrot main section ($4000-$46FF) has its own overflow check;
;   if you add inline code there, watch the output for "Assembled code
;   overrun over mult tab".

; Always defined (purely symbolic; no code emitted).
MEM_CARDIOID_BASE    = $0C00
MEM_CARDIOID_END     = $0CFF       ; 256 bytes max (cardioid is ~159 bytes)
MEM_STRIPEMS_BASE    = $0D00
MEM_STRIPEMS_END     = $1DFF       ; 4352 bytes max (stripe MS code+tables)
MEM_MIRRORBENCH_BASE = $1E00       ; Legacy name retained — historically held mirror_tile too.
MEM_MIRRORBENCH_END  = $1FFF       ; 512 bytes max (bench routines + tables, ~50 bytes used).


; ---- Benchmark option ----
; Set BUILD_BENCHMARK = 1 to enable rendering time measurement.
; - Border flashes white at render start, red when rendering finishes.
; - On C64/C128: stores CIA1 Timer B underflow count, configured to count
;   Timer A underflows (~50/60 Hz frame rate). 16-bit value at bench_tb_l/h
;   tells how many KERNAL "frames" elapsed during the render.
;   Elapsed seconds ≈ (frames / 50) on PAL or (frames / 60) on NTSC.
;   This is independent of the (sometimes broken) CIA1 TOD chip in VICE.
; - Also stores CIA1 TOD timestamps (BCD) for completeness, but TOD
;   is unreliable in some VICE configurations.
; - On other platforms: benchmark stubs are no-ops (border flash only on C64/C128).
BUILD_BENCHMARK = 0

; ---- Optimization option: luma-ordered palette ----
; Set BUILD_LUMA_PALETTE = 1 to remap iter to color via a 16-byte lookup table
; that orders the palette by luminance (dark to bright).
; - On color: iter rings form a smooth dark-to-bright gradient.
; - On grayscale (B&W TV, desaturated screenshot): a smooth monochromatic
;   gradient.
; - Cost: ~5 cycles per pixel (TAX + table LDA) and 16 bytes of data.
; - No effect on histogram or other optimizations.
; Set to 0 for the raw-iter rainbow ordering.
BUILD_LUMA_PALETTE = 1

; ---- Optimization option: periodicity detection ----
; Set BUILD_PERIODICITY = 1 to enable periodic-orbit detection in the
; iteration loop. After 4 iterations, the current (zx, zy) is snapshotted;
; subsequent iterations compare against the snapshot. If a match is found
; (exact 4-byte equality in Q5.11), the orbit is periodic → point is in
; the set, and we exit early to found_color_black.
;
; - Complements cardioid + bulb tests (which catch period-1 and period-2
;   only). Periodicity catches higher-period mini-Mandelbrots and points
;   inside disconnected components that fall through the analytical tests.
; - Inline cost: 11 bytes (LDA iter / CMP #4 / BCC / JSR / BEQ).
;   Per-iter cost ~6 cycles when iter < 4 (skipped early), ~50 cycles
;   when iter >= 4 (JSR + 4-byte CMP chain). Typical workload sees
;   most outside points reject before iter=4, so overhead is small.
; - Routine + 4-byte storage placed in BENCH region ($1E00-$1FFF).
;   Currently C64-only; other targets need separate placement.
; - Default OFF: measured at default-zoom view as a +3% regression because
;   cardioid+bulb already cover most interior pixels and the few remaining
;   mini-Mandelbrot interior points don't pay back the per-iter overhead.
;   Enable to test on zoomed-in views with visible mini-Mandelbrots, where
;   savings can reach 20-40%.
BUILD_PERIODICITY = 0

; ---- Optimization option: stripe-wise Mariani-Silver ----
; Set BUILD_MARIANI_SILVER_STRIPE = 1 to enable stripe-wise MS rendering.
; A stripe is 40x8 pixels: 10 multicolor cells (4 px each) or 5 contour
; tiles (8 px each). ms_render_stripe_c40 builds one stripe via border
; tracing (40+40+6+6 = 92 samples) then recursive subdivision and
; brute-force fill. Cells/tiles are extracted into buf_iters_hr so
; existing per-tile rendering runs unchanged.
;
; - C64-only (stripe iter buffer at $E900-$F0FF, code in the STRIPEMS
;   region $0D00-$1DFF).
; - nxt_tile maintains stripe_idx (0..9 multicolor / 0..4 contour); the
;   first tile of each stripe (idx==0) triggers ms_render_stripe_c40,
;   the rest extract cells from the buffer.
; - Default view, C64 PAL: multicolor 102 s (-27 %), contour 175 s
;   (-33 %), vs. row-major rendering. Brute-force threshold #5.
BUILD_MARIANI_SILVER_STRIPE = 1

.if BUILD_MARIANI_SILVER_STRIPE & !BUILD_C64
    .error "BUILD_MARIANI_SILVER_STRIPE is C64-only for now."
.endif

; ---- Render option: 320x200 hi-res contour mode (C64 only) ----
; Set BUILD_HIRES_CONTOUR = 1 for a monochrome hi-res (320x200) render mode.
; Each pixel is iter & 1: even iter → background (black), odd iter →
; foreground (dark green). Alternating iter bands form contour rings.
; Screen RAM is pre-filled with $50 (dark green fg, black bg) at hi-res init.
;
; - Requires BUILD_LUMA_PALETTE = 1.
; - Eliminates histogram build + scan; pixel conversion is a single AND #$01.
BUILD_HIRES_CONTOUR = 0
.if BUILD_HIRES_CONTOUR & !BUILD_C64
    .error "BUILD_HIRES_CONTOUR is C64-only."
.endif
.if BUILD_HIRES_CONTOUR & !BUILD_LUMA_PALETTE
    .error "BUILD_HIRES_CONTOUR requires BUILD_LUMA_PALETTE = 1."
.endif

CHECK_BUILD = BUILD_C64 + BUILD_C128 + BUILD_TED + BUILD_VIC20 + BUILD_PET + BUILD_B128 + BUILD_ATARI + BUILD_BEEB
.if CHECK_BUILD < 1 || CHECK_BUILD > 1
    .error "ENABLE ONE AND ONLY ONE BUILD."
.endif

; BEGIN: Commodore machines -----------------
.if BUILD_C64
  * = $0801   ; C64
.elif BUILD_C128
  * = $1C01   ; C128
.elif BUILD_TED
  * = $1001   ; TED machines (C16 and Plus/4)
.elif BUILD_VIC20
  * = $1201   ; VIC-20 (8+ KB)
.elif BUILD_PET
  * = $401    ; PET.
.elif BUILD_B128
  * = $03     ; B128
; END: Commodore machines -----------------
.elif BUILD_ATARI
  * = $1800   ; Atari XL/XE
.elif BUILD_BEEB
  LOAD_ADDRESS = $1800   ; BBC Micro
.endif
  
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_VIC20 | BUILD_PET | BUILD_B128
  .word end_BASIC
  .word 10

.if BUILD_B128
; POKE this in to change code exe bank:
;       LDA #$01
;       STA $00
    .text                             $97,$34,$31,$2C,$31,$36,$39,$3A,$97 ; POKE41,169:POKE
    .text $34,$32,$2C,$31,$3A,$97,$34,$33,$2C,$31,$33,$33,$3A,$97,$34,$34 ; 42,1:POKE43,133:POKE44
    .text $2c,$30,$3A                                                     ; ,0:
.endif

  .byte $9e ; SYS

  .if BUILD_C64  
    .text "2061", $00 ; C64
  .elif BUILD_C128
    .text "7181", $00 ; C128
  .elif BUILD_TED
    .text "4109", $00 ; TED
  .elif BUILD_VIC20
    .text "4621", $00 ; VIC-20
  .elif BUILD_PET
    .text "1037", $00 ; PET
  .elif BUILD_B128
    .text "41",   $00 ; B128
  .endif
end_BASIC:
  .word 0
.endif
; END: Commodore machines -----------------


; BEGIN: BBC Micro -----------------
.if BUILD_BEEB
        ; We generate a SSD file, i.e. a floppy disk containing this program.
        ;
        ; Create SSD disk header.
        ;
        * = LOAD_ADDRESS - $200 ;--------- SECTOR 0
        ;
        .text "mandelbr"   ; First 8 chars of disk title.
        ;    First file name and "Dir" attributes.
        .text "!boot  ", $24

        * = LOAD_ADDRESS - $100 ;--------- SECTOR 1
        .text "8   "    ; Last 4 chars of tisk title.
        .byte $07       ; Disk cycle, HDFS: Key number.
        .byte 1*8       ; (Number of catalog entries) * 8
        .byte %00100011 ; [7..6]: Must be zero.
                        ; [5..4]: !Boot option (*OPT 4 value). We use %10 to run machine code.
                        ; [3]: 0=DFS/WDFS, 1=HDFS
                        ; [2]: Total number of sectors [10]. If HDFS: (number of sides)-1
                        ; [1..0]: Total number of sectors [9..8].
        .byte ((END_ADDRESS - LOAD_ADDRESS)+255)/256 + 2 ; Total number of sectors [7..0].
        ;   First file properties.
        .byte <LOAD_ADDRESS, >LOAD_ADDRESS ; Load address [15..0].
        .byte <LOAD_ADDRESS, >LOAD_ADDRESS ; Exec address [15..0].
        .word END_ADDRESS - LOAD_ADDRESS   ; File length  [15..0].
        .byte %00000000 ; [7..6] Exec address [17..16].
                        ; [5..4] File length  [17..16].
                        ; [3..2] Load address [17..16].
                        ; [1..0] Start sector [9..8]
        .byte $02       ;        Start sector [7..0].

        * = LOAD_ADDRESS
.endif
; END: BBC Micro -----------------

        
main:
.if BUILD_B128
        ; 4 NOPs to align main code after poked-in bank switch.
        NOP
        NOP
        NOP
        NOP
        ; Disable interrupts.
        SEI
        ; Switch data to bank 1.
        LDA #1
        STA $01
        ; Get out of page 0 and page 1.
        JMP $0200
        * = $0200
.else
        ; Disable interrupts.
        SEI
.endif        

.if BUILD_BEEB
        LDA #MODE_BEEB
        STA mode
        
        ; Mute that nasty startup beep.
        LDA #$00
        JSR set_volumes

        ; Configure System VIA Port A to read keyboard.
        LDA #$0F
        STA $FE42
        LDA #$03
        STA $FE40
        
        ; Set ULA palette for mode 2.
        ; Write the logical color to the top four bits, and the physical color EOR 7 in the bottom four bits.
        LDX #0
-       TXA
        EOR #$07
        STA ula_tmp
        TXA
        ROL
        ROL
        ROL
        ROL
        ORA ula_tmp
        STA $FE21     ; Palette Control (%ccccfbgr).
        INX
        CPX #16
        BNE -

        ; Border color / 24-bit palette control:
        ;   %0000xbgr - border colour
        ;   %01xxxxxx - palette control
        ;   %1xxxxxxx - palette control
        LDA #%00000000  ; Black.
        STA $FE22  ; Border color.
        
        
        ; Set Mode 2 (BITMAP_START = $3000).
        LDA #12    ; Set C0=1
        STA $FE40  ; VIA Reg B
        LDA #13    ; Set C1=1
        STA $FE40  ; VIA Reg B
        
        ; Setup the 6845 (CRTC).
        LDX #0
-       STX $FE00
        LDA crtc_mode_2,X
        STA $FE01
        INX
        CPX #18
        BNE -

        ; Setup Video Control register. For whatever reason, this must be done after setting up the CRTC.
        LDA #$F4   ; Mode 2 with no cursor. NOTE: setting bits 5,6 and 7 to 0 will cause the cursor to vanish.
        STA $FE20  ; Video Control.

        
        ; Draw test bitmap pattern.
        LDX #$00
-       TXA
        ;LDA #$FF
        STA BITMAP_START,X
        INX
        BNE -

        JMP done_BEEB
        

ula_tmp:    .byte   0  

; 6845 (CRTC) settings.
crtc_mode_2:
    .byte   127 ; R0        Horizontal total. The total number of 'character time units' across the screen - 1 (including non-displayed characters).
    .byte    80 ; R1        Characters per line. 
    .byte    98 ; R2        Horizontal sync position. Changing this moves the screen left/right.
    .byte   $28 ; R3        Vertical sync width [7..4], Horizontal sync width [3..0]. NOTE: Not advisable to change since most TVs/monitors require the standard values.
    .byte    38 ; R4        Vertical total (char rows).
    .byte     0 ; R5        Vertical total adjust (scan lines).
    .byte    32 ; R6        Vertical displayed (char rows).
    .byte    34 ; R7        Vertical sync position (char rows).
    .byte   $00 ; R8        Cursor delay (chars) [7..6], Display delay (chars) [5..4], Interlace mode [1..0]: %00 or %10 = non interlaced; %01 = interlaced; %11 = interlace and video for MODE 7 support.
    .byte     7 ; R9        Scan lines per character - 1.
    .byte   $67 ; R10       Cursor blink [6], Blink rate [5], Cursor start (scan line) [4..0].
    .byte     8 ; R11       Cursor end (scan line).
    .byte >(BITMAP_START/8); R12       Screen start address / 8, HI.
    .byte <(BITMAP_START/8); R13       Screen start address / 8, LO.
    .byte   $00 ; R14       Cursor position, HI.
    .byte   $00 ; R15       Cursor position, LO.
    .byte     0 ; R16       Light pen position, HI.
    .byte     0 ; R17       Light pen position, HLO.

; Table to convert a color index [0..15] into a byte representing 2 pixels of the same color (Mode 2).
mode2_solid_colors:
    .byte %00000000, %00000011, %00001100, %00001111
    .byte %00110000, %00110011, %00111100, %00111111
    .byte %11000000, %11000011, %11001100, %11001111
    .byte %11110000, %11110011, %11111100, %11111111

; This is the current BBC Micro joystick poll axis.
beeb_joy_dir_axis:  .byte $00
beeb_joy_last_x:    .byte 128     ; [0..255]. Default to centered.
beeb_joy_last_y:    .byte 128     ; [0..255]. Default to centered.
  
; Set volume in A to sound chip.
set_volumes:
        EOR #$0F    ; SN76489 takes a negative volume level
        PHA
        ORA #$D0    ; command: set volume of Channel 2
        JSR snd_sound_cmd
        PLA
        PHA
        ORA #$90    ; command: set volume of Channel 0
        JSR snd_sound_cmd
        PLA
        ORA #$B0    ; command: set volume of Channel 1
        JSR snd_sound_cmd
        RTS  
  
; Send command in A to sound chip.  
snd_sound_cmd:  
        LDX #$FF
        STX $FE43  ; System VIA Port A: Set all lines as output.
        STA $FE4F  ; System VIA Port A: Output A (no handshake).
        INX        ; X=0 (Enable sound chip).
        STX $FE40  ; System VIA Port B, assert sound chip write strobe.
        NOP        ; Wait for sound chip to process command...
        NOP
        NOP
        NOP
        LDX #8     ; X=8 (Disable sound chip).
        STX $FE40  ; System VIA Port B, negate sound chip write strobe.
        RTS
    
done_BEEB:    
.endif ; BUILD_BEEB


        
.if BUILD_C128
        ; Configure C128 MMU. Kick ROM out of the way.
        LDA #$3E            ; All Bank0 RAM but keep I/O regs ($D000-$DFFF).
        STA $D500
.elif BUILD_ATARI
        ; Disable IRQs.
        ;LDA #$00
        ;STA $D20E           ; IRQEN
        ; Disable NMIs
        LDA #$00
        STA $D40E           ; NMIEN

        ; Copy charset ($E000–$E3FF) from ROM to RAM.
        LDX #0
-       LDA $E000,X
        STA $1000,X
        LDA $E100,X
        STA $1100,X
        LDA $E200,X
        STA $1200,X
        LDA $E300,X
        STA $1300,X
        INX
        BNE -
        
        ; Point to copied charset.
        LDA #$10
        STA $D409           ; CHBASE
        
        ; Now disable ROMs.
        LDA $D301           ; PORTB
        AND #%11111110      ; Clear bit 0 to disable OS ROM.
        ORA #%10000010      ; Set bits 1 to disable BASIC ROM. Set bit 7 ti disable Self-Test ROM.
        STA $D301
        ; All system ROMs disabled. We still have hw regs at $D000-D7FF.
        
        ; Replace NMI vector.
        LDA #<atari_NMI
        STA $FFFA
        LDA #>atari_NMI
        STA $FFFB
        ; Replace IRQ vector.
        LDA #<atari_IRQ
        STA $FFFE
        LDA #>atari_IRQ
        STA $FFFF

        ;LDA #$00            ; Clear Pokey SKCTL
        ;STA $D20F           ; SKCTL
        ;LDA #$03            ; Then Set to $03
        ;STA $D20F           ; SKCTL

        ; Disable ANTIC DMA
        LDA #$00            ; Disable display list DMA.
        STA $D400           ; DMACTL
        
        ; Copy new display list for text (lo-res).
        LDX #0
-       LDA atari_DL_text,X
        STA $1400,X
        INX
        CMP #$41            ; This is the jump.
        BNE -
        LDA #$00            ; Set jump address.
        STA $1400,X
        LDA #$14
        STA $1401,X
        
        ; Copy new display list for bitmap (hi-res).
        LDX #0
-       LDA atari_DL_bitmap,X
        STA $1500,X
        CMP #$0F            ; Do we need to expand the template ?
        BEQ +
        INX
        CMP #$41            ; Stop at the ANTIC jump (end), in case we don't find the expansion point.
        BNE -
        BEQ done_expansion  ; If we are here, we did not find the expansion point.
+       ; Expand template and complete display list.
        LDA #$0F
        LDY #99             ; Define 99 lines before we need a LMS to hop the 4 KB boundary.
exp_0:  STA $1500,X
        INX
        DEY
        BNE exp_0
        LDA #$4F             ; Line 100: Time for a LMS.
        STA $1500,X
        INX
        LDA #$00             ; Line 100 ptr LO
        STA $1500,X
        INX
        LDA #(>BITMAP_START)+$10 ; Line 100 ptr HI
        STA $1500,X
        INX
        LDA #$0F
        LDY #99             ; Other 99 lines for a total of 200.
exp_1:  STA $1500,X
        INX
        DEY
        BNE exp_1
done_expansion:
        LDA #$41            ; ANTIC Jump
        STA $1500,X
        LDA #$00            ; Set jump address.
        STA $1501,X
        LDA #$15
        STA $1502,X

        ; Set new display list for text (lo-res).
        LDA #$00            ; Low byte of display list address
        STA $D402           ; Store in DLISTL
        LDA #$14            ; High byte of display list address
        STA $D403           ; Store in DLISTH
        ; Enable ANTIC DMA
        LDA #$22            ; Enable display list DMA (and set normal playfield mode).
        STA $D400           ; DMACTL

        ; Enable NMIs
        LDA #$C0
        STA $D40E           ; NMIEN
        
        ; Enable IRQs
        ;LDA #$F7
        ;STA $D20E           ; IRQEN
        
        ; Set border color.
        LDA #$00
        STA COL_BORDER

.endif ; BUILD_ATARI


        ; Initialize unsigned mul tables. This is required also by "print_str", so do it now.
        JSR mulu_init 


.if BUILD_PET
        ; Detect PET 40 vs 80 columns now, before we print anything.
        LDX #40
        LDA $D5
        CMP #$4F
        BNE +
        LDX #80
+       STX cbm_columns
.endif


.if BUILD_B128
        LDA #80
        STA cbm_columns
.endif


.if !BUILD_BEEB
        ; Print intro message (first message printed must start with $93=CLS).
        LDA #<str_intro
        STA str_ptr
        LDA #>str_intro
        STA str_ptr+1
        JSR print_str
.endif        
      
        ; Check machine.

.if BUILD_C64
        ; Check for Kawari, trying to enable extended features.
        LDA #86 ; 'V'
        STA $D03F
        LDA #73 ; 'I'
        STA $D03F
        LDA #67 ; 'C'
        STA $D03F
        LDA #50 ; '2'
        STA $D03F
        LDA $D03F
        AND #$80
        BNE no_kawari
        LDA #MODE_KAWARI
        STA mode
        ; Print "Kawari found" message.
        LDA #<str_kawari
        STA str_ptr
        LDA #>str_kawari
        STA str_ptr+1
        JSR print_str
        ; Zero out IDX regs
        LDA #$00
        STA $D035            ; VIDEO_MEM_1_IDX
        STA $D036            ; VIDEO_MEM_2_IDX
        LDA #$21             ; Enable extra regs overlay, and auto-increment mem port 1 on write.
                             ; NOTE: Auto-increment does not seem to work.
        STA $D03F            ; VIDEO_MEM_FLAGS
        LDA #$00
        STA $D03A            ; VIDEO_MEM_1_HI
        ; Kawari allows us to define nice palette gradients.
        ;
        ; Setup DVI/VGA 
        ; DVI/VGA palette is a 16*4 array of RGBx (6 bits each, 4th byte unused).
        LDY #$40             ; Point to first PAL_RGB register.
        LDX #0
-       STY $D039            ; VIDEO_MEM_1_LO
        INY
        LDA kawari_palette_RGB,X ; This is 8 bit, so we convert it to 6 bits.
        LSR
        LSR
        STA $D03B            ; Write value to video mem 1 val (and auto-increment).
        INX
        CPX #16*4
        BNE -
        ;
        ; Setup LPA color palette, 16 bytes LUMA, 16 bytes PHASE, 16 bytes AMPL.
        LDY #$A0             ; Point to first LPA register.
        LDX #0
-       STY $D039            ; VIDEO_MEM_1_LO (update ptr as auto-increment does not seem to be working).
        INY
        LDA kawari_palette_LPA,X  ; No conversion needed.
        STA $D03B            ; Write value to video mem 1 val (and auto-increment).
        INX
        CPX #16*3
        BNE -        
        ; Set color of first 256 bytes of CRAM to make intro text visible after redefining palette.
        LDX #$00
        LDA #$09
-       STA COL_RAM,X
        INX
        BNE -

no_kawari:

        ; Just map RAM and I/O. We don't need no Kernal.
        LDA $01
        AND #$F8
        ORA #$05
        STA $01
.endif ;BUILD_C64
        

.if BUILD_C128
.if BUILD_LUMA_PALETTE
        ; Default luma table pointer → VIC-II palette. Overridden below
        ; if we end up in VDC (80-col) mode.
        LDA #<iter_to_color_luma
        STA luma_table_ptr
        LDA #>iter_to_color_luma
        STA luma_table_ptr+1
.endif
        ; Detect C128.
        LDA $D030
        AND #$02           ; Check VIC-IIe test bit (should be 0 on a C128).
        BNE no_C128        ; This is not a C128.

        ; Check for 80-col mode.
        LDA $D7
        AND #$80
        BEQ no_VDC

        ; We are using the VDC (8563 or 8568).
        LDA $D030          ; Enable 2 MHz mode.
        ORA #$01
        STA $D030
        LDA #MODE_VDC
        STA mode
.if BUILD_LUMA_PALETTE
        ; Override luma pointer → VDC palette (RGBI 4-bit encoding).
        LDA #<iter_to_color_vdc_luma
        STA luma_table_ptr
        LDA #>iter_to_color_vdc_luma
        STA luma_table_ptr+1
.endif
        
        ; Enable 64K mode for VRAM amount probe.
        LDX #$1C            ; VDC[CB]: [7..5] = Character base address (A15-A13); [4] = RAM-Type.
        LDA #$20            ; Set Character base address to $2000.
        ORA #$10            ; Set RAM-Type to 4464 (64 KBytes).
        JSR vdc_reg_write
        
        ; Check VDC VRAM available (16KB or 64KB).
        LDA #37             ; Use prime number for one-shot check.
        LDX #$FF            ; X: addr [LO]
        LDY #$07            ; Y: addr [HI]
        JSR vdc_mem_write
        LDX #$FF            ; X: addr [LO]
        LDY #$47            ; Y: addr [HI]
        JSR vdc_mem_read
        CMP #37
        BEQ no_vdc_64K

        ; VDC has 64K
        LDA #$01
        STA vdc_has_64K

no_vdc_64K:

        ; Clear VDC screen.
        LDA #$00
        LDY #$00
        JSR vdc_cls

;        ; Print "PLEASE WAIT..."
;        LDX #$00            ; X: addr [LO]
;        LDY #$00            ; Y: addr [HI]
;-       LDA str_vdc_wait,X
;        BEQ +
;        ; X: addr [LO]
;        JSR vdc_mem_write
;        INX
;        BNE -
;        BEQ +
;.enc "screen"
;str_vdc_wait: .text "vdc "
;str_vdc_mem:  .text "16kb. please wait...", 0
;.enc "none"
;+       
no_VDC:
.endif ;BUILD_C128

no_C128:
       
        ; Common C64 and C128 initialization.
.if BUILD_C64 | BUILD_C128        
        ; Setup CIA1
        LDA #$FF
        STA $DC02 ; DDRA all R/W
        STA $DC03 ; DDRB all R/W
        
        ; Setup VIC-II
        LDA #$00
        STA COL_BORDER
        LDA #$00
        STA COL_BGND
.elif BUILD_TED
        LDA #$FF
        STA $FD30         ; 6529B Keyboard scan mask.
        ; Init TED Time #1 for user input timing.
        LDA #$00
        STA $FF00
        LDA #$04
        STA $FF01
        LDA #$08          ; Set video matrix at $800
        STA $FF14
        ; Unmap ROM out of the way.
        LDA #$00   ; Dummy value.
        STA $FF3F  ; Any write to this register unmaps ROM.

        ; Setup TED
        LDA #$00
        STA COL_BORDER
        LDA #$00
        STA COL_BGND
.endif
        

.if BUILD_VIC20
        ; VIC20 initialization.
        LDA #$7F
        STA $911E     ; Disable VIA1 NMI.
        STA $912E     ; Acknowledge VIA2 interrupts.
        STA $912D     ; Disable VIA2 interrupts.
        ; VIC-20 multicolor uses 4 fixed colors per pixel pair: bg/border/char/aux.
        ; Iter values map directly via iter & 3, so the chosen colors should
        ; progress smoothly dark→bright for a natural Mandelbrot gradient.
        ;
        ; With BUILD_LUMA_PALETTE: black → blue → purple → white (cool dark-to-bright).
        ; Without: original black/white/purple/cyan (no luma order; iter 1 jumps to white).
.if BUILD_LUMA_PALETTE
        COL_VIC_BORDER = 6 ; %01 = blue (dark)
        COL_VIC_AUX    = 1 ; %11 = white (bright)
.else
        COL_VIC_BORDER = 1 ; %01 = white
        COL_VIC_AUX    = 3 ; %11 = cyan
.endif
        LDA #$00 | COL_VIC_BORDER  ; [7..4]=Background (black), 3=Reverse, [2..0]=Border.
        STA $900F
        LDA #COL_VIC_AUX<<4
        STA $900E

        ; Set Screen RAM location at $0200 and Color RAM at $9600.
        ;  SCR_RAM[13-10] = $9005 [7..4]
        ;  SCR_RAM[9]     = $9002 [7]
        LDA #$80
        STA $9005
        LDA #$80|22
        STA $9002
;r JMP r
        
        ; Init VIAs for joystick reading (joystick input uses both VIAs).
        LDA #$00
        STA $9113 ; VIA1 DDRA
        STA $9122 ; VIA2 DDRB

        ; Too tight in here, as we need to define a "bitmap" charset (256 chars, 16 lines each): $1000-$1FFF.
        JMP $2400
        * = $2400
.endif


.if BUILD_PET
        ; Check if we have more than 2 KB video RAM.
        ; This is required to avoid setting "Color RAM" over mirrored Screen RAM.
        LDY $8000
        LDA #$20
        STA $8000
        LDA #$00
        STA $8800
        CMP $8000
        BEQ +
        ; Init extra video RAM in case it's Color RAM.
        LDA #$0F
        LDX #$00
-       STA $8800,X
        STA $8900,X
        STA $8A00,X
        STA $8B00,X
        INX
        BNE -
        LDA #1
+       STA pet_more_than_2KB_vram
        STY $8000

        ; Print "Press space" msg.
        LDA #<str_press_space
        STA str_ptr
        LDA #>str_press_space
        STA str_ptr+1
        JSR print_str
        
        LDX #'m'-64
        STX $8000
wait_pet_key:
        LDA #6              ; Select row 8 (either keyboard)
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$02            ; Check for 'C'.
        BNE no_C
        ; 'C' pressed. Invert color flag.
        LDX #'m'-64
        LDA pet_color
        EOR #$01
        STA pet_color
        BEQ is_mono
        LDX #'c'-64
is_mono:
        STX $8000
wait_release_C:
        LDA $E812           ; PIA1:PB
        AND #$02            ; Check for 'C'.
        BEQ wait_release_C

no_C:   LDA #8              ; Select row 8 (business keyboard)
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$04            ; Check for 'Space'.
        BNE +
        LDA #1              ; business keyboard detected
        STA pet_business_keyb
        JMP space_pressed
+       LDA #9              ; Select row 9 (normal keyboard)
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$04            ; Check for 'Space'.
        BNE wait_pet_key
space_pressed:    

.endif        

.if !BUILD_PET
        ; Print wait msg.
        LDA #<str_wait
        STA str_ptr
        LDA #>str_wait
        STA str_ptr+1
        JSR print_str
.endif
        
        ; Only build squares table if we have at least 64 KB RAM.
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_ATARI | BUILD_B128
        ; Initialize Q4.10 squares table.
        JSR init_squares_q4_10
.endif



.if BUILD_ATARI
        ; Enable special GTIA mode (16 luma).
        LDA $D01B
        AND #$3F
        ORA #%01000000       ; Set the GTIA mode bits (7-6) for 1 color / 16 luma.
        STA $D01B            ; PRIOR
        
        ; Customize the first 16 characters to display solid luma patterns (2x8 pixels).
        LDA #%00000000
        LDX #$00
nxt_char_pattern:
        LDY #8               ; Fill all 8 char lines.
-       STA $1000,X
        INX
        DEY
        BNE -
        CLC
        ADC #%00010001       ; Go to next pattern (2 pixels per char line).
        BCC nxt_char_pattern
.endif

        ; Enter main Mandelbrot code.        
        JSR Mandelbrot
exit:
        ; We'll never get back to here.
        ; We can't return to BASIC, as we have messed up the system quite good.
        ; Besides, there is no QUIT button ;-)
        RTS 


;==============================================================
; Strings
str_intro:
        .byte $93 ;Clear screen.      
        ;.text $0D, "..!? 012349 ABC abcdefghijklmnop" ; Used for testing.
        .text $0D
        .text "ddt's fixed-point mandelbrot", $0D
        .text "version 2025-02-25", $0D
        ;.text "https://github.com/0x444454/mandelbr8", $0D
        .byte $00

.if BUILD_C64
str_kawari:
        .text "found kawari.", $0D
        .byte $00
.endif        

str_wait:
        .text "please wait...", $0D
        .byte $00

str_press_space:
        .text $0D, "press 'c' to switch mono/color mode.", $0D
        .text "press 'space' to start...", $0D
        .byte $00
;==============================================================
; PET and CBM-II (B128) stuff

.if BUILD_PET | BUILD_B128
pet_more_than_2KB_vram:     .byte 0   ; Flag (0:<=2KB, 1: >2KB).
pet_color:                  .byte 0   ; Flag (0:normal, 1:color).
pet_business_keyb:          .byte 0   ; Flag (0:normal, 1:business).

pet_scratch:                .byte 0

iter_to_PETSCII: .byte $20, $3A, $2D, $2B, $57, $30, $2A, $51
                 .byte $54, $5A, $58, $58, $23, $18, $0F, $2E

cbm_columns:                .byte 40  ; Number of char columns.
.endif

; ---- Luma-ordered C64 color table ----
; Index = iter & $0F. Output = C64 color number (0..15) chosen so that the
; sequence forms a smooth dark→bright luminance gradient. On a color screen
; iter rings appear as a topographic gradient; on B&W or grayscale the
; gradient is monotonic. Always defined; only used if BUILD_LUMA_PALETTE = 1.
iter_to_color_luma:
    .byte $00    ; iter 0:  black     (in-set, luma 0)
    .byte $06    ; iter 1:  blue      (luma 1)
    .byte $02    ; iter 2:  red       (luma 2)
    .byte $0B    ; iter 3:  dark grey (luma 3)
    .byte $04    ; iter 4:  purple    (luma 4)
    .byte $09    ; iter 5:  brown     (luma 5)
    .byte $05    ; iter 6:  dark green(luma 6)
    .byte $08    ; iter 7:  orange    (luma 7)
    .byte $0C    ; iter 8:  med grey  (luma 8)
    .byte $0E    ; iter 9:  light blue(luma 9)
    .byte $0A    ; iter 10: pink      (luma 10)
    .byte $0D    ; iter 11: light grn (luma 11)
    .byte $03    ; iter 12: cyan      (luma 12)
    .byte $0F    ; iter 13: light grey(luma 13)
    .byte $07    ; iter 14: yellow    (luma 14)
    .byte $01    ; iter 15: white     (luma 15)

; ---- Luma-ordered VDC color table (C128 80-col mode) ----
; VDC (8563/8568) on C128 uses a CGA-style 16-color palette (NOT a simple
; RGBI bit mapping). The canonical C128 Programmer's Reference order is:
;   $0 Black, $1 Dark gray, $2 Blue,    $3 Light blue,
;   $4 Green, $5 Light grn, $6 Cyan,    $7 Light cyan,
;   $8 Red,   $9 Light red, $A Magenta, $B Light magenta,
;   $C Brown, $D Yellow,    $E Light gray, $F White.
; Luma values below are computed with Y' = 0.299R + 0.587G + 0.114B against
; standard CGA RGB values (intensity-2/3 for low-bright pairs, 255 for high).
; Only used in C128 build when running in VDC (80-col) mode.
; ---- TED uniform-luma constant ----
; TED multicolor allows only 2 cell-specific colors per 4x8 cell. Varying
; luma between cells produces visible stepping at boundaries, so all colors
; render at the same luma; only hue varies per cell.
;
; Luma 0..7: 6 = pastel (washes toward white); 4 = vivid mid-bright;
; 2-3 = dark, deep. Single constant, change to taste.
.if BUILD_TED
TED_HI_LUMA = $4
.endif

.if BUILD_C128
iter_to_color_vdc_luma:
    .byte $00    ; iter 0:  black            (Y=0)
    .byte $02    ; iter 1:  blue             (Y=19)
    .byte $08    ; iter 2:  dark red         (Y=51)
    .byte $0A    ; iter 3:  magenta          (Y=70)
    .byte $01    ; iter 4:  dark gray        (Y=85)
    .byte $04    ; iter 5:  dark green       (Y=100)
    .byte $0C    ; iter 6:  brown            (Y=101)
    .byte $03    ; iter 7:  light blue       (Y=104)
    .byte $06    ; iter 8:  dark cyan        (Y=119)
    .byte $09    ; iter 9:  light red        (Y=135)
    .byte $0B    ; iter 10: light magenta    (Y=154)
    .byte $0E    ; iter 11: light gray       (Y=170)
    .byte $05    ; iter 12: light green      (Y=184)
    .byte $07    ; iter 13: light cyan       (Y=203)
    .byte $0D    ; iter 14: yellow           (Y=235)
    .byte $0F    ; iter 15: white            (Y=255)
.endif

;==============================================================
; Atari stuff
           
.if BUILD_ATARI
; Atari display list for text mode (lo-res).
atari_DL_text:
    .fill   3, $70              ; Blank 8 lines.
    .byte      $42              ; ANTIC mode 2 (40x25), 1 line + set ptr.
    .byte      <SCR_RAM         ; SCR_RAM LO
    .byte      >SCR_RAM         ; SCR_RAM HI
    .fill  24, $02              ; ANTIC mode 2 (40x25), 24 more lines.
    .byte      $41              ; Jump and wait for vertical blank.
    .byte      <atari_DL_text   ; Jump address LO
    .byte      >atari_DL_text   ; Jump address HI

; Atari display list for text mode (hi-res).
atari_DL_bitmap:
    .fill   3, $70              ; Blank 8 lines.
    .byte      $4F              ; ANTIC mode F.1 (80x200), 1 line + set ptr.
    .byte      <BITMAP_START    ; bitmap LO
    .byte      >BITMAP_START    ; bitmap HI
    .fill   1, $0F              ; ANTIC mode F.1 (80x200), 199 more lines.
                                ; NOTE: Just one line in this template. We'll expand it during copy.
    .byte      $41              ; Jump and wait for vertical blank.
    .byte      <atari_DL_bitmap ; Jump address LO
    .byte      >atari_DL_bitmap ; Jump address HI

; Atari NMI routine.
atari_NMI:
        INC frame_couter
        RTI

frame_couter: .byte 0

; Atari IRQ routine.
atari_IRQ:
        INC $401
        RTI
.endif
           
;------------- system & configs -------------

.if BUILD_C64
  SCR_RAM      = $0400
  COL_RAM      = $D800
  COL_BORDER   = $D020
  COL_BGND     = $D021
  LORES_W      = 40
  LORES_H      = 25
  HIRES_H      = 200
  HIRES_TILE_H = 8
  BITMAP_START = $2000
.if BUILD_HIRES_CONTOUR
  HIRES_W      = 320   ; 1 bit/pixel: 8 pixels per byte
  HIRES_TILE_W = 8
.else
  HIRES_W      = 160   ; 2 bits/pixel multicolor: 4 pixels per byte
  HIRES_TILE_W = 4
.endif
.elif BUILD_C128
  SCR_RAM      = $0400
  COL_RAM      = $D800
  COL_BORDER   = $D020
  COL_BGND     = $D021
  LORES_W      = 40
  LORES_H      = 25
  HIRES_W      = 160   ; NOTE: This is for VIC-II hires (not VDC).
  HIRES_H      = 200   ; NOTE: This is for VIC-II hires (not VDC).
  HIRES_TILE_W = 4     ; NOTE: This is for VIC-II hires (not VDC).
  HIRES_TILE_H = 8     ; NOTE: This is for VIC-II hires (not VDC).
  BITMAP_START = $2000
.elif BUILD_TED
  SCR_RAM      = $0C00 ; Video matrix
  COL_RAM      = $0800 ; Attributes matrix
  COL_BORDER   = $FF19
  COL_BGND     = $FF15 ; Background register #0
  LORES_W      = 40
  LORES_H      = 25
  HIRES_W      = 160
  HIRES_H      = 200
  HIRES_TILE_W = 4
  HIRES_TILE_H = 8  
  BITMAP_START = $2000
.elif BUILD_VIC20
  SCR_RAM      = $0200 ; Video matrix.
  COL_RAM      = $9600
  COL_BORDER   = $900F ; Border and background are in the same register. Border is [2..0].
  COL_BGND     = $900F ; Border and background are in the same register. Background is [7..4].
  LORES_W      = 22
  LORES_H      = 22
  HIRES_W      = LORES_W*4
  HIRES_H      = LORES_H/2*16 ; I.e. 11 rows of chars, 16 lines per char.
  HIRES_TILE_W = 4
  HIRES_TILE_H = 8
  BITMAP_START = $1000 ; Charset defined at $1000.
.elif BUILD_PET
  SCR_RAM      = $8000 ; Video matrix.
  COL_RAM      = $8800 ; Only works on PET supporting color.
  COL_BORDER   = $FFFF ; Dummy.
  COL_BGND     = $FFFF ; Dummy.
  LORES_W      = 40
  LORES_H      = 25
  HIRES_W      = 0
  HIRES_H      = 0
  HIRES_TILE_W = 0
  HIRES_TILE_H = 0
  BITMAP_START = $0000
.elif BUILD_B128
  SCR_RAM      = $D000 ; Video matrix (bank 15).
  COL_RAM      = $0000 ; No Color RAM.
  COL_BORDER   = $FFFF ; Dummy.
  COL_BGND     = $FFFF ; Dummy.
  LORES_W      = 40    ; This is for the 40-col model (though we currently support only 80-col model).
  LORES_H      = 25
  HIRES_W      = 0
  HIRES_H      = 0
  HIRES_TILE_W = 0
  HIRES_TILE_H = 0
  BITMAP_START = $0000 ; No bitmap.
.elif BUILD_ATARI
  SCR_RAM      = $0400 ; Video matrix.
  COL_RAM      = $0400 ; ?
  COL_BORDER   = $D01A ; COLBK (border is same as background).
  COL_BGND     = $D01A ; ?
  LORES_W      = 40
  LORES_H      = 25
  HIRES_W      = 80
  HIRES_H      = 200
  HIRES_TILE_W = 2
  HIRES_TILE_H = 8
  BITMAP_START = $2060 ; Bitmap starts at $2060 to allow hitting $3000 exactly in the middle of the screen (ANTIC 4KB limitation). 
.elif BUILD_BEEB
  SCR_RAM      = $3000 ; Video matrix (this is actually a MODE 2: bitmap).
  COL_RAM      = $3000 ; No color RAM. Unfortunately, TASS64 has no .ifdef.
  COL_BORDER   = $FFFF ; Dummy.
  COL_BGND     = $FFFF ; Dummy.
  LORES_W      = 40
  LORES_H      = 32
  HIRES_W      = 160
  HIRES_H      = 255
  HIRES_TILE_W = 4
  HIRES_TILE_H = 8
  BITMAP_START = $3000
.endif


; The following is a bitmask, for faster checks.
MODE_VIC      =   $01       ; VIC-like video. E.g. VIC, VIC-II, TED, PET, et cetera.
MODE_KAWARI   =   $02
MODE_VDC      =   $04
MODE_BEEB     =   $08

mode:           .byte MODE_VIC  ; Default to VIC mode.
res:            .byte 0         ; 0 if text/lo-res, 1 if hi-res. Default to text/lo-res.

.if BUILD_C128
vdc_has_64K:            .byte 0     ; Boolean: 0=false; non-0=true.
vdc_hires_even_color:   .byte 0     ; Color of current hires even pixel.
.endif

.if BUILD_C64
kawari_palette_RGB:
    .byte   0,   0,   0,  0
    .byte  10,   7,  40,  0
    .byte   9,   1,  60,  0
    .byte   4,   4,  73,  0
    .byte   0,   7, 100,  0
    .byte  12,  44, 138,  0
    .byte  24,  82, 177,  0
    .byte  57, 125, 209,  0
    .byte 134, 181, 229,  0
    .byte 211, 236, 248,  0
    .byte 241, 233, 191,  0
    .byte 248, 201,  95,  0
    .byte 255, 170,   0,  0
    .byte 204, 128,   0,  0
    .byte 153,  87,   0,  0
    .byte 106,  52,   3,  0
kawari_palette_LPA:
    .byte $19, $02, $00, $20, $27, $2e, $30, $33, $36, $38, $37, $35, $33, $30, $2c, $28 ; Luma  (6 bits).
    .byte $00, $00, $00, $0a, $05, $f0, $e0, $d0, $ca, $70, $66, $66, $63, $61, $69, $6a ; Phase (8 bits).
    .byte  $0,  $8,  $c,  $f,  $f,  $f,  $f,  $f,  $6,  $4,  $b,  $f,  $e,  $f,  $f,  $f ; Amp   (4 bits).
.endif

;------------- print routine (no Kernal was harmed in the making of this routine) -------------
; Print zero-terminated string pointed to by (str_ptr), max 255 chars.
; This routine trashes registers and changes (str_ptr).
print_str:

.if BUILD_VIC20
        ; Unimplemented on VIC-20.
        RTS
.endif

pr_ch:
        LDY #0             ; Clear index.
        LDA (str_ptr),Y    ; Load the next char from the message.
        BNE pr_no_EOS
        ; If character is 0 (end of string), return.
        RTS

pr_no_EOS:
        CMP #$0D           ; <CR>
        BNE pr_no_CR
        LDA #0
        STA cursor_x
        INC cursor_y
        JSR calc_scr_addr
        JMP done_char
pr_no_CR:       
        CMP #$93           ; <CLS>
        BNE pr_no_CLS

        JSR clear_screen

        ; End clear screen. Reset cursor.
        LDA #$00
        STA cursor_x
        STA cursor_y
        JSR calc_scr_addr
        JMP done_char

pr_no_CLS:       
        ; ASCII char. Convert to screen code.
        CLC
        CMP #32
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_PET | BUILD_B128
        BPL +
        ADC #128 ; Commodore
.else
        BCC +
        ; ASCII lower than 32.
        SBC #32 ; Atari
.endif        
        JMP done_conv
+       CMP #64
        BMI done_conv
        CMP #97
        BPL +
        SEC
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_PET | BUILD_B128  
        SBC #64
.else
        SBC #32 ; ATARI
.endif        
        JMP done_conv
+       CMP #128
        BPL done_conv
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_PET | BUILD_B128
        SEC
        SBC #32
.endif        
        JMP done_conv
        LDA #46        ; Unkown. Use ".".
done_conv:
        ; Normal screen code.
        LDY #$00
.if BUILD_C128
        LDX mode
        CPX #MODE_VDC
        BEQ set_char_VDC
        ; C128 VIC-IIe
        STA (scr_ptr),Y
        JMP +
set_char_VDC:
        ; C128 VDC
        PHA
        LDA scr_ptr+1
        SEC
        SBC #$04
        TAY             ; Y: VRAM addr [HI]
        LDX scr_ptr     ; X: VRAM addr [LO]
        PLA             ; A: Byte value to write.
    ;LDA #$00
    ;TAX
    ;TAY
        JSR vdc_mem_write
+
.elif BUILD_B128
        ; B128: Switch "LDA/STA (zp),Y" to bank 15 (ROM and I/O).
        PHA
        LDA #15
        STA $01
        PLA
        STA (scr_ptr),Y
        ; Switch back to bank 1.
        LDA #1
        STA $01
.else
        ; Other machines.
        STA (scr_ptr),Y
.endif        
        
done_char_move_pos:
        INC cursor_x
        INC scr_ptr
        BNE +
        INC scr_ptr+1
+
done_char:    
        INC str_ptr         ; Increase char*.
        BNE +
        INC str_ptr+1
+       JMP pr_ch
pr_end:
        RTS


calc_scr_addr:
        ; Default to 40 columns. Mul by 40.
.if BUILD_PET | BUILD_B128
        LDA cbm_columns
.else
        LDA #40
.endif        
        STA x0
.if BUILD_C128        
        LDA mode
        AND #MODE_VDC
        BEQ +
        ASL x0             ; Actually, it is 80 columns.
+       
.endif
        LDA cursor_y
        STA y0
        LDA #$00           ; 256x256 chars will be enough for everyone...
        STA x1
        STA y1
        JSR multiply_16bit_unsigned
        ; Y-offset is in [z0..z1].
        LDA z0
        CLC
        ADC cursor_x
        STA scr_ptr
        LDA #$00
        ADC z1
        ADC #>SCR_RAM
        STA scr_ptr+1
        RTS

cursor_x:   .byte 0
cursor_y:   .byte 0


;------------- clear screen -------------
clear_screen:
.if BUILD_B128
        ; B128 clear screen.
        LDA #15
        STA $1
        LDA #<SCR_RAM
        STA $04
        LDA #>SCR_RAM
        STA $05
        LDY #0
cls_B128_page:        
        LDA #' '
cls_B128_b:
        STA ($04),Y
        INY
        BNE cls_B128_b
        INC $05
        LDA $05
        CMP #$D8            ; End of SCR_RAM.
        BNE cls_B128_page
        LDA #1
        STA $1
        RTS
.endif

.if BUILD_BEEB
        ; Just clear the entire bitmap: $3000..$7FFF
        LDA #$00
        STA bmp_ptr
        LDA #$30
        STA bmp_ptr+1
        LDY #0
nxt_page:
        LDA #$00
-       STA (bmp_ptr),Y
        INY
        BNE -
        INC bmp_ptr+1
        LDA bmp_ptr+1
        CMP #$80
        BNE nxt_page
        RTS
.endif

.if BUILD_VIC20
        LDA res
        BNE clear_hi
        ; Clear lo-res
        ;
        ; Screen RAM
        LDX #$00
        LDA #' '
-       STA SCR_RAM,X
        STA SCR_RAM+$100,X
        INX
        BNE -
        ; Color RAM
        LDA #$00
-       STA COL_RAM,X
        STA COL_RAM+$100,X
        INX
        BNE -
        RTS

clear_hi:
        ; Clear hi-res
        LDA #<BITMAP_START
        STA bmp_ptr
        LDA #>BITMAP_START
        STA bmp_ptr+1
        LDY #0
nxt_page:
        LDA #$00
-       STA (bmp_ptr),Y
        INY
        BNE -
        INC bmp_ptr+1
        LDA bmp_ptr+1
        CMP #>BITMAP_START + $10 ; We clear $1000 bytes.
        BNE nxt_page
        RTS
.endif

        LDA mode
        AND #MODE_VIC | MODE_KAWARI
        BEQ no_vic2_or_kawari
.if !BUILD_HIRES_CONTOUR
        ; Contour mode: screen RAM was already set to $50 by apply_mode — skip.
        LDX #$00
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_PET
        LDA #$A0 ; Use reverse spaces.
.else
        LDA #$20 ; Use spaces.
.endif

-       STA SCR_RAM,X
        STA SCR_RAM+$100,X
        STA SCR_RAM+$200,X
        STA SCR_RAM+$300,X

.if BUILD_PET
        LDY cbm_columns
        CPY #80
        BNE +
        STA SCR_RAM+$400,X
        STA SCR_RAM+$500,X
        STA SCR_RAM+$600,X
        STA SCR_RAM+$700,X
+
.endif

        INX
        BNE - ; Print till zero term or max 256 chars.
.endif ; !BUILD_HIRES_CONTOUR
        ; Clear color RAM to default color.
        LDX #$00
.if BUILD_HIRES_CONTOUR
        LDA #$00 ; Contour lo-res: black (mono rendering uses iter & 1 during draw).
.elif BUILD_C64 | BUILD_C128 | BUILD_TED
        LDA #$71 ; Commodore: White (upper nibble is only used by TED for luma).
.else
        LDA #$00 ; Atari: Black.
.endif

.if COL_RAM
-       STA COL_RAM,X
        STA COL_RAM+$100,X
        STA COL_RAM+$200,X
        STA COL_RAM+$300,X
        INX
        BNE - ; Print till zero term or max 256 chars.
.endif        
        RTS
no_vic2_or_kawari:  

.if BUILD_C128
        LDA mode
        AND #MODE_VDC
        BEQ +
        ; VDC clear (A=attr, Y=char/bitmap).
        ; Attr $F0 = fg=white, bg=black. Bitmap/char = 0 → cell shows bg
        ; (black). Previously $0F (bg=white) made the un-rendered area look
        ; white as rendering filled top-to-bottom; black is more natural.
        LDA #$F0
        LDY #$00
        JSR vdc_cls
        RTS
+
.endif
   
        RTS
    
;------------- Switch lo/hi res -------------
; Note: Not all platforms support switching.
; Output: Z = 0 if mode switch succeeded (use BNE to branch on success).
; Clobbered: A, X
switch_res:
        LDA res
        TAX             ; Save to revert on error.
        EOR #$01        ; Toggle resolution.
        STA res
        JSR apply_mode
        BNE +           ; Success.
        STX res         ; ERROR: Revert res.
+       RTS

;------------- Apply mode -------------
; Configure machine based on current mode and resolution setting.
; Output: Z = 0 if mode switch succeeded (use BNE to branch on success).
; Clobbered: A, X
apply_mode:
        LDA mode

.if BUILD_C64 | BUILD_C128
    .if BUILD_C128
        CMP #MODE_VDC
        BNE chk_VIC2_res
        ; VDC
        LDA res
        BNE +
        ; Set VDC lores mode.
        JSR vdc_set_lores
        LDA #$FF            ; Z = 0 (supported).
        RTS
+       ; Set VDC hires mode.
        LDA vdc_has_64K
        BEQ vdc_hires_unsupported
        JSR vdc_set_hires
        LDA #$FF            ; Z = 0 (supported).
        RTS
vdc_hires_unsupported:        
        LDA #$00            ; Z = 1 (unsupported).
        RTS
    .endif

chk_VIC2_res:
        ;CMP #MODE_VIC
        ;BNE chk_KAWARI_res ; Kawari hi-res not yet supported.
        ; VIC2
        LDA res
        BNE +
        ; VIC2 lo-res (text)
        LDA $D011       ; Setup CR1
        AND #$9F        ; Clear ECM and BMM
        STA $D011
        LDA $D016       ; Setup CR2
        AND #$EF        ; Clear MCM
        STA $D016
        LDA #$14        ; Screen RAM at $400
        STA $D018
        LDA #1          ; Return OK
        JMP end_applymode
+       ; VIC2 hi-res bitmap mode.
.if BUILD_HIRES_CONTOUR
        ; Contour mode: clear bitmap and fill screen RAM BEFORE enabling BMM so
        ; VIC-II never sees old bitmap data with text-mode screen RAM colors
        ; (text mode leaves $A0 in screen RAM → hi nibble $A = pink when BMM active).
        JSR clear_bitmap        ; fill bitmap with $00 (all black)
        ; Fill all screen RAM: dark green ($5) fg, black ($0) bg.
        ; Use 256-byte pages (256 × 4 = 1024 bytes) so all 1000 tiles are
        ; covered — a 250-byte limit leaves 6-byte gaps at page boundaries.
        LDX #$00
        LDA #$50
-       STA SCR_RAM,X
        STA SCR_RAM+$100,X
        STA SCR_RAM+$200,X
        STA SCR_RAM+$300,X
        INX
        BNE -
        LDA #$18        ; Screen RAM at $0400, bitmap at $2000.
        STA $D018
        LDA $D016
        AND #$EF        ; Clear MCM.
        STA $D016
        LDA $D011       ; Enable BMM now — bitmap + screen RAM already set.
        AND #$9F
        ORA #$20
        STA $D011
.else
        ; Multicolor mode: enable BMM first, then set MCM + clear bitmap.
        LDA $D011       ; Setup CR1: set BMM, clear ECM.
        AND #$9F
        ORA #$20
        STA $D011
        ; Multicolor mode: 2 bits/px. Set MCM.
        LDA $D016
        ORA #$10
        STA $D016
        LDA #$18        ; Screen RAM at $0400, bitmap at $2000.
        STA $D018
        JSR clear_bitmap
.endif
        LDA #1          ; Return OK
        JMP end_applymode
chk_KAWARI_res:
        ; KAWARI_GFX
        LDA res
        ;CMP #$01        ; Hi-res not yet supported on Kawari.
        JMP end_applymode
+
.elif BUILD_TED
        LDA res
        BNE +
        ; TED lo-res (text)
        LDA $FF12
        ORA #$04        ; Point to ROM (set bit 2).
        STA $FF12
        ; Clear multicolor mode.
        LDA $FF07
        AND #$EF
        STA $FF07
        ; Disable bitmap mode.
        LDA $FF06
        AND #$5F        ; Set also TED test bit (7) to 0.
        STA $FF06
        LDA #1          ; Return OK
        JMP end_applymode
+       ; TED hi-res (bitmap multicolor: 2 diff colors per 4x8 cell + 2 background colors (#0, #1).
        JSR clear_bitmap
        ; Initialise COL_RAM to uniform luma for both pattern slots; per-tile
        ; render writes only hues to SCR_RAM, COL_RAM stays at this luma.
        LDX #$00
-       LDA COL_RAM,X
        STA SCR_RAM,X
        LDA #(TED_HI_LUMA<<4)|TED_HI_LUMA
        STA COL_RAM,X

        LDA COL_RAM+$100,X
        STA SCR_RAM+$100,X
        LDA #(TED_HI_LUMA<<4)|TED_HI_LUMA
        STA COL_RAM+$100,X

        LDA COL_RAM+$200,X
        STA SCR_RAM+$200,X
        LDA #(TED_HI_LUMA<<4)|TED_HI_LUMA
        STA COL_RAM+$200,X

        LDA COL_RAM+$300,X
        STA SCR_RAM+$300,X
        LDA #(TED_HI_LUMA<<4)|TED_HI_LUMA
        STA COL_RAM+$300,X

        INX
        BNE -
        ; Background #1: gray (hue 1) at TED_HI_LUMA so uncovered-iter pixels
        ; per cell blend in at the same brightness as the rest of the palette.
        LDA #(TED_HI_LUMA<<4)|$1
        STA $FF16
        ; Set bmp base to $2000.
        LDA $FF12
        AND #$C3        ; Also, point to RAM (clear bit 2).
        ORA #$08
        STA $FF12
        ; Set multicolor mode.
        LDA $FF07
        ORA #$10
        STA $FF07
        ; Enable bitmap mode.
        LDA $FF06
        ORA #$20
        STA $FF06
        LDA #1          ; Return OK
        JMP end_applymode
.elif BUILD_VIC20
        LDA res
        BNE vic_hr
        ; VIC-20 lo-res.
        ; Set char mem to $8000 (ROM).
        LDA #$80
        STA $9005
        ; Set 22x22 resolution, 8 lines per char.
        LDA #$80|22
        STA $9002       ; Cols
        LDA #22<<1
        STA $9003       ; Rows
        ; Return OK
        LDA #1
        JMP end_applymode
vic_hr: 
        ; Fill Screen RAM with sequential chars to fake bitmap mode, and init Color RAM.
        LDX #$00
-       TXA
        STA SCR_RAM,X
        LDA #$08|4          ; Set CRAM to fixed char color + multicolor attribute.
        STA COL_RAM,X
        INX
        CPX #22*11
        BNE -
        ; Set char mem to $1000 (this is our bitmap RAM).
        LDA #$8C ; $1000
        STA $9005
        ; Set 22x11 resolution, 16 lines per char.
        LDA #$80|22
        STA $9002       ; Cols
        LDA #11<<1|1
        STA $9003       ; Rows.
        ; Now render hi-res preview using the lo-res iterations buffer.
        LDA #<BITMAP_START
        STA bmp_ptr
        LDA #>BITMAP_START
        STA bmp_ptr+1
        ; Let's do two lo-res rows at a time to handle 16-lines chars.
        LDA #<buf_iters_lr
        STA buf_it_ptr
        LDA #>buf_iters_lr
        STA buf_it_ptr+1
        LDA #LORES_H
        LSR                 ; We convert 2 lo-res rows at a time.  
        STA ctdwn_rows
nxt_tile_rows_to_convert:         
        LDA #LORES_W
        STA ctdwn_cols
nxt_tile_to_convert:        
        ; Upper half.
        LDY #0
        LDA (buf_it_ptr),Y
        AND #$03            ; Mod4.
        TAX
        LDA vic_multicolor_table,X
-       STA (bmp_ptr),Y
        INY
        CPY #8
        BNE -
        ; Lower half.
        LDY #LORES_W
        LDA (buf_it_ptr),Y
        AND #$03            ; Mod4.
        TAX
        LDA vic_multicolor_table,X        
        LDY #8
-       STA (bmp_ptr),Y
        INY
        CPY #16
        BNE -
        ; Done 16-lines char.
        INC buf_it_ptr
        BNE +
        INC buf_it_ptr+1
+       LDA bmp_ptr
        CLC
        ADC #16
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+       DEC ctdwn_cols
        BNE nxt_tile_to_convert
        ; Done two tile rows.
        ; Point to next lo-res addr.
        LDA buf_it_ptr
        CLC
        ADC #<LORES_W
        STA buf_it_ptr
        LDA buf_it_ptr+1
        ADC #>LORES_W
        STA buf_it_ptr+1
        ; Point to next hi-res addr.        
        DEC ctdwn_rows
        BNE nxt_tile_rows_to_convert
        ; Return OK
        LDA #1
        JMP end_applymode

vic_multicolor_table:
             .byte $00, $55, $AA, $FF

ctdwn_cols:  .byte 0
ctdwn_rows:  .byte 0

.elif BUILD_ATARI
        LDA #$14            ; High byte of display list address (default to lo-res).
        LDX res
        BNE +
        JMP switch_display_list
+       ; ATARI hi-res
        ; Copy lo-res image to hi-res.
        LDA #40
        STA num_tiles_w
        LDA #25
        STA num_tiles_h
        LDA #<SCR_RAM
        STA scr_ptr
        LDA #>SCR_RAM
        STA scr_ptr+1
        LDA #<BITMAP_START
        STA bmp_ptr
        LDA #>BITMAP_START
        STA bmp_ptr+1
        LDY #0
        LDA #0
        STA tiley
cpy_nxt_lr_tile_row:
        LDA #0
        STA tilex
cpy_nxt_lr_tile:        
        LDA (scr_ptr),Y
        ROL
        ROL
        ROL
        ROL
        AND #$F0
        STA (bmp_ptr),Y
        LDA (scr_ptr),Y
        AND #$0F
        ORA (bmp_ptr),Y
        STA (bmp_ptr),Y
        STA tmp_bmp_line   ; Save value to store in this tile.
        LDA bmp_ptr
        PHA
        LDA bmp_ptr+1
        PHA
        LDX #7              ; Write value to the remaining 7 tile lines.
cpy_t_line:
        LDA bmp_ptr
        CLC
        ADC num_tiles_w     ; This is a linear buffer, skip down one line.
        STA bmp_ptr
        LDA bmp_ptr+1
        ADC #0
        STA bmp_ptr+1
        LDA tmp_bmp_line
        STA (bmp_ptr),Y
        DEX
        BNE cpy_t_line
        PLA
        STA bmp_ptr+1
        PLA
        STA bmp_ptr
        INC scr_ptr
        BNE +
        INC scr_ptr+1
+       TXA
        PHA
        INC tilex
        JSR bmp_to_next_tile
        PLA
        TAX
        LDA tilex
        CMP num_tiles_w
        BNE cpy_nxt_lr_tile
        ; Copied a tile row.
        INC bmp_ptr
        BNE +
        INC bmp_ptr+1
+       INC tiley
        LDA tiley
        CMP num_tiles_h
        BNE cpy_nxt_lr_tile_row
        ; Done copying. Reset tilex and tiley.
        LDA #$00
        STA tilex
        STA tiley
        ; Set hi-res display list.
        LDA #$15
switch_display_list:
        ; Disable ANTIC DMA
        LDX #$00            ; Disable display list DMA.
        STX $D400           ; DMACTL
        ; Switch display list.
        STA $D403           ; Store in DLISTH
        ; Enable ANTIC DMA
        LDA #$22            ; Disable display list DMA.
        STA $D400           ; DMACTL
        LDA #1              ; Return OK
        JMP end_applymode
.elif BUILD_BEEB
        ; BBC Micro.
        ; Not much to do here, as we run the Beeb always in bitmap mode.
        ; Reset bitmap pointers.
        LDA #$00
        STA bmp_ptr
        LDA #$30
        STA bmp_ptr+1
        ; Return OK
        LDA #1
        JMP end_applymode
.else
        ; Unhandled mode.
        LDA #0          ; Return ERROR
.endif
end_applymode:
;ee: LDA res
;    BNE ee
        RTS

tmp_bmp_line: .byte 0


;------------- Clear bitmap -------------
; Clear the bitmap ($2000 to $3FFF). That works for Atari too (bitmap starts at $2060).
; Clobbered: A, X
clear_bitmap:
        LDA #$20
        STA str_ptr+1
        LDA #$00
        STA str_ptr
        LDX #$00
-       
.if BUILD_C64 | BUILD_C128
.if BUILD_HIRES_CONTOUR
        LDA #$00        ; Contour: all background (black).
.else
        LDA #$FF        ; Default to multicolor 3 (taken from Color RAM which should be already set).
.endif
.elif BUILD_TED
        LDA #$AA        ; Default color to video matrix [3−0], luma to attribute matrix [6−4].
.elif BUILD_VIC20
        LDA #$FF        ; Default to multicolor 3.
.endif        
        STA (str_ptr,X)
        INC str_ptr
        BNE -
        INC str_ptr+1
        LDA str_ptr+1
        CMP #$40
        BNE -
        RTS

;------------- Clear iters histogram -------------
clear_histogram:
        LDA #$00
        LDX #16       ; Colors histogram is 16 bytes.
-       STA b_hist,X
        DEX
        BNE -
        RTS

;------------- Build histogram -------------
; Build the color histogram from the content of iterations buffer.
; Only the first 4 bits of iter are used (mod16), so the histogram takes 16 bytes.
build_histogram:
        JSR clear_histogram
        LDA #<buf_iters_hr
        STA buf_it_ptr
        LDA #>buf_iters_hr
        STA buf_it_ptr+1
        LDY #0
-       LDA (buf_it_ptr),Y
        AND #$0F          ; Mod16.
        TAX
        INC b_hist,X
        INY
        CPY buf_tile_size
        BNE -
        RTS

;------------- Scan histogram -------------
; Find the 4 most used colors (mod16), and store them sorted in h_top4 (higher to lower).
; NOTE: Black (color 0) is not counted, as it is the fixed background color (and always available).
; NOTE: This is probably overkill, as we only need 3 colors + black (fixed background).
scan_histogram:
        ; Clear results.
        LDA #$00
        ; Clear top counts.
        STA h_top4_cnt
        STA h_top4_cnt+1
        STA h_top4_cnt+2
        STA h_top4_cnt+3
        ; Y is the result index (0 to 4).
        LDY #0
find_next:
        ; Scan all 16 entries.
        LDA #0
        STA h_top4_cnt,Y       ; Highest count found.
        STA h_top4_idx,Y       ; Index of highest found.
        LDX #15                ; Start with color 15 (down to 1).
-       LDA b_hist,X           ; Fetch color count.
        CMP h_top4_cnt,Y       ; Is this color more used than current most used ?
        BCC +                  ; BLT.
        ; Higher or equal found.
        STA h_top4_cnt,Y       ; Update highest count.
        STX h_top4_idx,Y       ; Update index of highest count.
+       DEX
        BNE -                  ; Stop at color 1, avoiding 0 (black) as the background color is always available.
        ; Found the index. Zero its histogram count, so we won't parse it again.
        LDA h_top4_idx,Y
        TAX
        LDA #$00
        STA b_hist,X 
        ; Find next.
        INY
        CPY #4
        BNE find_next
        RTS



;------------- Render tile (multicolor version) -------------
; Render a hi-res tile in multicolor mode.
; We have several different variants, as Commodore video chips are all different in this regard, i.e. for each 4x8 cell:
; - VIC:    1 custom color,  3 global. We use 4 fixed global colors.
; - TED:    2 custom colors, 2 global. We pick the 2 most used in the cell.
; - VIC-II: 3 custom colors, 1 global. We pick the 3 most used in the cell.
;
render_tile_multicolor:
.if BUILD_C64 | BUILD_C128
        ; Render a multicolor 4x8 tile based on the computed histogram.
        ; We need to choose between black or any of the other three most used colors in the tile.
        ; In multicolor bitmap, each pixel is encoded as two bits:
        ;   00 : Background color 0 ($D021)
        ;   01 : Color from bits 4-7  of c-data (Screen RAM hi-nibble).
        ;   10 : Color from bits 0-3  of c-data (Screen RAM lo-nibble).
        ;   11 : Color from bits 8-11 of c-data (Color RAM lo-nibble). 
        ;
        ; Set most used three colors in c-data (fourth color is always black).
        ;
        ; Color RAM (%11).
        LDA tile_num
        STA cram_ptr
        LDA tile_num+1
        CLC
        ADC #$D8
        STA cram_ptr+1
        LDA h_top4_idx+2
        LDY #0
        STA (cram_ptr),Y
        ; Screen RAM (%10 and %01).
        LDA tile_num+1
        CLC
        ADC #$04
        STA cram_ptr+1
        LDA h_top4_idx+1
        AND #$0F
        STA tmp_A
        LDA h_top4_idx+0
        ASL
        ASL
        ASL
        ASL
        ORA tmp_A
        STA (cram_ptr),Y
.elif BUILD_TED
        ; Point to video matrix. Lumas are set globally to TED_HI_LUMA in
        ; apply_mode (uniform luma hides multicolor cell-clash artifacts);
        ; per-cell write here only sets the two cell hues.
        LDA tile_num
        STA cram_ptr
        LDA tile_num+1
        CLC
        ADC #>SCR_RAM       ; Video matrix.
        STA cram_ptr+1
        LDA h_top4_idx      ; Multicolor pattern %01 uses color from video matrix bits [7..4].
        ASL
        ASL
        ASL
        ASL
        LDY #0
        STA (cram_ptr),Y
        LDA h_top4_idx+1    ; Multicolor pattern %10 uses color from video matrix bits [3..0].
        AND #$0F
        ORA (cram_ptr),Y
        STA (cram_ptr),Y
.elif BUILD_VIC20
        ; We use 4 fixed colors in multicolor mode, so no need to set cram here (already done in hi-res mode init).
.endif

.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_VIC20      
        ; bmp_ptr contains the current tile bitmap line (4 pixels, 2 bits each).
        ; buf_it_ptr is the per-pixel iterations buffer.
        LDA #<buf_iters_hr
        STA buf_it_ptr
        LDA #>buf_iters_hr
        STA buf_it_ptr+1
        LDY #0           ; Current tile pixel [0..32].
nxt_tile_line_MC:
        LDA #$00         ; Preset line all black.
        TAX
        STA (bmp_ptr,X)
        LDX #3           ; Tile line pixel countdown [3..0]. We use this also as a shift counter.
nxt_tile_pix_MC:
        ; Fetch pixel iters and convert to color.
        LDA (buf_it_ptr),Y
    .if BUILD_VIC20
        ; VIC-20: Direct map iters to color.
        AND #$03         ; Mod4.
    .else
        ; All other machines: Find best match.
        AND #$0F         ; Mod16.
        ; If black, pass-through as background color.
        BEQ found_conversion
        ; Search for exact match in histogram.
        CMP h_top4_idx   ; Compare with 1st most used.
        BNE +
        LDA #%01
        JMP found_conversion
+       CMP h_top4_idx+1 ; Compare with 2st most used.
        BNE +
        LDA #%10
        JMP found_conversion
+       CMP h_top4_idx+2 ; Compare with 3rd most used.
        BNE +
        LDA #%11
        JMP found_conversion
        ; No exact match. Just use lower 2 bits (but avoid black).
+       AND #%11
        BNE found_conversion
        LDA #%01         ; If %00 (black), then make it %01.
    .endif
found_conversion:
        STX tmp_X        ; Save X.
        CPX #0
        BEQ done_adjust
-       ASL
        ASL
        DEX
        BNE -            ; Keep adjusting mask.
done_adjust:
        LDX #0
        ORA (bmp_ptr,X)
        STA (bmp_ptr,X)  ; Update tile bitmap line.
        INY              ; Point to next pixel.
        LDX tmp_X        ; Restore X (line pixel countdown).
        DEX
        BPL nxt_tile_pix_MC
        ; End of tile bitmap line.
        INC bmp_ptr      ; Inc bitmap ptr.
        BNE +
        INC bmp_ptr+1
+        
        CPY buf_tile_size
        BNE nxt_tile_line_MC
    .if BUILD_VIC20
        ; On VIC-20 our bitmap is represented by 16-line chars, so skip next 8 lines.
        LDA bmp_ptr
        CLC
        ADC #8
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+        
    .endif
.endif
        RTS

tmp_A: .byte 0
tmp_X: .byte 0


.if BUILD_ATARI
;------------- Render tile (ATARI version) -------------
; Render a hi-res tile in ATARI mode F.1 (2x8 pixels per tile).
; Note that this is a linear format (40 bytes per line).
; 
render_tile_ATARI:
        ; Save bmp_ptr
        LDA bmp_ptr
        PHA
        LDA bmp_ptr+1
        PHA
        ; Simply use the 2x8 iters buffer as colors (Mod16).
        ; bmp_ptr contains the current tile bitmap line (2 pixels, 4 bits each).
        ; buf_it_ptr is the per-pixel iterations buffer.
        LDA #<buf_iters_hr
        STA buf_it_ptr
        LDA #>buf_iters_hr
        STA buf_it_ptr+1
        LDY #0           ; Current tile pixel [0..16].
        LDX #0
nxt_tile_line_A:
        ; Each tile line contains two pixels.
        ; Fetch pixel iters and convert to color.
        LDA (buf_it_ptr),Y
        ROL
        ROL
        ROL
        ROL
        AND #$F0
        STA (bmp_ptr,X)
        INY
        LDA (buf_it_ptr),Y
        AND #$0F         ; Mask.
        ORA (bmp_ptr,X)
        STA (bmp_ptr,X)
        INY
        ; End of tile bitmap line (2 pixels).
        CLC
        LDA bmp_ptr
        ADC num_tiles_w   ; This is a linear buffer, skip down one line.
        STA bmp_ptr
        LDA bmp_ptr+1
        ADC #0
        STA bmp_ptr+1
        CPY #HIRES_TILE_W*HIRES_TILE_H
        BNE nxt_tile_line_A
        ; Retreive bmp_ptr.
        PLA
        STA bmp_ptr+1
        PLA
        STA bmp_ptr
        JSR bmp_to_next_tile
        RTS
.endif

.if BUILD_BEEB
;------------- Render tile (BBC Micro version) -------------
; Render a hi-res tile in Mode 2.
; We use a 4x8 tile format.
; The BBC Micro uses 8 colors per pixel, plus a useless flash attribute.
; Each byte encodes 2 horizontal pixels (fbgr and FBGR) in bit-interleaved format: fFbBgGrR.
; For each 4x8 cell, bytes are rendered on screen like this ("byte_offset=format"):
;   00=fFbBgGrR  08=fFbBgGrR
;   01=fFbBgGrR  09=fFbBgGrR
;   02=fFbBgGrR  0a=fFbBgGrR
;   03=fFbBgGrR  0b=fFbBgGrR
;   04=fFbBgGrR  0c=fFbBgGrR
;   05=fFbBgGrR  0d=fFbBgGrR
;   06=fFbBgGrR  0e=fFbBgGrR
;   07=fFbBgGrR  0f=fFbBgGrR
;
; Our algorithm renders two half-tiles (first 2x8 left, and then 2x8 right).
;
render_tile_BEEB:
        ; Simply use the 4x8 iters buffer as colors (Mod8).
        ; bmp_ptr contains the current half-tile bitmap byte (2 pixels, 4 bits each).
        ; buf_it_ptr is the per-pixel iterations buffer.
        
        LDA #<buf_iters_hr
        STA buf_it_ptr
        LDA #>buf_iters_hr
        STA buf_it_ptr+1
        LDA #2
        STA halves_countdown     ; Tile halves countdown (2 halves).
        LDY #0                   ; Current tile pixel in iters buffer [0..32].
nxt_halftile_BEEB:      
        LDA #8
        STA line_countdown       ; Tile line countdown.
nxt_tile_byte_BEEB:
        ; Each bitmap byte contains 2 pixels (left and right).
        ; Alas, color bits are interleaved, so we use a table to interleave them.
        LDA (buf_it_ptr),Y          ; Get left pixel.
        AND #$07                    ; Only 8 colors available.
        INY
        TAX
        LDA mode2_solid_colors,X    ; Convert left-pixel to interleaved using table.
        AND #$AA
        STA tmp_conv
        LDA (buf_it_ptr),Y          ; Get right pixel.
        AND #$07                    ; Only 8 colors available.
        INY
        TAX
        LDA mode2_solid_colors,X    ; Convert right-pixel to interleaved using table.
        AND #$55
        ORA tmp_conv                ; Interleave left and right pixels.
        LDX #0
        STA (bmp_ptr,X)             ; Set bitmap byte.
        INC bmp_ptr
        BNE +
        INC bmp_ptr+1
+       INY                         ; Skip two pixels (we are rendering half-tile in this inner loop).
        INY
        DEC line_countdown
        BNE nxt_tile_byte_BEEB
        ; Half-tile done.
        DEC halves_countdown
        BEQ done_tile_BEEB
        ; Get back to right-tile pixels.
        TYA
        SEC
        SBC #30
        TAY
        BNE nxt_halftile_BEEB       ; NOTE: This is actually an unconditional relative branch.
done_tile_BEEB:

        RTS
.endif

halves_countdown:   .byte 0
line_countdown:     .byte 0
tmp_conv:           .byte 0    


;==============================================================

; On VIC-II and TED machines, we need to check if we overlapped bitmap memory (and code will be trashed).
.if BUILD_C64 || BUILD_C128 || BUILD_TED
    .if * >= $2000
        .error "BITMAP MEM OVERLAP"
    .endif
.endif


.if BUILD_C128    
;==============================================================
; C128 VDC ROUTINES - This can overlap bitmap mem.
; WARNING: PLACE AT THE END OF ALL SUBS TO ALLOW OTHER SUBS TO STAY BELOW $2000 !!!!!!
;          These routines are to be used with the VDC, so we don't care if the code goes over the VIC-II bitmap area $2000-$3FFF.
;
;------------- VDC reg read -------------
; Inputs
;   X: Register number
; Outputs:
;   A: Value

vdc_reg_read:
        STX $D600        ; VDC register index.
-       BIT $D600
        BPL -
        LDA $D601        ; VDC register data.
        RTS

;------------- VDC reg write -------------
; Inputs
;   X: Register number
;   A: Value

vdc_reg_write:
        STX $D600        ; VDC register index.
-       BIT $D600
        BPL -
        STA $D601        ; VDC register data.
        RTS


;------------- VDC mem read -------------
; Read a byte from VDC VRAM.
; Inputs
;   X: VRAM addr [LO]
;   Y: VRAM addr [HI]
; Outputs: A: read value.
; Clobbered: [none]
;
vdc_mem_read:
        LDA #$12         ; VDC mem addr HI
        STA $D600
-       BIT $D600
        BPL -
        STY $D601        ; Set addr HI.

        LDA #$13         ; VDC mem addr LO
        STA $D600
-       BIT $D600
        BPL -
        STX $D601        ; Set addr LO.

        LDA #$1F         ; VDC data register.
        STA $D600
-       BIT $D600
        BPL -
        LDA $D601        ; Set mem value.

        RTS

;------------- VDC mem write -------------
; Write a byte to VDC VRAM.
; Inputs:
;   A: Byte to write.
;   X: VRAM addr [LO]
;   Y: VRAM addr [HI]
; Outputs: [none]
; Clobbered: [none]
;
vdc_mem_write:
        PHA
        
        LDA #$12         ; VDC mem addr HI
        STA $D600
-       BIT $D600
        BPL -
        STY $D601        ; Set addr HI.

        LDA #$13         ; VDC mem addr LO
        STA $D600
-       BIT $D600
        BPL -
        STX $D601        ; Set addr LO.

        LDA #$1F         ; VDC data register.
        STA $D600
-       BIT $D600
        BPL -
        PLA
        STA $D601        ; Set mem value.

        RTS


;------------- VDC mem fill -------------
; Fill VDC VRAM (hardware blit).
; Up to 256 bytes can be filled with one call.
; Inputs:
;   A: Byte to write.
;   blt_dst[LO][HI]: Fill start address in VDC memory.
;   blt_size: Fill size - 1 (bytes).
;
; Outputs: [none]
; Clobbered: [none]
;
vdc_mem_fill:
        PHA
        PHA

        ; Set block start address.
        
        LDA #$12         ; VDC mem addr HI
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_dst+1
        STA $D601        ; Set addr HI.

        LDA #$13         ; VDC mem addr LO
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_dst
        STA $D601        ; Set addr LO.

        ; Set fill value.

        LDA #$1F         ; VDC data register.
        STA $D600
-       BIT $D600
        BPL -
        PLA
        STA $D601        ; Set mem value.

        ; Write a 0 to R$18 "VSS" bit 7, to select the Block-Write mode.
        LDA #$18         ; VDC "VSS" register.
        STA $D600
-       BIT $D600
        BPL -
        LDA $D601
        AND #$7F         ; Clear bit 7 to select Fill op.
        STA $D601

        ; Write the fill size - 1 to to R$1E "WC", to start the fill.
        LDA #$1E         ; VDC "WC" register.
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_size
        STA $D601        ; Set blit size.

        ; After the fill is completed, R$12/R$13 will contain the last written addr + 1.
        PLA              ; Restore A.
        RTS

;------------- VDC mem copy -------------
; Copy VDC VRAM (hardware blit).
; Up to 256 bytes can be copied with one call.
; Inputs:
;   blt_src[LO][HI]: Copy source start address in VDC memory.
;   blt_dst[LO][HI]: Copy destination start address in VDC memory.
;   blt_size: Copy size - 1 (bytes).
;
; Outputs: [none]
; Clobbered: [none]
;
vdc_mem_copy:
        PHA

        ; Set block src start address.
        
        LDA #$12         ; VDC mem addr HI
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_dst+1
        STA $D601        ; Set addr HI.

        LDA #$13         ; VDC mem addr LO
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_dst
        STA $D601        ; Set addr LO.

        ; Write a 1 to R$18 "VSS" bit 7, to select the Block-Copy mode.

        LDA #$18         ; VDC "VSS" register.
        STA $D600
-       BIT $D600
        BPL -
        LDA $D601
        ORA #$80         ; Set bit 7 to select Copy op.
        STA $D601

        ; Set block dst start address.
        
        LDA #$20         ; VDC block source addr HI
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_src+1
        STA $D601        ; Set addr HI.

        LDA #$21         ; VDC block source addr HI
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_src
        STA $D601        ; Set addr LO.


        ; Write the copy size - 1 to to R$1E "WC", to start the copy.

        LDA #$1E         ; VDC "WC" register.
        STA $D600
-       BIT $D600
        BPL -
        LDA blt_size
        STA $D601        ; Set blit size. 

        ; After the fill is completed, R$12/R$13 will contain the last written addr + 1.
        PLA              ; Restore A.
        RTS


blt_src:    .word 0
blt_dst:    .word 0
blt_size:   .byte 0


;------------- VDC clear screen -------------
; Character mode (lo-res) or bitmap mode (hi-res) CLS routine.
; This uses VDC hardware acceleration.
;
; Inputs:
;   A: Byte to write to attributes (or set to $FF to skip writing attributes).
;   Y: Byte to write to char/bitmap.
;
; Clobbered: A, Y
;
vdc_cls:
        PHA                 ; Save attrib value.
        TYA
        PHA                 ; Save char/bitmap value.


        ; Clear screen matrix.
        
        LDA #$FF
        STA blt_size
        LDA #$00
        STA blt_dst+1
        STA blt_dst
        ; Preset lores.
        LDY #$10            ; lores [$0000-$0FFF]
        LDA res
        BEQ +
        ; Instead, it's hires.
        LDY #$40            ; hires [$0000-$3FFF]
+       PLA                 ; Get char/bitmap fill value.
-       JSR vdc_mem_fill
        INC blt_dst+1
        DEY
        BNE -
        
        ; Clear attribs ?
        PLA
        CMP #$FF
        BEQ dont_clear_attribs
        ; Do clear attribs. Push attrib value back in stack.
        PHA

        ; Clear attribs.
        LDA #$00
        STA blt_dst
        LDA res             ; Check lores/hires.
        BNE cla_hr
        ; lores [$1000-$1FFF]
        LDA #$10
        STA blt_dst+1
        TAY                 ; Clear $10 pages.
        BNE v_do_cla        ; Branch always
cla_hr: ; hires [$4000-$5FFF]
        LDA #$40
        STA blt_dst+1
        LDY #$20
v_do_cla:
        PLA                 ; Get attrib fill value.
-       JSR vdc_mem_fill
        INC blt_dst+1
        DEY
        BNE -

dont_clear_attribs:
        RTS               ; Return


;------------- VDC wait until VBlank -------------
; Wait till end of frame.
;
vdc_wait_vb:
-       LDA $D600
        AND #$20
        BEQ -
        RTS

;------------- VDC set low resolution (80x50) -------------
; This mode works with 16KB VRAM.
; Screen:     $0000-$0FFF
; Attributes: $1000-$1FFF
; Chars def:  $2000-$3FFF (this is the default and not set here).
;
vdc_set_lores:
        ; Wait for VBlank to minimize glitch.
        JSR vdc_wait_vb
        ; Setup 80x50 chars mode (each char is 8x4).
        ; NOTE: This has not been tested on a CRT (only in VICE).
        LDX #$09            ; VDC[CTV]: Rasterlines per char row. (Default 7).
        LDA #$03
        JSR vdc_reg_write

        LDX #$17            ; VDC[CDV]: Char height rasterlines - 1. (Default 8). Set equal to R$09 for no vertical inter-char spacing.
        JSR vdc_reg_write

        LDX #$0C            ; VDC[DSh]: Display start HI. (Default $00).
;JSR vdc_reg_read
;JSR print_A_hex 
        LDA #$00
        JSR vdc_reg_write
        LDX #$0D            ; VDC[DSl]: Display start LO. (Default $00).
        LDA #$00
        JSR vdc_reg_write

        LDX #$04            ; VDC[VT]: Vertical Total (char rows - 1). (Default PAL=38, NTSC=32).
        LDA #76             ; PAL
        JSR vdc_reg_write
        
        LDX #$05            ; VDC[VA]: Vertical Adjust (rasterlines) (Default 0).
        LDA #0
        JSR vdc_reg_write
        
        LDX #$06            ; VDC[VD]: Vertical Displayed (visible char rows). (Default 25).
        LDA #50
        JSR vdc_reg_write
        
        LDX #$07            ; VDC[VP]: Vertical Sync Position (Default PAL=32, NTSC=29).
        LDA #64             ; PAL
        JSR vdc_reg_write
        
        ; Set attributes at $1000.
        LDX #$14            ; VDC[AAh]: Attribute Address HI (Default=$08).
        LDA #$10
        JSR vdc_reg_write
        LDX #$15            ; VDC[AAl]: Attribute Address LO (Default=$00).
        LDA #$00
        JSR vdc_reg_write

        ; Deactivate bitmap mode.
        LDX #$19            ; VDC[HSS]: Bitmap [7]; Attributes [6]; Gap fill [5]; Pixel clock (40 Col) [4]; hor smooth scroll.
        JSR vdc_reg_read
        AND #$7F            ; Disable bitmap.
        ORA #$40            ; Enable attributes.
        JSR vdc_reg_write        
        
        ; Set all pixels to 1 for the '@' char (code $00).
        ; Note that we use 8x4 chars in VDC lores.
        ; Font starts at $2000.
        LDY #$20            ; Y: addr [HI]
        LDX #$00            ; X: addr [LO]
        LDA #$FF
-       JSR vdc_mem_write
        INX
        CPX #$04            ; Only 4 lines to set.
        BNE -
        
        LDA #$0F            ; Attribute (white).
        LDY #$00            ; Char ("@").
        JSR vdc_cls

        RTS

;------------- VDC set high resolution (160x100) -------------
; This mode requires 64KB VRAM.
;
; Bitmap:     $0000-$3E80
; Attributes: $4000-$5F40
;
; Clobbered: A, X, Y
;
vdc_set_hires:
        ; Wait for VBlank to minimize glitch.
        JSR vdc_wait_vb

        ; Setup 160x100 bitmap mode (each attribute is 8x2, used only for fg/bg attributes).
        ; NOTE: This has not been tested on a CRT (only in VICE).
        
        LDX #$09            ; VDC[CTV]: Rasterlines - 1 per char row. (Default 7).
        LDA #$01
        JSR vdc_reg_write

        LDX #$17            ; VDC[CDV]: Char rasterlines - 1. (Default 8). Must be <= R9. Set equal to R$09 for no vertical inter-char spacing.
        JSR vdc_reg_write
        
        ; Set bitmap starting at $0000.
        LDX #$0C            ; VDC[DSh]: Display start HI. (Default $00).
        LDA #$00            ; $00 [HI]
        JSR vdc_reg_write
        LDX #$0D            ; VDC[DSl]: Display start LO. (Default $00).
        LDA #$00            ; $00 [LO]
        JSR vdc_reg_write

        LDX #$04            ; VDC[VT]: Vertical Total (char rows - 1). (Default PAL=38, NTSC=32).
        LDA #152
        JSR vdc_reg_write
        
        ; R$05: The number of scan lines added to the end of the frame for fine adjustment of the vertical sync rate.
        LDX #$05            ; VDC[VA]: Vertical Adjust (rasterlines) (Default 0).
        LDA #3              ; This seems to match the lores position (at least on the VICE emu).
        JSR vdc_reg_write
        
        LDX #$06            ; VDC[VD]: Vertical Displayed (visible char rows). (Default 25).
        LDA #100    
        JSR vdc_reg_write
        
        LDX #$07            ; VDC[VP]: Vertical Sync Position (Default PAL=32, NTSC=29). Must be > R6.
        LDA #128
        JSR vdc_reg_write
        
        ; Set attributes at $4000.
        LDX #$14            ; VDC[AAh]: Attribute Address HI (Default=$08).
        LDA #$40
        JSR vdc_reg_write
        LDX #$15            ; VDC[AAl]: Attribute Address LO (Default=$00).
        LDA #$00
        JSR vdc_reg_write
        
        ; Activate bitmap mode.
        LDX #$19            ; VDC[HSS]: Bitmap [7]; Attributes [6]; Gap fill [5]; Pixel clock (40 Col) [4]; hor smooth scroll.
        JSR vdc_reg_read
        ORA #$C0            ; Enable both bitmap and attributes.
        JSR vdc_reg_write
        
        ; Copy lores attribs [$1000-$1FFF] to hires attribs [$4000-$5FFF].
        
        LDA #$00
        STA blt_src
        STA blt_dst
        LDA #$10
        STA blt_src+1
        LDA #$40
        STA blt_dst+1
        ; 50 attribute lines of 80 chars each must be expanded 2x vertically.
        LDA #80
        STA blt_size
        LDY #50
a_lr2hr:
        LDX #2              ; Expand 2x
exp4x:  JSR vdc_mem_copy
        LDA blt_dst
        CLC
        ADC #80
        STA blt_dst
        BCC +
        INC blt_dst+1
+       DEX
        BNE exp4x
        ; Go to next lores attr row.
        LDA blt_src
        CLC
        ADC #80
        STA blt_src
        BCC +
        INC blt_src+1
+       DEY
        BNE a_lr2hr

        ; Clear bitmap to $00 (all background). The Mandelbrot render fills it
        ; top-to-bottom; starting from black is more natural than the previous
        ; $FF (all foreground = bright "white" area before the render reaches it).
        LDA #$FF            ; Set A=$FF so vdc_cls does not touch attributes.
        LDY #$00            ; Set bitmap to $00.
        JSR vdc_cls
     
        RTS


;------------- Setup Mandelbrot pass using VDC rendering -------------
;
vdc_setup_pass:
        ; VDC common.
        LDA #0
        STA screenw+1
        STA screenh+1    
        ; Enable iters buffer.
        LDA #$01
        STA enable_buf_it
        
        ; Check if VDC hi-res.
        LDA res
        BNE vdc_hi_res

vdc_lo_res:
        LDA #1
        STA num_tiles_w
        STA num_tiles_h
        LDA #80
        STA screenw
        STA tilew
        LDA #50
        STA screenh
        STA tileh
        ; Point to start of VDC attributes.
        LDX #$12          ; VDC mem addr HI
        LDA #$10
        JSR vdc_reg_write
        INX               ; VDC mem addr LO
        LDA #$00
        JSR vdc_reg_write
        RTS

vdc_hi_res:
        ; VDC hi-res (one single 160x100 tile).
        LDA #80
        STA num_tiles_w
        LDA #50
        STA num_tiles_h
        LDA #160
        STA screenw
        LDA #100
        STA screenh
        LDA #2
        STA tilew
        LDA #2
        STA tileh
        LDA #2*2 ; Pixels per tile.
        STA buf_tile_size
        LSR incx+1
        ROR incx
        LSR incy+1
        ROR incy
        ; Point bitmap to start of VDC mem ($0000).
        LDA #$00
        STA bmp_ptr
        LDA #$00
        STA bmp_ptr+1
        ; Point VDC attr to start of VDC attribs ($4000).
        LDA #$00
        STA vdc_attr_ptr
        LDA #$40
        STA vdc_attr_ptr+1
        RTS
        

;------------- Render a Mandelbrot tile (2x2) with the VDC -------------
; After this, bmp_ptr needs to point to the next tile.
;        
render_tile_VDC:
        LDX bmp_ptr
        LDY bmp_ptr+1
        LDA #4
        STA vdc_row_count
        ; Set all 4 bytes of the tile to #$0F (background, foreground).
vdc_set_tile_bmp:
        LDA #$0F            ; Value (always $0F): 4 pixels off, 4 pixels on.
        JSR vdc_mem_write
        TXA
        CLC
        ADC #80
        TAX
        BCC +
        INY
+       DEC vdc_row_count
        BNE vdc_set_tile_bmp
        
        ; Now set attributes.
        LDX vdc_attr_ptr
        LDY vdc_attr_ptr+1

        LDA buf_iters_hr+0
        ASL
        ASL
        ASL
        ASL
        STA vdc_tmp
        LDA buf_iters_hr+1
        AND #$0F
        ORA vdc_tmp         ; Attribute value to write (two colors, one per nibble).
    ;LDA #$3F
        JSR vdc_mem_write

        TXA
        CLC
        ADC #80
        TAX
        BCC +
        INY
+
        LDA buf_iters_hr+2
        ASL
        ASL
        ASL
        ASL
        STA vdc_tmp
        LDA buf_iters_hr+3
        AND #$0F
        ORA vdc_tmp         ; Attribute value to write (two colors, one per nibble).
    ;LDA #$F3
        JSR vdc_mem_write
        
        ; Point to the next tile.
        INC bmp_ptr
        BNE +
        INC bmp_ptr+1
+       ; Point to the next tile.
        INC vdc_attr_ptr
        BNE +
        INC vdc_attr_ptr+1
+        
        RTS
 
vdc_tmp:       .byte 0
vdc_row_count: .byte 0
vdc_attr_ptr:  .word 0
        
.endif ; BUILD_C128    
    
    
;------------- Mandelbrot calculation -------------
.if BUILD_BEEB
        * = $1C00
.elif BUILD_VIC20
        * = $3000
.elif BUILD_PET
        * = $1200
.elif BUILD_B128
        * = $2000
.else
        * = $4000
.endif

Mandelbrot:
        FPREC = 11          ; Fixed-point precision.

        ; Max iters. 16-color targets cap at 16 (AND #$0F in histogram and
        ; color lookup). Contour mode uses 32: each iter step is a visible
        ; contour band, and cardioid + period-2 fast-tests cover the in-set
        ; so the per-iter cost is small.
.if BUILD_HIRES_CONTOUR
        LDA #32
.else
        LDA #16
.endif
        STA max_iter


.if BUILD_VIC20
        ; Default coordinates.
        start_ax = -2.0*(1<<FPREC)
        ; Center vertically for 200 lines displays.
        start_ay =  1.15*(1<<FPREC)
.elif BUILD_BEEB
        ; Center vertically for 256 lines displays.
        start_ax = -2.2*(1<<FPREC)
        ; Center vertically for 200 lines displays.
        start_ay =  1.25*(1<<FPREC)
.elif BUILD_C64 | BUILD_C128
        ; C64 multicolor 160×200, contour 320×200, and C128 VIC-IIe 160×200:
        ; no centroid adjustment applied, so start_ay must equal exactly
        ; 100 * incy_hr = 100 * (192/8)/2048 = 1.171875 to center y=0
        ; vertically on screen. (C128 VDC mode uses its own setup path.)
        start_ax = -2.2*(1<<FPREC)
        start_ay = 1.171875*(1<<FPREC) ; = 2400 in Q5.11
.else   ; All other machines.
        ; Default coordinates.
        start_ax = -2.2*(1<<FPREC)
        ; Center vertically for 200 lines displays.
        start_ay =  1.25*(1<<FPREC)
.endif


      
        
        LDA #<start_ax
        STA ax
        LDA #>start_ax
        STA ax+1
    
        LDA #<start_ay
        STA ay
        LDA #>start_ay
        STA ay+1
    
        ; Set default lo-res increments, depending on mode.
        LDA #0
        STA incx_lr+1
        STA incy_lr+1    
        LDA mode
        AND #MODE_VIC | MODE_KAWARI | MODE_BEEB
        BEQ +
        LDA #192            ; Must be a multiple of 8 to keep lo-res and hi-res aligned.
        STA incx_lr
        STA incy_lr
.if BUILD_VIC20
        ;ASL incx_lr        ; Double that for VIC-20 char aspect-ratio.
        LDA #248            ; Must be a multiple of 8 to keep lo-res and hi-res aligned.
        STA incx_lr
        LDA #224
        STA incy_lr
.endif        
        JMP done_incs
+       LDA mode
        CMP #MODE_VDC
        BNE +
        LDA #96            ; Must be a multiple of 8 to keep lo-res and hi-res aligned.
        STA incx_lr
        STA incy_lr
        JMP done_incs
+       ; Unknown/unhandled mode.
done_incs:


first_pass:
.if BUILD_BENCHMARK & !BUILD_C128
        JSR benchmark_start
.endif
.if BUILD_HIRES_CONTOUR
        ; Contour mode: skip lo-res pass, go directly to hi-res.
        LDA #1
        STA res
.else
        ; First pass is lo-res.
        LDA #0
        STA res
.endif
        LDA #0
        STA buf_tile_size ; 0 means screen size or none (depending on video mode).

calc_image:
        LDA #0
.if !BUILD_HIRES_CONTOUR
        STA res           ; Reset to lo-res at start of each image.
.endif
        STA tilex
        STA tiley
        ; Configure graphics subystem.
        JSR apply_mode
        JSR clear_screen

nxt_pass:
        ; Preset incs for lo-res.
        LDA incx_lr
        STA incx
        LDA incx_lr+1
        STA incx+1
        LDA incy_lr
        STA incy
        LDA incy_lr+1
        STA incy+1
        ; Reset tile num.
        LDA #0
        STA tile_num
        STA tile_num+1
        STA screenw+1
        STA screenh+1        
        ; Handle mode-dependent params.
        LDA mode
        AND #MODE_VIC | MODE_KAWARI | MODE_BEEB ; Check for VIC2 and similar chips.
        BNE +
        JMP no_VIC2ish_setup

      
        ;------ VIC2
+       LDA res
        BNE hi_res
        ; Lo-res. One single (LORES_W x LORES_H) tile.
        LDA #1
        STA num_tiles_w
        STA num_tiles_h
        LDA #LORES_W
.if BUILD_PET | BUILD_B128
        LDX cbm_columns
        CPX #80
        BNE +
        ASL
        CLC
        ROR incx
+        
.endif        
        STA screenw
        STA tilew
        LDA #LORES_H
        STA screenh
        STA tileh
        ; In low-res we might want to also set Screen RAM (e.g. PET machines).
        LDA #<SCR_RAM
        STA sram_ptr
        LDA #>SCR_RAM
        STA sram_ptr+1
        ; In lo-res we write directly to Color RAM after calculating a pixel.
        LDA #<COL_RAM
        STA cram_ptr
        LDA #>COL_RAM
        STA cram_ptr+1
        JMP first_tile

hi_res:
        ; Hi-res mode second-pass.
        ; Set tile width and height.
        LDA #<BITMAP_START
        STA bmp_ptr
        LDA #>BITMAP_START
        STA bmp_ptr+1
        LDA #<HIRES_W       ; lo byte (handles both 160 and 320)
        STA screenw
        LDA #>HIRES_W       ; hi byte (0 for 160, 1 for 320)
        STA screenw+1
        LDA #HIRES_H
        STA screenh
        LDA #0
        STA screenh+1
        LDA #LORES_W
        STA num_tiles_w
        LDA #LORES_H
        STA num_tiles_h
        LDA #HIRES_TILE_W
        STA tilew
        LDA #HIRES_TILE_H
        STA tileh
        LDA #HIRES_TILE_W*HIRES_TILE_H ; Pixels per tile.
        STA buf_tile_size
        ; Update incs for second-pass.
        ; incx: lo-res has LORES_W columns, hi-res has HIRES_W pixels.
        ; Need to divide by (HIRES_W / LORES_W) = HIRES_TILE_W rotations.
.if BUILD_ATARI
        LDX #1        ; Atari: HIRES_TILE_W=2, divide by 2.
.elif BUILD_HIRES_CONTOUR
        LDX #3        ; Contour: HIRES_TILE_W=8, divide by 8.
.else
        LDX #2        ; Multicolor: HIRES_TILE_W=4, divide by 4.
.endif
-       CLC
        ROR incx+1
        ROR incx
        DEX
        BNE -
        LDX #3        ; Rotate thrice to divide lo-res incy by 8.
-       CLC
        ROR incy+1
        ROR incy
        DEX
        BNE -
        LDA incy
        BNE +
        ; Zoomed-in too much, set minimum incs.
        LDA #1
        STA incy
        ASL
        STA incx
+    
.if !BUILD_C64 & !BUILD_C128
        ; Sub|add half a lo-res pixel to ax|ay so the previously calculated
        ; lo-res iter aligns with the centroid of the corresponding hi-res
        ; tile. C64 and C128 VIC-IIe skip this: the centroid shift scales
        ; with incy_lr and shows as vertical drift when zooming.
        ; start_ay = 1.171875 already centres y=0 on those targets.
        LDA incx_lr
        TAX
        CLC
        ROR incx_lr
        LDA ax
        SEC
        SBC incx_lr
        STA ax
        LDA ax+1
        SBC #0
        STA ax+1
        STX incx_lr
        LDA incy_lr
        CLC
        ROR
        CLC
        ADC ay
        STA ay
        LDA ay+1
        ADC #0
        STA ay+1
.endif
        JMP first_tile

no_VIC2ish_setup:

.if BUILD_C128
        LDA mode
        CMP #MODE_VDC
        BNE +
        ;------ VDC
        JSR vdc_setup_pass
+
.endif ; BUILD_C128

first_tile:
        LDA ax
        STA t_ax
        LDA ax+1
        STA t_ax+1
        LDA ay
        STA t_ay
        LDA ay+1
        STA t_ay+1

nxt_tile:       ; A tile is the entire screen if not using a tiled hi-res video mode.
        ; Check if we can skip this tile.
        LDA res
        BEQ no_skip         ; Can't skip in lo-res.

no_skip:
        LDA #0              ; Reset cur pixel pos in tile.
        STA pixelx
        STA pixely
    
        ; (cx, cy) is our current point to calculate.
        ; Start with upper left point of tile (t_ax, t_ay).
        LDA t_ax
        STA cx
        LDA t_ax+1
        STA cx+1
        
        LDA t_ay
        STA cy
        LDA t_ay+1
        STA cy+1
    
        ; Setup the iterations buffer for this tile.
.if BUILD_HIRES_CONTOUR
        ; Contour mode is always hi-res (res=1); lo-res branch never executes.
        LDA #<buf_iters_hr
        STA buf_it_ptr
        LDA #>buf_iters_hr
        STA buf_it_ptr+1
.else
        LDA res
        BNE +
        LDA #<buf_iters_lr
        STA buf_it_ptr
        LDA #>buf_iters_lr
        STA buf_it_ptr+1
        JMP done_it_buf
+       LDA #<buf_iters_hr
        STA buf_it_ptr
        LDA #>buf_iters_hr
        STA buf_it_ptr+1
done_it_buf:
.endif

.if BUILD_MARIANI_SILVER_STRIPE & BUILD_C64
        LDA res
        BEQ ms_str_skip
.if BUILD_HIRES_CONTOUR
        ; Contour (320×200): 40 cells × 8 px/cell. We use a NARROWER 40-px
        ; stripe (5 tiles wide) instead of half-row 160-px. Each tile-row
        ; contains 8 stripes (tilex 0,5,10,15,20,25,30,35 trigger a build);
        ; the local index within a stripe (0..4) is tracked in stripe_idx.
        ; Narrower stripe means smaller cx range per border trace, more
        ; locally uniform iter values, and avoids the wide-stripe MS bugs.
        LDA tilex
        BNE +                    ; reset stripe_idx at start of tile row
        STA stripe_idx
+       LDA stripe_idx
        BNE ms_c40_extract       ; not first tile in stripe → just extract
        JSR ms_render_stripe_c40 ; first tile in stripe (idx==0): build stripe
ms_c40_extract:
        LDA stripe_idx
        STA stripe_cellx
        JSR ms_extract_cell_from_stripe_contour
        ; Increment stripe_idx; wrap at 5.
        INC stripe_idx
        LDA stripe_idx
        CMP #5
        BNE +
        LDA #0
        STA stripe_idx
+       JMP end_tile
.else
        ; Multicolor: 40-px stripe (10 cells × 4 px). Same as contour but with
        ; 10-tile wrap. Replaces the previous 160-px (full-row) stripe, which
        ; produced visible 8×160 single-color artifacts when zoomed in due to
        ; MS top-level uniformity false-positives. Narrower stripe means
        ; smaller cx range, fewer false-positives, and any remaining artifact
        ; is only 8×40 in size.
        LDA tilex
        BNE +                    ; reset stripe_idx at start of tile row
        STA stripe_idx
+       LDA stripe_idx
        BNE ms_mc_extract        ; not first tile in stripe → just extract
        JSR ms_render_stripe_c40 ; first tile in stripe (idx==0): build stripe
ms_mc_extract:
        LDA stripe_idx
        STA stripe_cellx
        JSR ms_extract_cell_from_stripe
        ; Increment stripe_idx; wrap at 10.
        INC stripe_idx
        LDA stripe_idx
        CMP #10
        BNE +
        LDA #0
        STA stripe_idx
+       JMP end_tile
.endif
ms_str_skip:
.endif

; Calculate current point (cx, cy).
calc_point:
    ;INC $D020
        LDA #0   ; Reset iteration counter.
        STA iter
        STA zx   ; Reset (zx, zy)
        STA zx+1
        STA zy
        STA zy+1

; ---- Cardioid + period-2 bulb quick tests (call out-of-line) ----
; Both routines JMP directly to found_color_black if the point is inside;
; return normally otherwise. Bulb is tested first because its bbox is narrow
; (most points reject in just a few cycles).
; NOTE: cardioid is C64-only for now — it's ~160 bytes placed at $0C00 in
; the C64 BASIC-stub-to-bitmap gap. Other targets have different memory
; layouts so cardioid placement needs separate per-target work.
; Bulb test enabled on all squares-table-using targets (incl. C128).
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_ATARI | BUILD_B128
        JSR test_period2_bulb
.endif
.if BUILD_C64
        JSR test_cardioid
.endif

nxt_iter:
        JSR check_userinput
        BNE no_recalc    ; No recalculation needed.
        ; User input requires image recalc. 
        JMP first_pass
no_recalc:
        ;   zx = zx + cx
        CLC     
        LDA zx  
        ADC cx  
        STA zx  
        LDA zx+1
        ADC cx+1
        STA zx+1
    
        ;   zy = zy + cy
        CLC     
        LDA zy  
        ADC cy  
        STA zy  
        LDA zy+1
        ADC cy+1
        STA zy+1
    
zx2_sw:    
        LDA zx
        STA x0
        STA y0
        LDA zx+1
        STA x1
        STA y1
.if BUILD_VIC20 | BUILD_PET | BUILD_BEEB
        ; These have not enough mem for squares table.
        JSR multiply_Q5_11_signed ; [z1..z2] = zx*zx
.else
        ; Use squares table.
        JSR square_Q5_11
.endif        
        LDA z1
        STA zx2
        LDA z2
        STA zx2+1
zx2_done:
    
        ; zy2 = zy * zy → keep result in z1, z2 (avoid redundant zy2 store).
        LDA zy
        STA x0
        STA y0
        LDA zy+1
        STA x1
        STA y1
.if BUILD_VIC20 | BUILD_PET | BUILD_BEEB
        ; These have not enough mem for squares table.
        JSR multiply_Q5_11_signed ; [z1..z2] = zy*zy
.else
        JSR square_Q5_11           ; [z1..z2] = zy*zy
.endif
        ; Skip "STA zy2 / STA zy2+1" — z1/z2 hold zy² and stay
        ; valid until we've consumed them in both the divergence check and
        ; the zx-update below (no intervening writes touch z1/z2).

        ; Check for divergence (zx2 + zy2 >= 4.000 → $2000 in Q5.11).
        ; Add low bytes for carry, then check high byte alone.
        ; Low-byte addition kept (was marked "Maybe not needed"
        ; but it computes the carry into the high-byte addition; without it
        ; we'd miss divergence on points where low bytes overflow).
        CLC
        LDA zx2
        ADC z1                     ; (was: ADC zy2)
        LDA zx2+1
        ADC z2                     ; (was: ADC zy2+1)
        CMP #$20                   ; Just check high byte.
        BCC +                      ; BLT
        JMP found_color            ; Early exit (not black if >= 4.000).
+
        ; Before overwriting zx, set it for the next muls operation.
        LDA zx
        STA x0
        LDA zx+1
        STA x1

        ; zx = zx2 - zy2 (using z1/z2 directly).
        SEC
        LDA zx2
        SBC z1                     ; (was: SBC zy2)
        STA zx
        LDA zx2+1
        SBC z2                     ; (was: SBC zy2+1)
        STA zx+1
    

        ; zy = 2 * zx * zy
        LDA mode
        AND #MODE_KAWARI
        BEQ zxzy_sw
        ; Use Kawari hardware muls.
        LDA x0
        STA $D030       ; OP_1_LO
        LDA x1
        STA $D02F       ; OP_1_HI
        LDA y0
        STA $D032       ; OP_2_LO
        LDA y1
        STA $D031       ; OP_2_HI
        LDA #2          ; Kawari S_MULT operator.
        STA $D033       ; This triggers the operation.
        ; Result is immediately available.
        LDA $D031       ; RESULT_LH
        STA z1
        LDA $D030       ; RESULT_HL
        STA z2
        LDA $D02F       ; RESULT_HH
        STA z3
        JMP zxzy_done
    
zxzy_sw: 
        ; No need to setup zx [x0,x1] and zy [y0,y1]. They are already there.
        JSR multiply_16bit_signed ; [z0..z3] = zx*zy <<22

zxzy_done:
        LDA z3       ; We need Q5.11, so discard z0 (8 bits) and shift-r twice (2 bits) to get 2*result <<11.
        CMP #$80     ; Set carry if result is negative.
        ROR z3
        ROR z2
        ROR z1        
        CMP #$80     ; Set carry if result is negative.
        ROR z3
        ROR z2
        ROR z1       ; [z1..z2] = 2*zx*zy
        LDA z1
        STA zy
        LDA z2
        STA zy+1

        ; Inc iter and check max_iter.
        INC iter
.if BUILD_PERIODICITY & BUILD_C64
        ; Periodicity check. Snapshot at iter==4, compare for iter>4.
        ; Inline filter avoids JSR cost for the common early-iter diverge case.
        LDA iter
        CMP #4
        BCC pd_skip
        JSR periodicity_check
        BEQ found_color_black
pd_skip:
.endif
        LDA iter
        CMP max_iter
        BEQ found_color_black ; Max iters reached.
        JMP nxt_iter

found_color_black:
        LDA #0              ; Max iters is always black
        STA iter
found_color:
.if BUILD_LUMA_PALETTE
.if BUILD_HIRES_CONTOUR
        ; Contour mode: store raw iter (0..15). render_tile_contour does
        ; AND #$01 per pixel, so only the LSB matters. Raw iter (rather
        ; than collapsed parity) also lets stripe MS test uniformity on
        ; real iter values, avoiding false positives where border parity
        ; matches but interior parities differ.
.elif BUILD_C128
        ; C128 main section is tight; use a JSR (3 bytes inline) instead of
        ; the 10-byte inline remap. The luma_remap routine is placed in the
        ; post-mult-table area at $4FA1+.
        JSR luma_remap
.else
        ; Remap iter (0..15) → C64 color in luminance order.
        ; After this, `iter` no longer literally counts iterations — it holds
        ; the C64 color number. Histogram, tile-skip, and rendering all
        ; downstream work on this remapped value consistently.
        LDA iter
        AND #$0F
        TAX
        LDA iter_to_color_luma,X
        STA iter
.endif
.endif
        LDA iter
        LDY enable_buf_it
        BEQ skip_buf_it
        LDY #0
        STA (buf_it_ptr),Y  ; Save iters to pixel iterations buffer.
        INC buf_it_ptr
        BNE +
        INC buf_it_ptr+1
+       
skip_buf_it:

        ; If we are in hi-res mode, we do not set Color RAM here.
        LDA res
        BNE skip_ColorRAM

        ; Lo-res.
        LDA mode
        AND #MODE_VIC | MODE_KAWARI
        BEQ no_VIC2
        ; MODE_VIC
        LDA iter
        AND #$0F
.if BUILD_TED
        ORA #(TED_HI_LUMA<<4)    ; Set luma uniformly (see TED_HI_LUMA def).
.elif BUILD_PET | BUILD_B128
        AND #$0F
        TAX
        LDA pet_color
        BNE no_PETSCII
        ; Use table to convert iters to PETSCII.
        LDA iter_to_PETSCII,X   ; Fetch PETSCII from table.
    .if BUILD_B128
        ; B128
        ; Switch to Bank 15
        LDY #15
        STY $01
        LDY #0
        STA (sram_ptr),Y  ; Set Screen RAM
        ; Switch to Bank 1
        LDY #1
        STY $01
    .else
        ; PET
        LDY #0
        STA (sram_ptr),Y  ; Set Screen RAM
    .endif
no_PETSCII:        
        INC sram_ptr
        BNE +
        INC sram_ptr+1
+       
        LDA pet_more_than_2KB_vram
        BEQ no_CRAM
        TXA               ; Retreive color.
.endif
        LDY #0
        STA (cram_ptr),Y  ; Set color
        INC cram_ptr
        BNE +
        INC cram_ptr+1
+       JMP nxt_point
no_CRAM:
no_VIC2:
.if BUILD_C128
        LDA mode
        CMP #MODE_VDC
        BNE +
        ; MODE_VDC (lores).
; VDC_to_VIC-II debug
;    LDA cram_ptr+1
;    CMP #$D8
;    BCS v1
;    LDA #0
;    STA cram_ptr
;    LDA #$D8
;    STA cram_ptr+1
;v1: LDA pixely
;    AND #1
;    BNE skip_cramme
;    LDA pixelx
;    AND #1
;    BNE skip_cramme    
;    LDY #0
;    LDA iter
;    AND #$0F
;    STA (cram_ptr),Y  ; Set color
;    INC cram_ptr
;    BNE skip_cramme
;    INC cram_ptr+1
;skip_cramme:
        LDA iter
        AND #$0F          ; Max 16 colors on VDC (and remove all special attributes).
        LDX #$1F          ; VDC data register (we already point to the next attribute byte).
        JSR vdc_reg_write
        JMP nxt_point
+
.endif
.if BUILD_BEEB
        ; MODE_BEEB
        ; We don't have Color RAM, so we just fake it using bitmap.
        LDA iter
        AND #$07          ; Mode-2 is 8 colors.
        TAX
        LDA mode2_solid_colors,X    ; Use table to convert to solid color pattern (2 pixels of 4 bits each).
        LDY #0
        LDX #16           ; 2 pixels per byte. We need to set 4x8 = 32 pixels, hence 16 bytes.
-       STA (cram_ptr),Y  ; Set 2 pixels.
        INC cram_ptr
        BNE +
        INC cram_ptr+1
+       DEX
        BNE -
        JMP nxt_point
.endif

skip_ColorRAM:
.if BUILD_MARIANI_SILVER_STRIPE
        ; When called as JSR by Mariani-Silver, return after the
        ; iter has been written to (buf_it_ptr). The default render flow
        ; (which reaches here via JMP from nxt_point at the bottom) leaves
        ; ms_callable=0 and falls through normally.
        LDA ms_callable
        BEQ +
        RTS
+
.endif

; Go to nxt point in tile.
nxt_point:
        ; cx = cx + incx
        CLC
        LDA cx
        ADC incx
        STA cx
        LDA cx+1
        ADC incx+1
        STA cx+1
        
        ; Point to next pixel and check end of rows.
        INC pixelx
        LDA pixelx
        CMP tilew       ; WARNING: This currently requires tile width < 256.
        BEQ nxt_row     ; End of tile row.
        JMP calc_point

        ; Jump to next pixel row in tile.
nxt_row:
        ; cy = cy + incy
        SEC
        LDA cy
        SBC incy
        STA cy
        LDA cy+1
        SBC incy+1
        STA cy+1
        
        ; cx = t_ax
        LDA t_ax
        STA cx
        LDA t_ax+1
        STA cx+1
    
        LDA #0
        STA pixelx
        INC pixely
        LDA pixely
        CMP tileh      ; NOTE: This works only with tile height < 256.
        BEQ end_tile
        JMP calc_point

end_tile:
        ; End of tile.
        ; In lo-res mode (res=0), switch to hi-res. In hi-res, render the tile.
        LDA res
        BNE +
        JMP switch_to_hires
+
    
        ; We have completed a hi-res tile, render it.
.if BUILD_HIRES_CONTOUR & BUILD_C64
        JSR render_tile_contour
.elif BUILD_C64 | BUILD_TED
        JSR build_histogram
        JSR scan_histogram
        JSR render_tile_multicolor
.elif BUILD_C128
        LDA mode
        CMP #MODE_VDC
        BEQ +               ; Special tile rendering in VDC mode.
        JSR build_histogram
        JSR scan_histogram
        JSR render_tile_multicolor
        JMP go_to_next_tile
+       ; Render VDC tile (2x4).
        JSR render_tile_VDC
.elif BUILD_VIC20
        ; No need for histogram (4 fixed colors).
        JSR render_tile_multicolor
.elif BUILD_ATARI
        JSR render_tile_ATARI
.elif BUILD_BEEB
        JSR render_tile_BEEB
.endif        

go_to_next_tile:
        ; Calc next tile.
        INC tile_num
        BNE +
        INC tile_num+1
+       INC tilex
        LDA tilex
        CMP num_tiles_w
        BNE nxt_tile_in_row
        ; End of tile row, advance to next row.
.if BUILD_C128
        LDA mode
        CMP #MODE_VDC
        BNE +
        JSR bmp_to_next_tile    ; Needed on C128 VDC to update linear bitmap pointer.
+
.elif BUILD_ATARI
        JSR bmp_to_next_tile    ; Needed on Atari to update linear bitmap pointer.
.elif BUILD_VIC20
        LDA tiley
        AND #$01
        BNE +
        ; If tiley is even, go back to second half of 16-lines custom characters.
        LDA bmp_ptr
        SEC
        SBC #<344
        STA bmp_ptr
        LDA bmp_ptr+1
        SBC #>344
        STA bmp_ptr+1
        JMP done_vnt
+       ; If tiley is odd, just go back 8 lines.
        LDA bmp_ptr
        SEC
        SBC #8
        STA bmp_ptr
        BCS done_vnt
        DEC bmp_ptr+1
done_vnt:
.endif
        
        INC tiley
        LDA tiley
        CMP num_tiles_h
        BEQ no_more_passes      ; Hi-res pass done. Image completed.

        LDA #0
        STA tilex
        LDA ax
        STA t_ax
        LDA ax+1
        STA t_ax+1
.if BUILD_C128
        LDA mode
        CMP #MODE_VDC
        BNE no_eotH_VDC
        LDX #2                  ; VDC's HIRES_TILE_H
        BNE find_next_t_ay
.endif
no_eotH_VDC:
        LDX #HIRES_TILE_H       ; Sub HIRES_TILE_H*incy to t_ay.
find_next_t_ay:
        SEC
        LDA t_ay
        SBC incy 
        STA t_ay
        LDA t_ay+1
        SBC incy+1
        STA t_ay+1
        DEX
        BNE find_next_t_ay
        JMP done_tile_advance

nxt_tile_in_row:
        ; Advance to next tile in row.
.if BUILD_C128
        LDA mode
        CMP #MODE_VDC
        BNE no_eotW_VDC
        LDX #2                  ; VDC's HIRES_TILE_W
        BNE find_next_t_ax
.endif
no_eotW_VDC:        
        LDX #HIRES_TILE_W         ; Add HIRES_TILE_W*incx to t_ax.
find_next_t_ax:        
        CLC
        LDA t_ax
        ADC incx 
        STA t_ax
        LDA t_ax+1
        ADC incx+1
        STA t_ax+1
        DEX
        BNE find_next_t_ax
done_tile_advance:
    
        JMP nxt_tile

;----------------- Switch to hires -----------------
; After lo-res pass, switch to hi-res for second pass.
switch_to_hires:
        JSR switch_res
        BEQ no_more_passes  ; Switch mode failed.
        JMP nxt_pass
no_more_passes:
.if BUILD_BENCHMARK
        JSR benchmark_end
.endif
wait_ui_loop:
        JSR check_userinput ; Check userinput.
        BNE wait_ui
        JMP first_pass      ; Recalculate new image.
wait_ui:
        JMP wait_ui_loop    ; Loop checking user input.

        RTS ; EXIT

; (Benchmark routines moved to end of file near the cardioid test — see end
;  of source. They use `* = $1E00` which must come AFTER all main-section
;  code or it would shift everything.)

; Variables in page 0 for faster access.
var_bytes   = $a0
iter        = var_bytes +  0
max_iter    = var_bytes +  1
num_tiles_w = var_bytes +  2  ; Number of tile on screen (horizontal).
num_tiles_h = var_bytes +  3  ; Number of tile on screen (vertical).
tilex       = var_bytes +  4  ; Current tile x position on screen.
tiley       = var_bytes +  5  ; Current pixel y position on screen.
pixelx      = var_bytes +  6  ; Current pixel x position in tile.
pixely      = var_bytes +  7  ; Current pixel y position in tile.
b_hist      = var_bytes +  8  ; 4x8 block: Histogram table start (indices are iters mod16).
b_hist_last = b_hist    + 16  ; 4x8 block: Histogram table end.
h_top4_cnt  = b_hist_last     ; 4x8 block: Histogram 4 top counts (pixels).
h_top4_idx  = h_top4_cnt + 4  ; 4x8 block: Histogram 4 top indices (iters mod16).
b_END       = h_top4_idx + 4  ; --------------


; Words
var_words   = b_END            ; Start of words.
;
buf_it_ptr  = var_words +  0   ; Pixel iterations buffer.
ax          = var_words +  2   ; Screen plane upper-left corner x (Q5.11).
ay          = var_words +  4   ; Screen plane upper-left corner y (Q5.11).
cx          = var_words +  6   ; Current plane point x (Q5.11).
cy          = var_words +  8   ; Current plane point x (Q5.11). 
incx_lr     = var_words + 10   ; Lo-res pixel increment x (Q5.11).
incy_lr     = var_words + 12   ; Lo-res pixel increment y (Q5.11).
incx        = var_words + 14   ; Current pixel increment x (Q5.11).
incy        = var_words + 16   ; Current pixel increment y (Q5.11).
zx          = var_words + 18   ; zx (Q5.11).
zy          = var_words + 20   ; zy (Q5.11).
zx2         = var_words + 22   ; Squared zx (Q5.11).
zy2         = var_words + 24   ; Squared zy (Q5.11).
screenw     = var_words + 26   ; Screen width (pixels).
screenh     = var_words + 28   ; Screen height (pixels).
tilew       = var_words + 30   ; Tile width (pixels).
tileh       = var_words + 32   ; Tile height (pixels).
tile_num    = var_words + 34   ; Tile number (sequential).
squares     = var_words + 36   ; Squares table pointers (Q4.10*Q4.10 = Q5.11).
str_ptr     = var_words + 38   ; Current char of string to print.
scr_ptr     = var_words + 40   ; Curren screen pointer of string print routine.
bmp_ptr     = var_words + 42   ; Curren bitmap pointer (hi-res).
sram_ptr    = var_words + 44   ; Screen RAM ptr.
cram_ptr    = var_words + 46   ; Color RAM ptr.
t_ax        = var_words + 48   ; Current tile ax (upper-left corner x).
t_ay        = var_words + 50   ; Current tile ay (upper-left corner y).

  
  
 
;------------- Set bitmap pointer to next tile -------------
; Clobbered: A, X
;
bmp_to_next_tile:
.if BUILD_C64 | BUILD_TED
        CLC
        LDA bmp_ptr
        ADC #8
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+       RTS

.elif BUILD_C128
        LDA mode
        CMP #MODE_VDC
        BEQ btnt_vdc
        
        ; C128 VIC-IIe
        CLC
        LDA bmp_ptr
        ADC #8
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+       RTS
     
btnt_vdc:        
        ; C128 VDC
        LDX tilex
        CPX num_tiles_w
        BEQ b_end_of_row
        INC bmp_ptr
        BNE +
        INC bmp_ptr+1
+       INC vdc_attr_ptr
        BNE +
        INC vdc_attr_ptr+1
+       RTS
b_end_of_row:
        ; Add 80*3=240 to bmp.
        LDA bmp_ptr
        CLC
        ADC #240
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+       ; Add 80 to attr.
        LDA vdc_attr_ptr
        CLC
        ADC #80
        STA vdc_attr_ptr
        BCC +
        INC vdc_attr_ptr+1
+       RTS

.elif BUILD_VIC20
        LDX tilex
        CPX num_tiles_w
        BNE skip_16b
        ; End of row.
        LDA tiley
        AND #$01
        BEQ skip_8b
        ; If tiley is even, go back to second half of 16-lines custom characters.
        LDA bmp_ptr
        SEC
        SBC #<344
        STA bmp_ptr
        LDA bmp_ptr+1
        SBC #>344
        STA bmp_ptr+1
        RTS

skip_8b:
        CLC
        LDA bmp_ptr
        ADC #8
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+        
        RTS

skip_16b:
        CLC
        LDA bmp_ptr
        ADC #16
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+        
        RTS

.elif BUILD_ATARI
        LDX tilex
        CPX num_tiles_w
        BEQ b_end_of_row
        INC bmp_ptr
        BNE +
        INC bmp_ptr+1
+
        RTS
b_end_of_row:
        LDX #HIRES_TILE_H-1
-       LDA bmp_ptr
        CLC
        ADC num_tiles_w
        STA bmp_ptr
        LDA bmp_ptr+1
        ADC #0
        STA bmp_ptr+1
        DEX
        BNE -
        RTS

.elif BUILD_BEEB
        CLC
        LDA bmp_ptr
        ADC #16
        STA bmp_ptr
        BCC +
        INC bmp_ptr+1
+       RTS
.else   
        ; Unknown machine.
        RTS     
.endif        


;=========================================================================
; Check for user input.
; We read the machine's main joystick signals and put them in A using this format:
;   A=[xxxFRLDU] : All bits are active low: Fire, Right, Left, Down, Up.
;
; Output: Set Z flag if image must be recalculated (e.g. BEQ recalc).
; Clobbered: A, X, Y
check_userinput:
        ; Read joy inputs and translate to common format.
.if BUILD_C64 || BUILD_C128
        ; C64/C128 joystick.
        LDA $DC00           ; Get CIA1:PRA. This is [xxxFRLDU].
        AND #$1F            ; Get only joy-2 actions.

.elif BUILD_TED
        ; TED joystick input.
        LDA #$FF
        STA $FD30           ; 6529B Keyboard scan mask.
        LDA #$02            ; Select joy-1.
        STA $FF08           ; Strobe latch.
        LDA $FF08           ; Read value.
        AND #$0F            ; Mask directions.
        ; Directions are already in common format, but fire is bit 6.
        BIT $FF08           ; Check for joy-1 fire (pressed if bit 6 is 0).
        BVC +
        ORA #$10
+       
.elif BUILD_VIC20
      
        ; VIC20 joystick input.
        LDA $911F           ; Get VIA1:PA. This is [xxFLDUxx].
        LSR
        LSR                 ; [00xxFLDU]
        AND #$0F            ; [0000FLDU]
        STA input_scratch
        ASL                 ; [000FLDU0]
        AND #$10            ; [000F0000]
        ORA input_scratch   ; [000FFLDU]
        STA input_scratch
        LDA $9120           ; Get VIA2:PB. This is [Rxxxxxxx].
        ROL                 ; Carry = R
        LDA input_scratch
        AND #$17            ; [000F0LDU]
        BCC +
        ORA #$08            ; [000FRLDU]
+
.elif BUILD_PET
        ; PET user port joystick input (bitmap same as C64).
        ;LDA $E84F
        ;AND #$1F
        
        ; Keyboard SHIFT=fire, WASD=dirs. Read bits are active low (already ok for our standard format: [xxxFRLDU]).
        LDA pet_business_keyb
        BNE scan_pet_business_keyb
        
        ; This is for the PET normal keyboard.
        LDA #3              ; Select row 3
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$01            ; Bit 0 is 'W' (UP).
        STA input_scratch   ; [0000000U]
        LDA #4              ; Select row 4
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$03            ; Bit 0 is 'A' (LEFT), bit 1 is 'D' (RIGHT).
        ASL
        ASL
        ORA input_scratch   ; [0000RL0U]
        STA input_scratch
        LDA #5              ; Select row 5
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$01            ; Bit 0 is 'S' (DOWN).
        ASL
        ORA input_scratch   ; [0000RLDU]
        STA input_scratch
        LDA #8              ; Select row 8
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$21            ; Bit 0 is L-Shift, bit 5 is R-Shift (use both for FIRE).
        CMP #$21
        JMP set_fire

        ; This is for the PET business keyboard.
scan_pet_business_keyb:
        LDA #4              ; Select row 4
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        ROR                 ; Shift bit 1 ('W') to bit 0.
        AND #$01            ; Check for 'W' (UP).
        STA input_scratch   ; [0000000U]
        LDA #3              ; Select row 3
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$03            ; Bit 0 is 'A' (LEFT), bit 1 is 'D' (RIGHT).
        ASL
        ASL
        ORA input_scratch   ; [0000RL0U]
        STA input_scratch
        LDA #2              ; Select row 2
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$02            ; Bit 1 is 'S' (DOWN).
        ORA input_scratch   ; [0000RLDU]
        STA input_scratch
        LDA #6              ; Select row 6
        STA $E810           ; PIA1:PA
        LDA $E812           ; PIA1:PB
        AND #$41            ; Bit 0 is L-Shift, bit 6 is R-Shift (use both for FIRE).
        CMP #$41

        ; This is for both normal and business keyboards.
set_fire:        
        BNE shift_pressed   ; Keep bit 4 of result set to 0 (FIRE pressed).
        LDA #$10            ; Unselect FIRE.
        ORA input_scratch
        STA input_scratch
shift_pressed:
        LDA input_scratch   ; [000FRLDU]

        
done_pet_keyboard:
        
.elif BUILD_B128
        ; B128 keyboard (6525 TPI).
        ; Use "WASD" for dirs and "SHIFT" for fire.
        ;
        LDA #$1F
        STA input_scratch   ; Reset input scratch mask to nothing pressed.
        ;
        ; Switch to Bank 15
        LDA #15
        STA $01
        ; Select column using PA ($DF00) and PB ($DF01).
        LDA #0
        STA $04
        LDA #$DF
        STA $05
        LDA #$FF
        LDY #0              ; Point to PA (col select).
        STA ($04),Y         ; PA=$FF
        ; Check "A" (LEFT).
        INY                 ; Point to PB (col select).
        LDA #$FD
        STA ($04),Y         ; PB=$FD (select kb connector pin 13).
        INY                 ; Point to PC (row input).
        LDA ($04),Y         ; Get PC.
        LSR
        ORA #$FB
        AND input_scratch
        STA input_scratch
        ; Check "W" (UP) and "S" (DOWN).
        DEY                 ; Point to PB (col select).
        LDA #$FB
        STA ($04),Y         ; PB=$FB (select kb connector pin 12).
        INY                 ; Point to PC (row input).
        LDA ($04),Y         ; Get PC.
        LSR
        LSR
        ORA #$FC
        AND input_scratch
        STA input_scratch
        ; Check "D" (RIGHT).
        DEY                 ; Point to PB (col select).
        LDA #$F7
        STA ($04),Y         ; PB=$F7 (select kb connector pin 11).
        INY                 ; Point to PC (row input).
        LDA ($04),Y         ; Get PC.
        ORA #$F7
        AND input_scratch
        STA input_scratch
        ; Check "SHIFT" (FIRE).
        DEY                 ; Point to PB (col select).
        LDA #$FE
        STA ($04),Y         ; PB=$FE (select kb connector pin 14).
        INY                 ; Point to PC (row input).
        LDA ($04),Y         ; Get PC.
        ORA #$EF
        AND input_scratch
        STA input_scratch   ; [000FRLDU] 

        ; Switch back to Bank 1
        LDX #1
        STX $01

.elif BUILD_ATARI
        ; Atari joystick input.
        LDA $D300           ; PIA:PORTA[3..0] is joy-1 directions [R,L,D,U]. Active low.
        AND #$0F
        LDX $D010           ; GTIA:TRIG0[0] is joy-1 trigger. Active low.
        BEQ +               ; We can do this because TRIG0[7..1] is always 0.
        ORA #$10
+

.elif BUILD_BEEB
        ; BBC Micro analog joystick input (uPD7002 chip).
        ; First, read fire button.
        LDX #$1F            ; Use X to store joy value.
        LDA $FE40
        AND #$10            ; Bit 4 is low if joy-1 fired.
        BNE +
        LDX #$0F            ; Fire pressed.
 +      ; Now check directions.
 
        LDA beeb_joy_dir_axis   ; Get current axis (bit 0) and waiting flag (bit 7).
        BMI adc_check       ; If bit 7 is set, check if result is ready.
        ; Else, init next axis read.
adc_init:
        AND #$01            ; Select channel: 0 = Joy-1 x-axis; 1 = Joy-1 y-axis.
        STA $FEC0           ; Write to data latch / AD start reg.
        ORA #$80            ; Remember to wait for the ADC (about 4ms for 8-bit).
        STA beeb_joy_dir_axis
        JMP done_joy_BEEB

adc_check:
        LDA $FEC0           ; Read ADC status register. Bit 7 is 0 when conversion completed.
        BMI done_joy_BEEB   ; Branch if conversion not yet completed.
        ; Conversion completed.
        LDA beeb_joy_dir_axis
        TAY                 ; Save axis to Y (bit 7 is also set).
        LDA $FEC1           ; Fetch ADC value [0..255].
        CPY #$80            ; Which axis ?
        BNE +
        STA beeb_joy_last_x
        BEQ chk_thesholds   ; Unconditional.
 +      STA beeb_joy_last_y
 chk_thesholds:
        CMP #32             ; Dead-zone threshold low.
        BCS chk_hi          ; BGE
        ; Low detected.
        CPY #$80            ; Which axis ?
        BNE +
        ; RIGHT
        TXA
        AND #$F7
        TAX
        JMP switch_axis
+       ; DOWN
        TXA
        AND #$FD
        TAX
        JMP switch_axis        
        
chk_hi: CMP #256-32         ; Dead-zone threshold high.
        BCC switch_axis     ; BLT
        ; High detected.
        CPY #$80            ; Which axis ?
        BNE +
        ; LEFT
        TXA
        AND #$FB
        TAX
        JMP switch_axis
+       ; UP
        TXA
        AND #$FE
        TAX
        JMP switch_axis

switch_axis:
        ; Switch axis for next read.
        LDA beeb_joy_dir_axis
        EOR #$01
        STA beeb_joy_dir_axis
        JMP adc_init        ; Init next axis read.

done_joy_BEEB:
        ; Read keyboard.
        ; 'SHIFT'
        LDA #0
        STA $FE4F
        LDA $FE4F  ; N flag = pressed.
        BPL +
        TXA
        AND #$EF   ; Simulate fire with 'SHIFT'.
        TAX
+       ; 'RIGHT'
        LDA #121
        STA $FE4F
        LDA $FE4F  ; N flag = pressed.
        BPL +
        TXA
        AND #$F7
        TAX
+       ; 'LEFT'
        LDA #25
        STA $FE4F
        LDA $FE4F  ; N flag = pressed.
        BPL +
        TXA
        AND #$FB
        TAX
+       ; 'DOWN'
        LDA #41
        STA $FE4F
        LDA $FE4F  ; N flag = pressed.
        BPL +
        TXA
        AND #$FD
        TAX
+       ; 'UP'
        LDA #57
        STA $FE4F
        LDA $FE4F  ; N flag = pressed.
        BPL +
        TXA
        AND #$FE
        TAX
+
        ; ...

done_keyb_BEEB:
        TXA                 ; Move result to A.
        
.else
        ; Unsupported platform. No input.
        LDA #$1F
.endif
        
        ; Edge-triggered debounce: only act on transitions from prev state.
        ; One press = one action regardless of hold duration. Warp-safe.
        CMP prev_input
        BEQ no_change           ; State unchanged
        STA prev_input          ; Remember new state
        CMP #$1F
        BEQ no_change           ; Transitioned to "no input" (release)
        TAX                     ; X = current input
        ; Fire alone (no direction) does nothing; fire only acts with a
        ; direction (zoom or iter +/-).
        AND #$0F
        CMP #$0F
        BEQ no_change
        TXA
        AND #$10
        BEQ fire                ; Fire pressed
        JMP no_fire             ; Direction only

no_change:
        LDA #$01                ; Clear Z flag so caller sees "no recalc".
        RTS

fire:
        ; Fire button pressed. Handle zoom.
        ; Note: We have almost no checks for precision underflow.
        ;       Let's call underflow a "user error" :-)
chk_zoom_IN:
.if BUILD_VIC20
    INCX_ZOOM_STEP = 8
    INCY_ZOOM_STEP = 4
.else
    ; UX: ~8% zoom per press (16/192 ≈ 8.3%, ~9 presses for 2× zoom).
    ; Previous step #4 gave only ~2.4% per press = ~30 presses for 2×.
    INCX_ZOOM_STEP = 16
    INCY_ZOOM_STEP = 16
.endif
        TXA                 ; Retreive joy input from X.
        AND #$01            ; Up
        BNE chk_zoom_OUT

        ; ZOOM IN.
        ; Save both prev values up front. If X processing jumps to
        ; set_min_step (already at min zoom), Y processing is skipped;
        ; saving incy_lr_prev here keeps recenter from computing a phantom
        ; shift on presses at max zoom.
        LDA incx_lr+1
        STA incx_lr_prev+1
        LDA incx_lr
        STA incx_lr_prev
        LDA incy_lr+1
        STA incy_lr_prev+1
        LDA incy_lr
        STA incy_lr_prev
        ; X
        LDA incx_lr
        SEC
        SBC #INCX_ZOOM_STEP
        STA incx_lr
        BCS +
        ; Borrow.
        LDA incx_lr+1
        BEQ set_min_step    ; Negative step.
        DEC incx_lr+1
+       BNE +
        ; incx_lr+1 == 0. Enforce min zoom-in step.
        LDA incx_lr
        CMP #INCX_ZOOM_STEP
        BCC set_min_step    ; BLT
+
        ; Y
        LDA incy_lr
        SEC
        SBC #INCY_ZOOM_STEP
        STA incy_lr
        BCS +
        ; Borrow.
        LDA incy_lr+1
        BEQ set_min_step    ; Negative step.
        DEC incy_lr+1
+       BNE +
        ; incy_lr+1 == 0. Enforce min zoom-in step.
        LDA incy_lr
        CMP #INCY_ZOOM_STEP
        BCC set_min_step    ; BLT
+
        JMP zoomin_recenter

set_min_step:
        LDA #0
        STA incx_lr+1
        STA incy_lr+1
        LDA #INCX_ZOOM_STEP
        STA incx_lr
        LDA #INCY_ZOOM_STEP
        STA incy_lr

zoomin_recenter:       
        JSR recenter        ; This clobbers X.  
        LDA incx_lr
        JSR print_A_hex
        JMP end_input

chk_zoom_OUT:    
        TXA                 ; Retrieve input.
        AND #$02            ; Down
        BNE chk_iters_more
        
        ; ZOOM OUT
        LDA incx_lr+1
        STA incx_lr_prev+1
        LDA incx_lr
        STA incx_lr_prev
        CMP #241            ; Max zoom-out reached ?
        BCC +               ; No, increase step.
        JMP end_input       ; Yes. Do nothing.
        
+       CLC
        ADC #INCX_ZOOM_STEP
        STA incx_lr
        BCC +
        INC incx_lr+1
        CLC
+       LDA incy_lr+1
        STA incy_lr_prev+1
        LDA incy_lr
        STA incy_lr_prev
        ADC #INCY_ZOOM_STEP
        STA incy_lr
        BCC +
        INC incy_lr+1
+       JSR print_A_hex
        JSR recenter        ; This clobbers X.  
        JMP end_input
    
chk_iters_more:
        TXA                 ; Retrieve input.
        AND #$08            ; Right
        BNE chk_iters_less
        LDA max_iter
        CMP #255            ; Max 255 iters.
        BEQ end_zoomiters
        INC max_iter
        LDA max_iter
        JSR print_A_hex

chk_iters_less:
        TXA                 ; Retrieve input.
        AND #$04            ; Left
        BNE end_zoomiters
        DEC max_iter
        BNE +
        LDA #2              ; Min iters is 2.
        STA max_iter
+       LDA max_iter
        JSR print_A_hex

end_zoomiters:
        ; Set zero flag if image must be recalculated.
        TXA
        AND #$0F           
        CMP #$0F            ; Check if a joystick direction was pressed.    
        BEQ no_dir
        LDA #$00
        RTS
no_dir:
        LDA #$FF
        RTS

no_fire: ;----- no fire button pressed
        ; Pan by incx_lr / incy_lr (= 1 lo-res pixel = 8 hi-res pixels per
        ; press, ~4 % of the screen). Scales with zoom level.
chk_pan_U:
        TXA                 ; Retrieve input from X.
        AND #$01            ; Up
        BNE chk_pan_D
        CLC
        LDA ay
        ADC incy_lr
        STA ay
        LDA ay+1
        ADC incy_lr+1
        STA ay+1
chk_pan_D:
        TXA                 ; Retrieve input.
        AND #$02            ; Down
        BNE chk_pan_L
        SEC
        LDA ay
        SBC incy_lr
        STA ay
        LDA ay+1
        SBC incy_lr+1
        STA ay+1
chk_pan_L:
        TXA                 ; Retrieve input.
        AND #$04            ; Left
        BNE chk_pan_R
        SEC
        LDA ax
        SBC incx_lr
        STA ax
        LDA ax+1
        SBC incx_lr+1
        STA ax+1
chk_pan_R:
        TXA                 ; Retrieve input.
        AND #$08            ; Right
        BNE end_input
        CLC
        LDA ax
        ADC incx_lr
        STA ax
        LDA ax+1
        ADC incx_lr+1
        STA ax+1
  
    
end_input:
        ;JSR print_A_hex
        ; Set zero flag to signal image must be recalculated.
        LDA #$00
        RTS

prev_input:     .byte $1F   ; Last seen input state (default $1F = no input).
input_scratch:  .byte 0

;===================================================================
; Recenter mandelbrot based on newly changed incx and incy.
; This will readjust ax and ay.
;
; Inputs:
;   prev_incx : Previous incx
;   prev_incy : Previous incy
;
; Outputs:
;   ax : New upper-left x coord bnased on current incx
;   ay : New upper-left y coord bnased on current incy

recenter:
        ; Image dimensions in the complex plane: LORES_W * incx_lr and
        ; LORES_H * incy_lr. (Multiplying screenw/screenh by incx_lr/incy_lr
        ; mixes HI-RES pixel counts with LO-RES increments and gives the
        ; wrong shift, drifting the image off-axis on each zoom step.)
        ; Current complex plane width.
        LDA #<LORES_W
        STA x0
        LDA #>LORES_W
        STA x1
        LDA incx_lr
        STA y0
        LDA incx_lr+1
        STA y1
        JSR multiply_16bit_unsigned
        LDA z0
        STA pw_cur
        LDA z1
        STA pw_cur+1
        ; Calculate previous complex plane width.
        LDA incx_lr_prev
        STA y0
        LDA incx_lr_prev+1
        STA y1
        JSR multiply_16bit_unsigned
        LDA z0
        STA pw_prev
        LDA z1
        STA pw_prev+1

        ; Calculate current complex plane height.
        LDA #<LORES_H
        STA x0
        LDA #>LORES_H
        STA x1
        LDA incy_lr
        STA y0
        LDA incy_lr+1
        STA y1
        JSR multiply_16bit_unsigned
        LDA z0
        STA ph_cur
        LDA z1
        STA ph_cur+1
        ; Calculate previous complex plane height.
        LDA incy_lr_prev
        STA y0
        LDA incy_lr_prev+1
        STA y1
        JSR multiply_16bit_unsigned
        LDA z0
        STA ph_prev
        LDA z1
        STA ph_prev+1
        
        ; Compute diff.
        SEC
        LDA pw_prev
        SBC pw_cur
        STA pw_diff
        LDA pw_prev+1
        SBC pw_cur+1
        STA pw_diff+1
        SEC
        LDA ph_prev
        SBC ph_cur
        STA ph_diff
        LDA ph_prev+1
        SBC ph_cur+1
        STA ph_diff+1
        ; Divide diff by two.
        CMP #$80        ; Set carry if negative.
        ROR pw_diff+1
        ROR pw_diff
        CMP #$80        ; Set carry if negative.
        ROR ph_diff+1
        ROR ph_diff
.if BUILD_C128
        ; C128 VDC mode: actual screen is 80×50 lo-res, but LORES_W/H above
        ; are 40/25 (compile-time constants for the whole C128 build, sized
        ; for VIC-IIe). Multiply the halved diffs by 2 to compensate, so
        ; recenter shifts ax/ay correctly when zooming in VDC mode.
        LDA mode
        CMP #MODE_VDC
        BNE +
        ASL pw_diff
        ROL pw_diff+1
        ASL ph_diff
        ROL ph_diff+1
+
.endif
        ; Add halved diff to ax.
        CLC
        LDA ax
        ADC pw_diff
        STA ax
        LDA ax+1
        ADC pw_diff+1
        STA ax+1
        ; Sub halved diff from ay (pixel vs plane coords are opposite on y-axis).
        SEC
        LDA ay
        SBC ph_diff
        STA ay
        LDA ay+1
        SBC ph_diff+1
        STA ay+1
    
        RTS

incx_lr_prev: .word 0
incy_lr_prev: .word 0
pw_cur:       .word 0
ph_cur:       .word 0
pw_prev:      .word 0
ph_prev:      .word 0
pw_diff:      .word 0
ph_diff:      .word 0


;===========================================================
; Print A as a hex number on the upper-left corner of the screen.
; NOTE: Registers are preserved.

print_A_hex:
        PHA        ; Save A.
        PHA        ; Save A.
        
        LSR
        LSR
        LSR
        LSR
        CMP #$0A
        BCS pA_alpha_0
        ; Not alpha, i.e. [0..9]
        ADC #$30 + 9
pA_alpha_0:    
        SEC
        SBC #9
        STA nibble_char_h

nxt_nibble:
        PLA        ; Restore A.
        AND #$0F
        CMP #$0A
        BCS pA_alpha_1
        ; Not alpha, i.e. [0..9]
        ADC #$30 + 9
pA_alpha_1:    
        SEC
        SBC #9
        STA nibble_char_l

.if BUILD_B128
        TYA
        PHA         ; Save Y.
        LDA $01
        PHA         ; Remember bank.
        LDA $04
        PHA         ; Remember $04
        LDA $05
        PHA         ; Remember $05
        ; Switch to bank 15
        LDA #15
        STA $01
        LDA #$00
        STA $04
        LDA #$D0
        STA $05
        LDA nibble_char_h
        LDY #0
        STA ($04),Y
        LDA nibble_char_l
        INY
        STA ($04),Y
        PLA         ; Retrieve $05.
        STA $05
        PLA         ; Retrieve $04.
        STA $04
        PLA         ; Retrieve previous bank.
        STA $01
        PLA         ; Restore Y.
        TAY
.else        
        ;LDA mode
        ;AND #MODE_VIC | MODE_KAWARI
        ;BEQ +
        ; Output.
        LDA nibble_char_h
        STA SCR_RAM
        LDA nibble_char_l
        STA SCR_RAM+1
    .if COL_RAM
        ; Set color.
        LDA #$61   ; Light gray (use also high nibble for TED machines).
        STA COL_RAM
        STA COL_RAM+1
    .endif
.endif
;+ 
        ;CMP #MODE_VDC
        ;BNE +
        ;; Output.
        ;TXA
        ;PHA
        ;LDX #$12          ; VDC mem addr HI
        ;LDA #$00
        ;JSR vdc_reg_write
        ;INX               ; VDC mem addr LO
        ;JSR vdc_reg_write
        ;LDX #$1F          ; VDC data
        ;LDA nibble_char_h
        ;JSR vdc_reg_write
        ;LDA nibble_char_l
        ;JSR vdc_reg_write
        ;; Set color.
        ;LDX #$12          ; VDC mem addr HI
        ;LDA #$10
        ;JSR vdc_reg_write
        ;INX               ; VDC mem addr LO
        ;LDA #$00
        ;JSR vdc_reg_write
        ;LDX #$1F          ; VDC data
        ;LDA #$1F          ; White.
        ;JSR vdc_reg_write
        ;PLA
        ;TAX
        ;JMP end_pAh
;+
end_pAh:    
        PLA        ; Restore A.
        RTS

nibble_char_h: .byte 0
nibble_char_l: .byte 0



;=============================================================
; Description: Signed Q4.10 fixed-point squares table.
; This is a 32KB table containing 16384 Q4.10 numbers (two bytes each).
; Only positive Q4.10 with even lowest bit are present.
; Table starts at $5000 and ends at $cfff

init_squares_q4_10:
        LDA #$00
        STA squares     ; Use a page 0 address.
        LDA #$50
        STA squares+1
        LDY #$00        ; Used for indirect indexed.
        STY x0          ; Start from 0.
        STY x1
        STY y0
        STY y1

-       JSR multiply_Q5_11_signed
        ; Result is in [z1..z2].
        LDA z1
        LDY #$00
        STA (squares),Y
        INC squares
        LDA z2
        STA (squares),Y
        INC squares
        BNE +
        INC squares+1
+       INC x0      ; Skip odd numbers.
        INC x0
        INC y0
        INC y0
        BNE -
        INC x1
        INC y1
        LDA x1
        CMP #$80    ; Last entry is for number $7FFF.
        BNE -

squares_tab_complete:
        RTS

;===========================================================
; Description: Get the square of the given signed Q5.11 number using the signed Q4.10 squares table.
; NOTE: The square will be an approximation if the last bit is odd.
;
; Input: Q5.11 signed value in x0,x1
;
; Output: Approximated Q5.11 signed squared value in z1,z2

square_Q5_11:
        ; Check if negative.
        LDA x1
        BPL not_neg
        
        ; Convert to positive (exact).
        SEC
        LDA #$00
        SBC x0
        AND #$FE            ; Make even.
        STA squares
        LDA #$00
        SBC x1
        STA squares+1
        BPL fetch_square   ; Always positive (i.e. branch always).
not_neg:
        LDA x0
        AND #$FE            ; Make even.
        STA squares
        LDA x1
        STA squares+1
fetch_square:        
        ; Fetch from table.
        CLC
        LDA squares+1
        ADC #$50            ; Table offset
        STA squares+1
        LDY #$00
        LDA (squares),Y
        STA z1
        INY
        LDA (squares),Y
        STA z2
        RTS

;==============================================================
; Description: Signed Q5.11 fixed-point multiplication with signed Q5.11 result.
; This uses the multiply_16bit_unsigned routine.
;
; Revision history [authors in square brackets]:
; 2024-11-07: First simple test loop. [DDT]
; 2025-02-13: Changed to Q5.11 [DDT]
;
; Input: Q5.11 signed value in x0,x1
;        Q5.11 signed value in y0,y1
;
; Output: Q5.11 signed value z1,z2
;
; Clobbered: X, A, C
multiply_Q5_11_signed:
            
        ; Step 1: signed multiply
        JSR multiply_16bit_signed
        ; Result is in z1,z2.
        
        ; Perform fixed point adjustment.
        ; We need to shift it right 11 bits, so just ignore z0 and shift right thrice the 24 bit value in z1,z2,z3.
        LDA z3
        CMP #$80        ; Set carry if result is negative.
        ROR z3
        ROR z2
        ROR z1
        
        CMP #$80        ; Set carry if result is negative.
        ROR z3
        ROR z2
        ROR z1

        CMP #$80        ; Set carry if result is negative.
        ROR z3
        ROR z2
        ROR z1
        
        RTS

buf_tile_size:  .byte 0      ; 0 means screen size or none (depending on mode).

enable_buf_it:  .byte 1

.if BUILD_MARIANI_SILVER_STRIPE
; When set to 1, calc_point's exit at skip_ColorRAM does RTS
; instead of falling through to nxt_point. Stripe MS sets this to 1
; before JSR calc_point and back to 0 after. Default render flow leaves
; it at 0 (existing behavior unchanged).
ms_callable:    .byte 0
.endif

; Tile iterations buffers (lo-res and hi-res).
.if BUILD_C64
buf_iters_lr = $E000
buf_iters_hr = $E800
.elif BUILD_C128
buf_iters_lr = $E000
buf_iters_hr = $F000
.elif BUILD_TED
buf_iters_lr = $E000
buf_iters_hr = $E800
.elif BUILD_VIC20
buf_iters_lr = $2000
buf_iters_hr = $2800
.elif BUILD_PET
buf_iters_lr = $1C00            ; Is that ok ?
buf_iters_hr = $1C00            ; Is that ok ?
.elif BUILD_B128
buf_iters_lr = $E000
buf_iters_hr = $F000
.elif BUILD_ATARI
buf_iters_lr = $E000
buf_iters_hr = $E800
.elif BUILD_BEEB
buf_iters_lr = $1000
buf_iters_hr = $1800
.endif


; ---------------- Signed 16x16=32 bits ----------------
; Revision history [authors in square brackets]:
;   2024-11-07: Original smult12 code taken from:
;    https://github.com/TobyLobster/multiply_test
;   2024-11-07: Adapted to TASS and Commodore 64. [DDT];
;
; smult12.a
; from smult3, but tweaked to use mult86 as a base
;
; 16 bit x 16 bit signed multiplication, 32 bit result
; Average cycles: 234.57
; 2210 bytes (including init routine)

; pointers to tables of squares
p_sqr_lo1    = $8b   ; 2 bytes
p_sqr_hi1    = $8d   ; 2 bytes
p_neg_sqr_lo = $8f   ; 2 bytes
p_neg_sqr_hi = $91   ; 2 bytes
p_sqr_lo2    = $93   ; 2 bytes
p_sqr_hi2    = $95   ; 2 bytes

; the inputs and outputs
x0  = p_sqr_lo1      ; multiplier, 2 bytes
x1  = p_sqr_lo2      ; [WARNING: note non-consecutive bytes!]
y0  = $04            ; multiplicand, 2 bytes
y1  = $05
z0  = $06            ; product, 4 bytes
z1  = $07            ;
z2  = $08            ;
z3  = $09            ;



;========================== MULTIPLICATION TABLES ==========================
; Must be aligned to page boundary.
;
.if BUILD_C64
    MULT_TAB_ADDR = $4700
.elif BUILD_C128
    MULT_TAB_ADDR = $4700
.elif BUILD_TED
    MULT_TAB_ADDR = $4700
.elif BUILD_VIC20
    MULT_TAB_ADDR = $3700
.elif BUILD_PET
    MULT_TAB_ADDR = $800
.elif BUILD_B128
    MULT_TAB_ADDR = $2800
.elif BUILD_ATARI
    MULT_TAB_ADDR = $4700
.elif BUILD_BEEB
    MULT_TAB_ADDR = $2700
.endif

; First, check that code assembled didn't go past MULT_TAB_ADDR.
.if (Mandelbrot < MULT_TAB_ADDR) && (* > MULT_TAB_ADDR)
    .error "Assembled code overrun over mult tab."
.endif

; Note - the last byte of each table is never referenced, as a+b<=510
        * = mult_tab_addr
sqrlo:
    .for i := 0, i < 511, i += 1
        .byte <((i*i)/4)
    .endfor

        * = mult_tab_addr + $200
sqrhi:
    .for i := 0, i < 511, i += 1
        .byte >((i*i)/4)
    .endfor

        * = mult_tab_addr + $400
negsqrlo:
    .for i := 0, i < 511, i += 1
        .byte <(((255-i)*(255-i))/4)
    .endfor

        * = mult_tab_addr + $600
negsqrhi:
    .for i := 0, i < 511, i += 1
        .byte >(((255-i)*(255-i))/4)
    .endfor

    
; Description: Signed 16-bit multiplication with signed 32-bit result.
;
; Input: 16-bit signed value in x0,x1
;        16-bit signed value in y0,y1
;
; Output: 32-bit signed value in z0,z1,z2,z3
;
; Clobbered: X, A, C
multiply_16bit_signed:
   
    ; Step 1: unsigned multiply
    jsr multiply_16bit_unsigned

    ; Step 2: Apply sign (See C=Hacking16 for details).
    bit x1
    bpl x1_pos
    sec
;    lda z2
    sbc y0
    sta z2
    lda z3
    sbc y1
    sta z3
x1_pos:
    bit y1
    bpl y1_pos
    sec
    lda z2
    sbc x0
    sta z2
    lda z3
    sbc x1
    sta z3
y1_pos:

    rts


; mult86.a
; from 6502.org, by Repose: http://forum.6502.org/viewtopic.php?p=106519#p106519
;
; 16 bit x 16 bit unsigned multiply, 32 bit result
; Average cycles: 193.07 (including z1 and z2 results being saved to memory locations)

; How to use:
; call jsr init, before first use
; put numbers in (x0,x1) and (y0,y1) and result is (z3, z2 (also A), z1 (also Y), z0)

; Diagram of the additions
;                 y1    y0
;              x  x1    x0
;                 --------
;              x0y0h x0y0l
; +      x0y1h x0y1l
; +      x1y0h x1y0l
; +x1y1h x1y1l
; ------------------------
;     z3    z2    z1    z0

multiply_16bit_unsigned:
    ; set multiplier as x1
    lda x1
    sta p_sqr_hi1
    eor #$ff
    sta p_neg_sqr_lo
    sta p_neg_sqr_hi

    ; set multiplicand as y0
    ldy y0

    ; x1y0l =  low(x1*y0)
    ; x1y0h = high(x1*y0)
    sec
    lda (p_sqr_lo2),y
    sbc (p_neg_sqr_lo),y
    sta x1y0l+1
    lda (p_sqr_hi1), y
    sbc (p_neg_sqr_hi),y
    sta x1y0h+1

    ; set multiplicand as y1
    ldy y1

    ; x1y1l =  low(x1*y1)
    ; z3    = high(x1*y1)
    lda (p_sqr_lo2),y
    sbc (p_neg_sqr_lo),y
    sta x1y1l+1
    lda (p_sqr_hi1),y
    sbc (p_neg_sqr_hi),y
    sta z3

    ; set multiplier as x0
    lda x0
    sta p_sqr_hi2
    eor #$ff
    sta p_neg_sqr_lo
    sta p_neg_sqr_hi

    ; x0y1l =  low(x0*y1)
    ; X     = high(x0*y1)
    lda (p_sqr_lo1),y
    sbc (p_neg_sqr_lo),y
    sta x0y1l+1
    lda (p_sqr_hi2),y
    sbc (p_neg_sqr_hi),y
    tax

    ; set multiplicand as y0
    ldy y0

    ; z0    =  low(x0*y0)
    ; A     = high(x0*y0)
    lda (p_sqr_lo1),y
    sbc (p_neg_sqr_lo),y
    sta z0
    lda (p_sqr_hi2),y
    sbc (p_neg_sqr_hi),y

    clc
do_adds:
    ; add the first two numbers of column 1
x0y1l:
    adc #0      ; x0y0h + x0y1l
    tay

    ; continue to first two numbers of column 2
    txa
x1y0h:
    adc #0      ; x0y1h + x1y0h
    tax         ; X=z2 so far
    bcc +
    inc z3      ; column 3
    clc

    ; add last number of column 1
+
    tya
x1y0l:
    adc #0      ; + x1y0l
    tay         ; Y=z1

    ; add last number of column 2
    txa
x1y1l:
    adc #0      ; + x1y1l
    bcc fin     ; A=z2
    inc z3      ; column 3
fin:
    sta z2      ; Added: save middle byte results from registers A,Y
    sty z1      ;
    rts

; Once only initialization
; (TODO: this could set up the pointer values in a loop to save memory
; it could also generate the square tables in code rather than load them)
mulu_init:
    lda #>sqrlo
    sta p_sqr_lo2+1
    sta p_sqr_lo1+1

    lda #>sqrhi
    sta p_sqr_hi1+1
    sta p_sqr_hi2+1

    lda #>negsqrlo
    sta p_neg_sqr_lo+1

    lda #>negsqrhi
    sta p_neg_sqr_hi+1
    rts


;------ Period-2 bulb quick test ------
; Test (cx + 1)² + cy² < 1/16 (= $0080 in Q5.11).
; If point is inside period-2 bulb of Mandelbrot set, this routine pulls the
; return address off the stack and JMPs to found_color_black, skipping the
; caller's iter loop entirely. Otherwise returns normally.
; Clobbers: A, X, Y, x0, x1, z1, z2, zx2 (zx2 is reset on first iter anyway).
; Only enabled where squares table is available (≥ 64 KB RAM machines).
; For C64 build the routine lives in the BENCH region ($1E00).
; For C128/TED/ATARI/B128 it falls into the post-mult-table gap ($4FA1+).
.if BUILD_C64 | BUILD_C128 | BUILD_TED | BUILD_ATARI | BUILD_B128
test_period2_bulb:
        ; Cheap bbox reject on cx high byte. Bulb x-range: [-1.25, -0.75)
        ; = [$F600, $FA00), so cx_hi must be one of $F6/$F7/$F8/$F9.
        LDA cx+1
        CMP #$F6
        BCC bulb_no         ; cx_hi < $F6 → too negative, out
        CMP #$FA
        BCS bulb_no         ; cx_hi >= $FA → too positive, out
        ; Cheap bbox reject on cy high byte. Bulb y-range: (-0.25, +0.25)
        ; ≈ ($FE00, $0200). Acceptable cy_hi: $00, $01, $FE, $FF.
        LDA cy+1
        CMP #$02
        BCC cy_bbox_ok      ; cy_hi < $02 → small + (or wrap)
        CMP #$FE
        BCS cy_bbox_ok      ; cy_hi >= $FE → small -
        BCC bulb_no         ; cy_hi in [$02, $FD] → out (always taken)
cy_bbox_ok:
        ; Full test: (cx + 1)² + cy² < $0080 ?
        CLC
        LDA cx
        ADC #<$0800         ; +1.0 in Q5.11 = $0800
        STA x0
        LDA cx+1
        ADC #>$0800
        STA x1
        JSR square_Q5_11    ; z1,z2 = (cx+1)²
        LDA z1
        STA zx2             ; scratch (overwritten by iter loop)
        LDA z2
        STA zx2+1
        LDA cy
        STA x0
        LDA cy+1
        STA x1
        JSR square_Q5_11    ; z1,z2 = cy²
        CLC
        LDA z1
        ADC zx2
        STA z1
        LDA z2
        ADC zx2+1
        ; sum < $0080 ?  Need high byte == 0 AND low < $80.
        BNE bulb_no         ; high byte != 0 → not in bulb
        LDA z1
        CMP #$80
        BCS bulb_no         ; low >= $80 → not in bulb
        ; In bulb! Pop caller's return addr from stack and jump to found_color_black.
        PLA
        PLA
        JMP found_color_black
bulb_no:
        RTS
.endif

; ---- luma_remap (C128 JSR target, mode-aware via ZP pointer) ----
; C128 has TWO display chips with different palettes (VIC-IIe vs VDC). The
; appropriate luma table address is loaded into ZP pointer luma_table_ptr
; ($F4-$F5) at startup based on detected mode. luma_remap reads through it.
; Helper-area cost: 10 bytes. ZP cost: 2 bytes (free; cardioid/mirror are
; C64-only and don't conflict).
.if BUILD_LUMA_PALETTE & BUILD_C128
luma_table_ptr = $F4            ; ZP pointer used only on C128
luma_remap:
        LDA iter
        AND #$0F
        TAY
        LDA (luma_table_ptr),Y
        STA iter
        RTS
.endif


;------ BENCH region: benchmark routines ------
; Placed in BENCH region ($1E00-$1FFF, see memory layout at top of file).
; Bounds check at end of region. An earlier mirror_tile routine that originally
; lived here is gone; the region now only holds optional bench code.
.if BUILD_C64
        * = MEM_MIRRORBENCH_BASE
.endif

.if BUILD_BENCHMARK
benchmark_start:
.if BUILD_C64 | BUILD_C128
        LDA #1              ; White: render in progress.
        STA $D020           ; VIC-II border color.
        ; Read CIA1 TOD (latch via hours; release via tenths).
        LDA $DC0B
        STA bench_h0
        LDA $DC0A
        STA bench_m0
        LDA $DC09
        STA bench_s0
        LDA $DC08
        STA bench_t0
        ; Configure CIA1 Timer B as Timer A underflow counter (~60 Hz).
        LDA #$FF
        STA $DC06
        STA $DC07
        LDA #$51            ; CRB: count Timer A underflow, force load, continuous, start
        STA $DC0F
.endif
        RTS

benchmark_end:
.if BUILD_C64 | BUILD_C128
        ; Stop Timer B and read counter (counts down from $FFFF).
        LDA $DC0F
        AND #$FE
        STA $DC0F
        LDA $DC06
        STA bench_tb_l
        LDA $DC07
        STA bench_tb_h
        ; TOD as well (best-effort).
        LDA $DC0B
        STA bench_h1
        LDA $DC0A
        STA bench_m1
        LDA $DC09
        STA bench_s1
        LDA $DC08
        STA bench_t1
        LDA #2              ; Red: render complete.
        STA $D020
.endif
        RTS

bench_h0:   .byte 0
bench_m0:   .byte 0
bench_s0:   .byte 0
bench_t0:   .byte 0
bench_h1:   .byte 0
bench_m1:   .byte 0
bench_s1:   .byte 0
bench_t1:   .byte 0
bench_tb_l: .byte 0
bench_tb_h: .byte 0
.endif




;------ Periodicity check (C64 only) ------
; At iter==4 (post-increment), snapshot (zx, zy) into period_save_zx/zy.
; For iter>4, compare current (zx, zy) against snapshot — exact 4-byte
; equality means we've found a periodic orbit, so the point is in the set.
;
; Caller (inline at INC iter site) filters iter<4 with BCC, so this routine
; is only entered with iter>=4. Returns Z=1 to caller iff periodic.
;
; Snapshot covers periods up to (max_iter - 4). With max_iter=32 that's
; periods 1..28; combined with the cardioid+bulb tests (which already cover
; periods 1 and 2 of the main shapes), this catches higher-order periods
; from mini-Mandelbrots and disconnected components.
.if BUILD_PERIODICITY & BUILD_C64
periodicity_check:
        LDA iter
        CMP #4
        BNE pc_compare         ; iter > 4: compare phase
        ; iter == 4: snapshot (zx, zy)
        LDA zx
        STA period_save_zx
        LDA zx+1
        STA period_save_zx+1
        LDA zy
        STA period_save_zy
        LDA zy+1
        STA period_save_zy+1
pc_no:
        LDA #1                  ; clear Z (not periodic)
        RTS
pc_compare:
        LDA zx
        CMP period_save_zx
        BNE pc_no
        LDA zx+1
        CMP period_save_zx+1
        BNE pc_no
        LDA zy
        CMP period_save_zy
        BNE pc_no
        LDA zy+1
        CMP period_save_zy+1
        ; Z=1 if all four bytes equal (periodic), Z=0 otherwise.
        RTS

period_save_zx: .word 0
period_save_zy: .word 0
.endif

;------ Hi-res contour mode render routines (C64 only) ------
; Placed in BENCH region alongside bench routines.
.if BUILD_HIRES_CONTOUR & BUILD_C64

;--- render_tile_contour ---
; Renders the current 8x8 hi-res tile from buf_iters_hr.
; Each pixel bit = iter & 1 (0 = background, 1 = foreground).
; Packs 8 pixels MSB-first into one bitmap byte, advances bmp_ptr per line.
;
render_tile_contour:
        LDA #<buf_iters_hr
        STA buf_it_ptr
        LDA #>buf_iters_hr
        STA buf_it_ptr+1
        LDY #0              ; iter buffer index
nxt_tile_line_HR:
        ; Collect 8 pixel bits into tmp_A, MSB = leftmost pixel.
        LDA #0
        STA tmp_A
        LDX #8              ; 8 pixels per line
nxt_tile_pix_HR:
        ASL tmp_A           ; shift previous bits up
        LDA (buf_it_ptr),Y
        AND #$01            ; pixel bit = iter LSB
        ORA tmp_A
        STA tmp_A
        INY
        DEX
        BNE nxt_tile_pix_HR
        ; Store byte to bitmap.
        LDA tmp_A
        LDX #0
        STA (bmp_ptr,X)
        INC bmp_ptr
        BNE +
        INC bmp_ptr+1
+
        CPY buf_tile_size   ; 64 for 8x8 tile
        BNE nxt_tile_line_HR
        RTS

.endif ; BUILD_HIRES_CONTOUR & BUILD_C64

.if BUILD_C64
; --- Bounds check: BENCH region must not exceed MEM_MIRRORBENCH_END ---
.cerror *-1 > MEM_MIRRORBENCH_END, "BENCH region overflows ($1E00-$1FFF). Bench code/tables exceeded 512 bytes."
.endif


;------ Main cardioid quick test (C64 only) ------
; The Mandelbrot set's main cardioid (the big heart-shape) covers ~25% of
; the default-view area and contains many max-iter pixels. Detecting them
; analytically saves a huge amount of iteration work.
;
; Test (without sqrt): let q = (cx - 1/4)^2 + cy^2.
; Inside the cardioid iff  q * (q + (cx - 1/4)) < cy^2 / 4.
;
; The cardioid spans roughly cx in [-0.5, 0.5] and |cy| <= 0.7, so we use
; a cheap bbox pre-reject on cx_hi and cy_hi to bail fast for points far
; outside. Within the bbox, magnitudes are small enough that the q*(q+a)
; multiply stays inside Q5.11 range.
;
; Zero-page scratch (well above var_words area which ends at $F3):
;   $F4-$F5: card_a   (cx - 1/4)
;   $F6-$F7: card_q   (a^2 + cy^2)
;   $F8-$F9: card_cy4 (cy^2 / 4)
;
; Clobbers: A, X, Y, x0, x1, y0, y1, z0, z1, z2, z3, $F4-$F9.
;
; PLACEMENT: CARDIOID region (see memory layout at top of file).
; Bounds check at end of routine ensures it doesn't overflow.
.if BUILD_C64
        * = MEM_CARDIOID_BASE
test_cardioid:
        ; Cheap bbox reject on cx_hi: cardioid x-range ≈ [-0.5, 0.5]
        ; → cx_hi in {$FC, $FD, $FE, $FF, $00, $01, $02, $03}.
        LDA cx+1
        CMP #$04
        BCC card_cx_ok      ; cx_hi < $04 → small +
        CMP #$FC
        BCS card_cx_ok      ; cx_hi >= $FC → small -
        JMP card_no         ; otherwise out (use JMP — branch would be too far)
card_cx_ok:
        ; Cheap bbox reject on cy_hi: cardioid y-range ≈ [-0.7, 0.7]
        ; → cy_hi in {$FA, $FB, $FC, $FD, $FE, $FF, $00, $01, $02, $03, $04, $05}.
        LDA cy+1
        CMP #$06
        BCC card_cy_ok      ; cy_hi < $06 → small +
        CMP #$FA
        BCS card_cy_ok      ; cy_hi >= $FA → small -
        JMP card_no
card_cy_ok:
        ; Compute a = cx - 1/4 (Q5.11 subtraction).
        SEC
        LDA cx
        SBC #<$0200
        STA $F4             ; card_a low
        LDA cx+1
        SBC #>$0200
        STA $F5             ; card_a high
        ; Square a → z1, z2.
        LDA $F4
        STA x0
        LDA $F5
        STA x1
        JSR square_Q5_11
        LDA z1              ; save a^2 to card_q (will become q after adding cy^2).
        STA $F6
        LDA z2
        STA $F7
        ; Square cy → z1, z2.
        LDA cy
        STA x0
        LDA cy+1
        STA x1
        JSR square_Q5_11
        ; Save cy^2 / 4 to card_cy4 (right shift z2:z1 by 2, sign-preserving).
        LDA z2
        CMP #$80
        ROR z2
        ROR z1
        CMP #$80
        ROR z2
        ROR z1
        LDA z1
        STA $F8
        LDA z2
        STA $F9
        ; Re-square cy (we destroyed cy^2 by shifting it).
        LDA cy
        STA x0
        LDA cy+1
        STA x1
        JSR square_Q5_11
        ; q = a^2 + cy^2.
        CLC
        LDA z1
        ADC $F6
        STA $F6
        LDA z2
        ADC $F7
        STA $F7
        ; (q + a) → x0, x1
        CLC
        LDA $F6
        ADC $F4
        STA x0
        LDA $F7
        ADC $F5
        STA x1
        ; multiplier = q → y0, y1
        LDA $F6
        STA y0
        LDA $F7
        STA y1
        ; Multiply: z1, z2 = q * (q + a) in Q5.11.
        JSR multiply_Q5_11_signed
        ; Compare z2:z1 < cy^2/4 (in $F9:$F8).
        LDA z2
        CMP $F9
        BCC in_cardioid
        BNE card_no
        LDA z1
        CMP $F8
        BCS card_no
in_cardioid:
        PLA
        PLA
        JMP found_color_black
card_no:
        RTS

; --- Bounds check: CARDIOID region must not exceed MEM_CARDIOID_END ---
.cerror *-1 > MEM_CARDIOID_END, "CARDIOID region overflows ($0C00-$0CFF). test_cardioid grew past 256 bytes."
.endif


;------ Stripe-wise Mariani-Silver border tracing (C64 only) ------
; Renders 40x8 stripes via recursive border tracing. A stripe holds 10
; multicolor cells (4 px each) or 5 contour tiles (8 px each).
; ms_render_stripe_c40 builds one stripe and is called every 10 / 5 tiles;
; cells/tiles are extracted from the stripe buffer.
;
; Algorithm per stripe: trace 92 border samples (40 top + 40 bot + 6 left
; col + 6 right col), check uniformity, and either fill the interior with
; the reference iter or recursively split. Uniform regions (cardioid
; interior, deep exterior) are filled cheaply; near contours we fall back
; to brute-force pixel computation. Threshold #5 keeps brute-force on the
; smallest sub-rectangles so contour detail survives at zoom.
;
; Stripe iter buffer (page-aligned, 40 bytes used per row, rest of page
; unused):
;   row 0 -> $E900..$E927    row 4 -> $ED00..$ED27
;   row 1 -> $EA00..$EA27    row 5 -> $EE00..$EE27
;   row 2 -> $EB00..$EB27    row 6 -> $EF00..$EF27
;   row 3 -> $EC00..$EC27    row 7 -> $F000..$F027
; pixel(x, y) is at ($E900 + y*$0100 + x). Lookups via stripe_row_hi[y]
; for code that doesn't want to inline the +y offset.
;
; cx/cy lookup tables: precomputed once per stripe so each calc_point call
; fetches (cx, cy) by pixel coordinate without redoing the per-pixel ADC
; chain. cx_tbl sized 160 (legacy); only entries 0..39 used.
;
; Zero-page scratch: $FA/$FB used as src pointer (page-aligned, lo=0)
; during cell extraction. Outside the $F4-$F9 range that cardioid uses
; during calc_point.
.if BUILD_MARIANI_SILVER_STRIPE
        * = MEM_STRIPEMS_BASE

; Page-high lookup: row Y of the stripe iter buffer lives at page (E9+y).
stripe_row_hi:
        .byte $E9, $EA, $EB, $EC, $ED, $EE, $EF, $F0

; cx_tbl[x] = t_ax + x*incx. Split-byte for fast X-indexed access
; (LDA cx_tbl_lo,X / LDA cx_tbl_hi,X). Sized 160 (legacy); only entries
; 0..39 used by the c40 path.
cx_tbl_lo:  .fill 160, 0
cx_tbl_hi:  .fill 160, 0
; cy_tbl[y] = t_ay - y*incy, y = 0..7.
cy_tbl_lo:  .fill 8, 0
cy_tbl_hi:  .fill 8, 0

; Scratch state.
stripe_src_off: .byte 0      ; cellx * tile_w — column offset within stripe row
stripe_cellx:   .byte 0      ; cell index within stripe: 0..9 (multicolor) or 0..4 (contour)
stripe_idx:     .byte 0      ; tile index within current stripe; resets at start of each tile row

; Subdivision stack (LIFO of pixel-x ranges). 40-wide stripe with brute-force
; threshold 5 needs ~3 levels deep; 16 leaves plenty of headroom.
ms_stack_x1:    .fill 16, 0
ms_stack_x2:    .fill 16, 0
ms_stack_size:  .byte 0

; Currently-popped rectangle.
cur_x1:         .byte 0      ; left column (inclusive)
cur_x2:         .byte 0      ; right column (inclusive)
cur_ref:        .byte 0      ; reference iter from stripe[x1, 0]
cur_count:      .byte 0      ; x2 - x1 (= width - 1)
cur_count_save: .byte 0      ; loop counter copy for top/bot row scans
cur_mid:        .byte 0      ; midpoint column for current split
cur_y:          .byte 0      ; row counter for fill / brute-force loops
cur_x1_p1:      .byte 0      ; x1+1 (interior left column)

; Single-pixel arguments to ms_compute_pixel.
stripe_pixx:    .byte 0      ; pixel x in stripe (0..39)
stripe_pixy:    .byte 0      ; pixel y in stripe (0..7)


;------ Build per-stripe lookup tables ------
; Caller sets t_ax / t_ay to the upper-left corner of the stripe and
; incx / incy to the per-pixel hi-res increments. We then fill cx_tbl
; for all 160 columns and cy_tbl for all 8 rows.
init_stripe_tables:
        ; cx_tbl[0] = t_ax
        LDA t_ax
        STA cx_tbl_lo
        LDA t_ax+1
        STA cx_tbl_hi
        LDX #0
init_cx_loop:
        CLC
        LDA cx_tbl_lo,X
        ADC incx
        STA cx_tbl_lo+1,X
        LDA cx_tbl_hi,X
        ADC incx+1
        STA cx_tbl_hi+1,X
        INX
        CPX #159              ; stop after writing index 159
        BNE init_cx_loop

        ; cy_tbl[0] = t_ay
        LDA t_ay
        STA cy_tbl_lo
        LDA t_ay+1
        STA cy_tbl_hi
        LDX #0
init_cy_loop:
        SEC
        LDA cy_tbl_lo,X
        SBC incy
        STA cy_tbl_lo+1,X
        LDA cy_tbl_hi,X
        SBC incy+1
        STA cy_tbl_hi+1,X
        INX
        CPX #7                ; stop after writing index 7
        BNE init_cy_loop
        RTS


;------ Copy 32 iters from stripe to buf_iters_hr ------
; Caller sets stripe_cellx (0..39); we copy the 4×8 cell from the stripe
; iter buffer into buf_iters_hr[0..31] in row-major order so the existing
; histogram + render_tile_multicolor code runs unchanged.
ms_extract_cell_from_stripe:
        LDA stripe_cellx
        ASL
        ASL                   ; A = cellx * 4 = src column offset
        STA stripe_src_off
        LDA #0
        STA $FA               ; src ptr lo (rows are page-aligned)
        LDA #$E9
        STA $FB               ; src ptr hi (start at row 0's page)
        LDX #0                ; dst index into buf_iters_hr (0..31)
ext_row_loop:
        LDY stripe_src_off
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INX
        INC $FB               ; advance src to next row's page
        CPX #32
        BNE ext_row_loop
        RTS


;------ Copy 64 iters from stripe to buf_iters_hr (contour: 8×8 cell) ------
; Like ms_extract_cell_from_stripe but for the 8-px-wide contour cells.
; Caller sets stripe_cellx (0..19, local index within the active half-stripe);
; we copy 8 columns × 8 rows = 64 bytes into buf_iters_hr in row-major order.
.if BUILD_HIRES_CONTOUR
ms_extract_cell_from_stripe_contour:
        LDA stripe_cellx
        ASL
        ASL
        ASL                   ; A = stripe_cellx * 8 = src column offset
        STA stripe_src_off
        LDA #0
        STA $FA               ; src ptr lo (rows are page-aligned)
        LDA #$E9
        STA $FB               ; src ptr hi (start at row 0's page)
        LDX #0                ; dst index into buf_iters_hr (0..63)
ext_c_row_loop:
        LDY stripe_src_off
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INY
        INX
        LDA ($FA),Y
        STA buf_iters_hr,X
        INX
        INC $FB               ; advance src to next row's page
        CPX #64
        BNE ext_c_row_loop
        RTS
.endif


;------ Compute one stripe pixel via calc_point ------
; Reads stripe_pixx and stripe_pixy, fetches (cx, cy) from cx_tbl/cy_tbl,
; aims buf_it_ptr at the matching cell in the stripe iter buffer (which
; is page-aligned: high byte = $E9 + pixy, low byte = pixx), then JSRs
; calc_point with ms_callable=1 so it returns via RTS at skip_ColorRAM
; rather than falling through to nxt_point.
ms_compute_pixel:
        LDX stripe_pixx
        LDA cx_tbl_lo,X
        STA cx
        LDA cx_tbl_hi,X
        STA cx+1
        LDX stripe_pixy
        LDA cy_tbl_lo,X
        STA cy
        LDA cy_tbl_hi,X
        STA cy+1
        LDA stripe_pixx
        STA buf_it_ptr
        CLC
        LDA stripe_pixy
        ADC #$E9
        STA buf_it_ptr+1
        LDA #1
        STA ms_callable
        JSR calc_point
        LDA #0
        STA ms_callable
        RTS


;------ Iterative subdivision (shared by all stripe renderers) ------
; Caller seeds ms_stack_x1[0]/x2[0] with the initial rectangle and
; ms_stack_size = 1, then JMPs here. The stripe buffer must already
; contain border samples for this rectangle.
;
; Algorithm per popped rectangle (x1, x2), width = x2-x1+1:
;   * If width <= 5: brute-force compute all interior pixels.
;   * Else check uniformity of all four borders (top row, bot row,
;     left col, right col). All four are guaranteed to already be in
;     the stripe buffer at this point (top/bot from border trace, side cols
;     from border trace for the initial rect or from a prior split column
;     for sub-rects).
;   * Uniform → fill the interior rows 1..6, columns x1+1..x2-1 with
;     the reference iter. No further computation required.
;   * Non-uniform → split at mid = x1 + (x2-x1)/2, compute the 6 new
;     pixels in column mid (rows 1..6), push (mid, x2) then (x1, mid)
;     so the left half is processed first.
;
; Splits share their boundary column so each new column is computed
; exactly once across the whole subdivision tree. ms_subdiv_done returns
; via RTS to the original ms_render_stripe_c40 caller.
ms_subdiv_loop:
        LDX ms_stack_size
        BNE +
        JMP ms_subdiv_done
+
        DEX
        STX ms_stack_size
        LDA ms_stack_x1,X
        STA cur_x1
        LDA ms_stack_x2,X
        STA cur_x2

        ; cur_count = x2 - x1 (= width - 1)
        SEC
        LDA cur_x2
        SBC cur_x1
        STA cur_count
        ; If width <= 5 (i.e., x2-x1 <= 4), brute-force.
        ; Threshold #3 was tested and gave ~1-2 % more speedup, but caused
        ; visible artifacts when zoomed in (8×160 stripes filled with a
        ; single color from MS uniformity false-positives that brute-forcing
        ; smaller sub-rects had previously masked). #5 is the safer setting.
        CMP #5
        BCS +
        JMP ms_brute
+

        ; Reference = stripe[x1, 0]
        LDX cur_x1
        LDA $E900,X
        STA cur_ref

        ; Check top row x1+1..x2 uniform (x1 == cur_ref by definition, skip it)
        SEC
        LDA cur_count
        SBC #1
        STA cur_count_save
        LDX cur_x1
        INX                  ; start at x1+1
ms_chk_top:
        LDA $E900,X
        CMP cur_ref
        BEQ +
        JMP ms_split
+
        INX
        DEC cur_count_save
        BPL ms_chk_top

        ; Check bot row x1+1..x2 uniform (row 7 lives on page $F0)
        SEC
        LDA cur_count
        SBC #1
        STA cur_count_save
        LDX cur_x1
        INX                  ; start at x1+1
ms_chk_bot:
        LDA $F000,X
        CMP cur_ref
        BEQ +
        JMP ms_split
+
        INX
        DEC cur_count_save
        BPL ms_chk_bot

        ; Check left col (x=cur_x1, y=1..6) uniform
        LDA cur_x1
        STA $FA              ; src ptr lo
        LDY #0
        LDX #1               ; row index
ms_chk_left:
        LDA stripe_row_hi,X
        STA $FB              ; src ptr hi for this row
        LDA ($FA),Y
        CMP cur_ref
        BEQ +
        JMP ms_split
+
        INX
        CPX #7
        BNE ms_chk_left

        ; Check right col (x=cur_x2, y=1..6) uniform
        LDA cur_x2
        STA $FA
        LDY #0
        LDX #1
ms_chk_right:
        LDA stripe_row_hi,X
        STA $FB
        LDA ($FA),Y
        CMP cur_ref
        BEQ +
        JMP ms_split
+
        INX
        CPX #7
        BNE ms_chk_right

        ; --- All borders uniform → fill interior rows 1..6, cols x1+1..x2-1 ---
        LDA cur_x1
        CLC
        ADC #1
        STA cur_x1_p1
        ; cur_x2 used as the loop terminator (write while Y < x2)
        LDA #1
        STA cur_y
ms_fill_row:
        LDX cur_y
        LDA stripe_row_hi,X
        STA $FB
        LDA #0
        STA $FA
        LDA cur_ref
        LDY cur_x1_p1
ms_fill_inner:
        STA ($FA),Y
        INY
        CPY cur_x2
        BNE ms_fill_inner
        INC cur_y
        LDA cur_y
        CMP #7
        BNE ms_fill_row
        JMP ms_subdiv_loop

ms_split:
        ; mid = x1 + (x2 - x1) / 2  (avoids byte-overflow of x1+x2)
        LDA cur_x2
        SEC
        SBC cur_x1
        LSR
        CLC
        ADC cur_x1
        STA cur_mid
        ; Compute 6 new pixels at column mid (rows 1..6)
        LDA cur_mid
        STA stripe_pixx
        LDA #1
        STA stripe_pixy
ms_trace_mid:
        JSR ms_compute_pixel
        INC stripe_pixy
        LDA stripe_pixy
        CMP #7
        BNE ms_trace_mid
        ; Push (mid, x2) then (x1, mid) so left half is processed first
        LDX ms_stack_size
        LDA cur_mid
        STA ms_stack_x1,X
        LDA cur_x2
        STA ms_stack_x2,X
        INX
        LDA cur_x1
        STA ms_stack_x1,X
        LDA cur_mid
        STA ms_stack_x2,X
        INX
        STX ms_stack_size
        JMP ms_subdiv_loop

ms_brute:
        ; width <= 5 → compute interior cols (x1+1..x2-1) × rows 1..6.
        ; If x2-x1 < 2 there is no interior column at all.
        LDA cur_count
        CMP #2
        BCC ms_brute_done
        LDA cur_x1
        CLC
        ADC #1
        STA stripe_pixx
ms_brute_col:
        LDA #1
        STA stripe_pixy
ms_brute_row:
        JSR ms_compute_pixel
        INC stripe_pixy
        LDA stripe_pixy
        CMP #7
        BNE ms_brute_row
        INC stripe_pixx
        LDA stripe_pixx
        CMP cur_x2
        BNE ms_brute_col
ms_brute_done:
        JMP ms_subdiv_loop

ms_subdiv_done:
        RTS

;------ 40-pixel-wide stripe MS (used by both contour and multicolor) ------
; Builds a 40×8 stripe. For contour: 5 tiles × 8 px = 40 wide, called every
; 5 tiles. For multicolor: 10 tiles × 4 px = 40 wide, called every 10 tiles.
; Reuses init_stripe_tables (extra cx_tbl entries 40..159 unused, harmless),
; ms_compute_pixel, and the subdivision/brute-force/fill machinery.
; Caller sets t_ax to the leftmost cx of the stripe.
ms_render_stripe_c40:
        JSR init_stripe_tables

        ; Top row (y=0): 40 pixels
        LDA #0
        STA stripe_pixy
        STA stripe_pixx
ms_trace_top_c40:
        JSR ms_compute_pixel
        INC stripe_pixx
        LDA stripe_pixx
        CMP #40
        BNE ms_trace_top_c40

        ; Bot row (y=7): 40 pixels
        LDA #7
        STA stripe_pixy
        LDA #0
        STA stripe_pixx
ms_trace_bot_c40:
        JSR ms_compute_pixel
        INC stripe_pixx
        LDA stripe_pixx
        CMP #40
        BNE ms_trace_bot_c40

        ; Left col (x=0, y=1..6): 6 pixels
        LDA #0
        STA stripe_pixx
        LDA #1
        STA stripe_pixy
ms_trace_left_c40:
        JSR ms_compute_pixel
        INC stripe_pixy
        LDA stripe_pixy
        CMP #7
        BNE ms_trace_left_c40

        ; Right col (x=39, y=1..6): 6 pixels
        LDA #39
        STA stripe_pixx
        LDA #1
        STA stripe_pixy
ms_trace_right_c40:
        JSR ms_compute_pixel
        INC stripe_pixy
        LDA stripe_pixy
        CMP #7
        BNE ms_trace_right_c40

        ; Push initial rect (0, 39), then reuse ms_subdiv_loop.
        ; ms_subdiv_done's RTS returns to our caller.
        LDA #0
        STA ms_stack_x1
        LDA #39
        STA ms_stack_x2
        LDA #1
        STA ms_stack_size
        JMP ms_subdiv_loop


; --- Bounds check: STRIPEMS region must not exceed MEM_STRIPEMS_END ---
.cerror *-1 > MEM_STRIPEMS_END, "STRIPEMS region overflows ($0D00-$1DFF). Stripe MS code+tables exceeded 4352 bytes."
.endif


END_ADDRESS:
    
