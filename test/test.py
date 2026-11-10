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
    H_TOTAL = H_DISPLAY + H_FRONT + H_SYNC + H_BACK
    V_TOTAL = V_DISPLAY + V_FRONT + V_SYNC + V_BACK

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

    # hvsync_generator registers hsync/vsync from hpos/vpos, so the sync
    # outputs are one clock behind the pixel counters, and the exact phase the
    # testbench observes also depends on where the capture starts. Instead of
    # hard-coding that phase, measure the sync pattern on the first line/frame
    # and then require every following line/frame to match it exactly.
    hsync_offset = None
    vsync_offset = None

    async def sample_line():
        """Read H_TOTAL pixels of uo_out -> (hsync bits, mid-line vsync, px)."""
        hsync = []
        pixels = bytearray(H_DISPLAY * 3)
        vsync_mid = 1
        for i in range(H_TOTAL):
            value = int(dut.uo_out.value)
            hsync.append((value >> 7) & 1)
            if i < H_DISPLAY:
                pixels[3*i:3*i+3] = palette[value]
            if i == H_TOTAL // 2:
                vsync_mid = (value >> 3) & 1
            await ClockCycles(dut.clk, 1)
        return hsync, vsync_mid, pixels

    def check_hsync(hsync, line):
        nonlocal hsync_offset
        zeros = [i for i, b in enumerate(hsync) if b == 0]
        assert len(zeros) == H_SYNC, (
            f"line {line}: hsync was low for {len(zeros)} pixels, expected {H_SYNC}"
        )
        start = zeros[0]
        assert zeros[-1] - start + 1 == H_SYNC, (
            f"line {line}: hsync pulse is not contiguous (starts at {start}, "
            f"last low pixel at {zeros[-1]})"
        )
        if hsync_offset is None:
            hsync_offset = start
            dut._log.info(f"hsync pulse starts at pixel {start} of every line")
        else:
            assert start == hsync_offset, (
                f"line {line}: hsync pulse moved to pixel {start}, "
                f"expected {hsync_offset}"
            )

    def check_vsync(vsync_lines, frame_num):
        nonlocal vsync_offset
        low = [i for i, b in enumerate(vsync_lines) if b == 0]
        assert len(low) == V_SYNC, (
            f"frame {frame_num}: vsync was low for {len(low)} lines, "
            f"expected {V_SYNC}"
        )
        assert low[-1] - low[0] + 1 == V_SYNC, (
            f"frame {frame_num}: vsync lines are not contiguous"
        )
        assert low[0] >= V_DISPLAY, (
            f"frame {frame_num}: vsync pulse overlaps the visible lines "
            f"(starts at line {low[0]})"
        )
        if vsync_offset is None:
            vsync_offset = low[0]
            dut._log.info(f"vsync pulse starts at line {low[0]} of every frame")
        else:
            assert low[0] == vsync_offset, (
                f"frame {frame_num}: vsync pulse moved to line {low[0]}, "
                f"expected {vsync_offset}"
            )

    async def capture_frame(frame_num):
        framebuffer = bytearray(V_DISPLAY*H_DISPLAY*3)
        vsync_lines = []
        for line in range(V_TOTAL):
            hsync, vsync_mid, pixels = await sample_line()
            check_hsync(hsync, line)
            vsync_lines.append(vsync_mid)
            if line < V_DISPLAY:
                if line % 120 == 0:
                    dut._log.info(f"Frame {frame_num}, line {line} (display)")
                framebuffer[3*line*H_DISPLAY:3*(line+1)*H_DISPLAY] = pixels
        check_vsync(vsync_lines, frame_num)
        return Image.frombytes('RGB', (H_DISPLAY, V_DISPLAY), bytes(framebuffer))

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
