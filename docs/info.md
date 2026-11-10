<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This is a self-contained Tetris game that draws a 640x480 VGA picture and is
controlled with a PMOD gamepad. It is built from three Verilog files:

- `hvsync_generator.v` derives the VGA timing from the 25.175 MHz pixel clock.
  A frame is 800x525 pixels: 640x480 visible, 16/48 pixel horizontal front/back
  porch, 96 pixel horizontal sync, and 10/33 line vertical front/back porch with
  a 2 line vertical sync. `hpos`/`vpos` are the beam position, and `display_on`
  marks the visible area.
- `gamepad_pmod.v` implements the serial protocol of the PMOD gamepad
  (`pmod_latch`, `pmod_clk`, `pmod_data`), debounces nothing itself and exposes
  the 12 button bits (`b`, `y`, `select`, `start`, `up`, `down`, `left`, `right`,
  `a`, `x`, `l`, `r`) plus an `is_present` flag.
- `project.v` contains the game. The playfield is 10 columns x 20 rows, with
  each cell drawn as 32x24 pixels (320 px wide, 480 px tall) and centred
  horizontally. Every cell stores a 3 bit colour ID,
  split over three 10 bit bitplanes (`board_0/1/2`), so the colour of a cell is
  just three parallel 1 bit RAM reads.

A 4x4 "piece box" is described by a `piece_cell` function that returns the
bitmap of one of the 7 tetrominoes for any of its 4 rotations. Movement,
rotation, line clears and spawn collisions are all checked the same way: the
state machine (`TITLE`, `PLAY`, `CHECK`, `LOCK`, `CLEAR`, `SHIFT`, `SPAWN`,
`OVER`) scans the 16 cells of the candidate box and compares them against the
bitplanes and the board edges.

The buttons are sampled once per frame (`frame_tick`, when `hpos`/`vpos` wrap),
so all game logic runs at the frame rate regardless of the pixel clock. Left and
right auto-repeat after a short delay, and holding *down* reduces the gravity
divider from 29 frames per row to 2 (soft drop). When a row is full, the rows
above it are shifted down and the top row is cleared.

The output byte is the standard TinyVGA PMOD colour mapping:
`uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]}`, so each channel
has 4 levels (2 bits) and 64 colours are possible. `uio_out`/`uio_oe` are tied
low, and `ena` is ignored.

## How to test

In simulation, `cd test && make` runs the cocotb testbench with Icarus
Verilog. It applies reset, then captures three complete frames through the VGA
output, checking the `hsync`/`vsync` polarity, pulse width and position of every
line on the way, and saves the captured frames as PNG images in
`test/output/`. Note that `hvsync_generator` registers `hsync`/`vsync`, so the
testbench compares them one clock late relative to `hpos`/`vpos`. If a
`test/reference/` directory with `frame0.png`, `frame1.png`, ... is present, the
`compare_reference` test also diffs the rendered frames against those golden
images.

On hardware, plug the Tiny VGA PMOD into `uo[7:0]` and a PMOD gamepad into
`ui[4]` (latch), `ui[5]` (clock) and `ui[6]` (data). After reset the design
shows the title screen; press *Start* to begin a game, then use left/right to
move, up to rotate, and down to soft drop a piece.

## External hardware

- [Tiny VGA PMOD](https://tinytapeout.com/specs/pinouts/#vga-output) (or a
  resistor ladder VGA DAC on `uo[7:0]`)
- PMOD gamepad (or any controller using the same 3 wire shift-register
  protocol)
