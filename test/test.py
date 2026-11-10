import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

import os
import glob
import itertools
from PIL import Image, ImageChops


@cocotb.test()
async def test_project(dut):

    # Set clock period to 40 ns (25 MHz)
    CLOCK_PERIOD = 40

    # Set VGA timing parameters matching hvsync_generator.v
    H_DISPLAY = 640
    H_FRONT   =  16
    H_SYNC    =  96
    H_BACK    =  48
    V_DISPLAY = 480
    V_FRONT   =  10
    V_SYNC    =   2
    V_BACK    =  33

    # Number of frames to capture
    CAPTURE_FRAMES = 3

    # Derived constants
    H_SYNC_START = H_DISPLAY + H_FRONT
    H_SYNC_END = H_SYNC_START + H_SYNC
    H_TOTAL = H_SYNC_END + H_BACK
    V_SYNC_START = V_DISPLAY + V_FRONT
    V_SYNC_END = V_SYNC_START + V_SYNC
    V_TOTAL = V_SYNC_END + V_BACK

    # hvsync_generator registers hsync/vsync from hpos/vpos, so the sync
    # outputs are always one clock behind the counters they come from.
    SYNC_LATENCY = 1

    def expected_hsync(i):
        return 0 if H_SYNC_START <= i - SYNC_LATENCY < H_SYNC_END else 1

    def expected_vsync(line, i):
        # On the first pixel of a line vsync still reflects the previous line.
        v = (line - 1) % V_TOTAL if i == 0 else line
        return 0 if V_SYNC_START <= v < V_SYNC_END else 1

    # Palette mapping uo_out values to RGB color
    # uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]}
    palette = [bytes(3)] * 256
    for r1, r0, g1, g0, b1, b0 in itertools.product(range(2), repeat=6):
        red = 170*r1 + 85*r0
        green = 170*g1 + 85*g0
        blue = 170*b1 + 85*b0
        color_index = b0<<6|g0<<5|r0<<4|b1<<2|g1<<1|r1<<0
        for sync_bits in (0x00, 0x08, 0x80, 0x88):
            palette[color_index | sync_bits] = bytes((red, green, blue))

    # Set up the clock
    clock = Clock(dut.clk, CLOCK_PERIOD, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset the design
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    # Releasing reset leaves hpos=0 and vpos=0, so the next read is pixel 0 of
    # line 0. Waiting extra clocks here would shift the whole capture.

    # Define some functions for capturing lines & frames

    async def check_line(line):
        for i in range(H_TOTAL):
            hsync = int(dut.uo_out.value[7])
            vsync = int(dut.uo_out.value[3])
            assert hsync == expected_hsync(i), "Unexpected hsync pattern"
            assert vsync == expected_vsync(line, i), "Unexpected vsync pattern"
            await ClockCycles(dut.clk, 1)

    async def capture_line(framebuffer, line):
        for i in range(H_TOTAL):
            hsync = int(dut.uo_out.value[7])
            vsync = int(dut.uo_out.value[3])
            assert hsync == expected_hsync(i), "Unexpected hsync pattern"
            assert vsync == expected_vsync(line, i), "Unexpected vsync pattern"
            if i < H_DISPLAY:
                offset = 3 * line * H_DISPLAY + 3 * i
                framebuffer[offset:offset+3] = palette[int(dut.uo_out.value)]
            await ClockCycles(dut.clk, 1)

    async def skip_frame(frame_num):
        dut._log.info(f"Skipping frame {frame_num}")
        await ClockCycles(dut.clk, H_TOTAL*V_TOTAL)

    async def capture_frame(frame_num):
        framebuffer = bytearray(V_DISPLAY*H_DISPLAY*3)
        for line in range(V_DISPLAY):
            dut._log.info(f"Frame {frame_num}, line {line} (display)")
            await capture_line(framebuffer, line)
        for line in range(V_DISPLAY, V_SYNC_START):
            dut._log.info(f"Frame {frame_num}, line {line} (front porch)")
            await check_line(line)
        for line in range(V_SYNC_START, V_SYNC_END):
            dut._log.info(f"Frame {frame_num}, line {line} (sync pulse)")
            await check_line(line)
        for line in range(V_SYNC_END, V_TOTAL):
            dut._log.info(f"Frame {frame_num}, line {line} (back porch)")
            await check_line(line)
        frame = Image.frombytes('RGB', (H_DISPLAY, V_DISPLAY), bytes(framebuffer))
        return frame

    # Start capturing

    os.makedirs("output", exist_ok=True)

    for i in range(CAPTURE_FRAMES):
        frame = await capture_frame(i)
        frame.save(f"output/frame{i}.png")


@cocotb.test()
async def compare_reference(dut):
    images = sorted(glob.glob("output/frame*.png"))
    references = sorted(glob.glob("reference/frame*.png"))

    if not references:
        dut._log.warning(
            "No reference frames in test/reference/ - skipping comparison. "
            "Copy output/frame*.png there to enable the golden image check."
        )
        return

    for img in images:
        basename = img.removeprefix("output/")
        ref_path = f"reference/{basename}"
        if not os.path.exists(ref_path):
            dut._log.warning(f"No reference image for {basename} - skipping")
            continue
        dut._log.info(f"Comparing {basename} to reference image")
        frame = Image.open(img)
        ref = Image.open(ref_path)
        diff = ImageChops.difference(frame, ref)
        if diff.getbbox() is not None:
            diff.save(f"output/diff_{basename}")
            assert False, f"Rendered {basename} differs from reference image"
