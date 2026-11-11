`default_nettype none

module tt_um_vga_example (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // Playground VGA timing: one clock per pixel.
    wire hsync;
    wire vsync;
    wire display_on;
    wire [9:0] pix_x;
    wire [9:0] pix_y;

    hvsync_generator hvsync_gen (
        .clk        (clk),
        .reset      (~rst_n),
        .hsync      (hsync),
        .vsync      (vsync),
        .display_on (display_on),
        .hpos       (pix_x),
        .vpos       (pix_y)
    );

    wire frame_tick = (pix_x == 10'd0) && (pix_y == 10'd0);

    // Gamepad wiring from the supplied Playground preset.
    wire pad_left;
    wire pad_right;
    wire pad_up;
    wire pad_down;
    wire pad_start;

    gamepad_pmod_single gamepad (
        .rst_n      (rst_n),
        .clk        (clk),
        .pmod_data  (ui_in[6]),
        .pmod_clk   (ui_in[5]),
        .pmod_latch (ui_in[4]),
        .b          (),
        .y          (),
        .select     (),
        .start      (pad_start),
        .up         (pad_up),
        .down       (pad_down),
        .left       (pad_left),
        .right      (pad_right),
        .a          (),
        .x          (),
        .l          (),
        .r          (),
        .is_present ()
    );

    // Button bits: left, right, rotate, soft drop, start.
    wire [4:0] pad_buttons = {
        pad_start, pad_down, pad_up, pad_right, pad_left
    };

    reg [4:0] button_sample;
    reg [4:0] button_stable;
    reg [4:0] button_previous;

    always @(posedge clk) begin
        if (!rst_n) begin
            button_sample   <= 5'b00000;
            button_stable   <= 5'b00000;
            button_previous <= 5'b00000;
        end else if (frame_tick) begin
            button_sample <= pad_buttons;

            // Change a debounced bit only after two matching samples.
            button_stable <=
                (button_stable & (pad_buttons ^ button_sample)) |
                (button_sample & ~(pad_buttons ^ button_sample));

            button_previous <= button_stable;
        end
    end

    wire [4:0] button_pressed = button_stable & ~button_previous;

    // Left/right repeat after an initial delay.
    reg [4:0] move_repeat;

    always @(posedge clk) begin
        if (!rst_n) begin
            move_repeat <= 5'd0;
        end else if (frame_tick) begin
            if (button_stable[0] == button_stable[1])
                move_repeat <= 5'd0;
            else if (move_repeat == 5'd15)
                move_repeat <= 5'd12;
            else
                move_repeat <= move_repeat + 5'd1;
        end
    end

    wire repeat_move = (move_repeat == 5'd15);

    wire move_left =
        button_stable[0] && !button_stable[1] &&
        (button_pressed[0] || repeat_move);

    wire move_right =
        button_stable[1] && !button_stable[0] &&
        (button_pressed[1] || repeat_move);

    // Three bitplanes store a color ID per board cell.
    // ID 0 is empty; IDs 1 through 7 identify the tetrominoes.
    reg [9:0] board_0 [0:19];
    reg [9:0] board_1 [0:19];
    reg [9:0] board_2 [0:19];

    localparam [2:0] PLAY  = 3'd0;
    localparam [2:0] CHECK = 3'd1;
    localparam [2:0] LOCK  = 3'd2;
    localparam [2:0] CLEAR = 3'd3;
    localparam [2:0] SHIFT = 3'd4;
    localparam [2:0] SPAWN = 3'd5;
    localparam [2:0] OVER  = 3'd6;
    localparam [2:0] TITLE = 3'd7;

    localparam [1:0] CHECK_MOVE  = 2'd0;
    localparam [1:0] CHECK_FALL  = 2'd1;
    localparam [1:0] CHECK_SPAWN = 2'd2;

    reg [2:0] state;
    reg [1:0] check_reason;

    reg [2:0] piece_kind;
    reg [1:0] piece_rotation;

    // Signed x allows empty columns of the 4x4 piece box to
    // extend beyond the left edge.
    reg signed [4:0] piece_x;
    reg [4:0] piece_y;

    reg [2:0] candidate_kind;
    reg [1:0] candidate_rotation;
    reg signed [4:0] candidate_x;
    reg [4:0] candidate_y;

    // Four bits select one cell of the 4x4 piece box.
    reg [3:0] scan_cell;
    reg [4:0] clear_row;
    reg [4:0] shift_row;
    reg [5:0] fall_count;

    wire [2:0] next_kind =
        (piece_kind == 3'd6) ? 3'd0 : piece_kind + 3'd1;

    wire [2:0] piece_color = piece_kind + 3'd1;

    wire [5:0] fall_limit =
        button_stable[3] ? 6'd2 : 6'd29;

    function piece_cell;
        input [2:0] kind;
        input [1:0] rotation;
        input [1:0] x;
        input [1:0] y;
        reg [15:0] bitmap;
        reg [1:0] base_x;
        reg [1:0] base_y;
        reg [3:0] bit_index;
        begin
            case (kind)
                3'd0: bitmap = 16'h00F0; // I
                3'd1: bitmap = 16'h0066; // O
                3'd2: bitmap = 16'h0072; // T
                3'd3: bitmap = 16'h0036; // S
                3'd4: bitmap = 16'h0063; // Z
                3'd5: bitmap = 16'h0071; // J
                3'd6: bitmap = 16'h0074; // L
                default: bitmap = 16'h0000;
            endcase

            if (kind == 3'd1) begin
                base_x = x;
                base_y = y;
            end else begin
                case (rotation)
                    2'd0: begin
                        base_x = x;
                        base_y = y;
                    end
                    2'd1: begin
                        base_x = y;
                        base_y = 2'd3 - x;
                    end
                    2'd2: begin
                        base_x = 2'd3 - x;
                        base_y = 2'd3 - y;
                    end
                    default: begin
                        base_x = 2'd3 - y;
                        base_y = x;
                    end
                endcase
            end

            bit_index = {base_y, base_x};
            piece_cell = bitmap[bit_index];
        end
    endfunction

    wire [1:0] scan_x = scan_cell[1:0];
    wire [1:0] scan_y = scan_cell[3:2];

    // Extra signed bit prevents boundary sums from wrapping.
    wire signed [5:0] check_x =
        $signed({candidate_x[4], candidate_x}) +
        $signed({4'b0000, scan_x});

    wire [5:0] check_y =
        {1'b0, candidate_y} + {4'b0000, scan_y};

    wire candidate_cell = piece_cell(
        candidate_kind, candidate_rotation, scan_x, scan_y
    );

    reg collision;
    always @* begin
        collision = 1'b0;

        if (candidate_cell) begin
            if ((check_x < 6'sd0) ||
                (check_x >= 6'sd10) ||
                (check_y >= 6'd20)) begin
                collision = 1'b1;
            end else begin
                collision =
                    board_0[check_y[4:0]][check_x[3:0]] |
                    board_1[check_y[4:0]][check_x[3:0]] |
                    board_2[check_y[4:0]][check_x[3:0]];
            end
        end
    end

    wire signed [5:0] lock_x =
        $signed({piece_x[4], piece_x}) +
        $signed({4'b0000, scan_x});

    wire [5:0] lock_y =
        {1'b0, piece_y} + {4'b0000, scan_y};

    wire current_cell = piece_cell(
        piece_kind, piece_rotation, scan_x, scan_y
    );

    function [9:0] column_mask;
        input [3:0] column;
        begin
            case (column)
                4'd0: column_mask = 10'b0000000001;
                4'd1: column_mask = 10'b0000000010;
                4'd2: column_mask = 10'b0000000100;
                4'd3: column_mask = 10'b0000001000;
                4'd4: column_mask = 10'b0000010000;
                4'd5: column_mask = 10'b0000100000;
                4'd6: column_mask = 10'b0001000000;
                4'd7: column_mask = 10'b0010000000;
                4'd8: column_mask = 10'b0100000000;
                4'd9: column_mask = 10'b1000000000;
                default: column_mask = 10'b0000000000;
            endcase
        end
    endfunction

    wire [9:0] locked_row =
        board_0[clear_row] |
        board_1[clear_row] |
        board_2[clear_row];

    wire start_game =
        frame_tick && button_pressed[4] &&
        ((state == TITLE) || (state == OVER));

    integer row;
    always @(posedge clk) begin
        if (!rst_n || start_game) begin
            for (row = 0; row < 20; row = row + 1) begin
                board_0[row] <= 10'b0000000000;
                board_1[row] <= 10'b0000000000;
                board_2[row] <= 10'b0000000000;
            end

            if (!rst_n)
                state <= TITLE;
            else
                state <= PLAY;

            check_reason       <= CHECK_MOVE;
            piece_kind         <= 3'd0;
            piece_rotation     <= 2'd0;
            piece_x            <= 5'sd3;
            piece_y            <= 5'd0;
            candidate_kind     <= 3'd0;
            candidate_rotation <= 2'd0;
            candidate_x        <= 5'sd0;
            candidate_y        <= 5'd0;
            scan_cell          <= 4'd0;
            clear_row          <= 5'd19;
            shift_row          <= 5'd0;
            fall_count         <= 6'd0;
        end else begin
            case (state)
                TITLE: begin
                    // Wait for Start.
                end

                PLAY: begin
                    if (frame_tick) begin
                        if (fall_count < fall_limit)
                            fall_count <= fall_count + 6'd1;

                        // Movement takes priority over gravity this frame.
                        if (button_pressed[2]) begin
                            candidate_kind     <= piece_kind;
                            candidate_rotation <= piece_rotation + 2'd1;
                            candidate_x        <= piece_x;
                            candidate_y        <= piece_y;
                            check_reason       <= CHECK_MOVE;
                            scan_cell          <= 4'd0;
                            state              <= CHECK;
                        end else if (move_left &&
                                     (piece_x > -5'sd3)) begin
                            candidate_kind     <= piece_kind;
                            candidate_rotation <= piece_rotation;
                            candidate_x        <= piece_x - 5'sd1;
                            candidate_y        <= piece_y;
                            check_reason       <= CHECK_MOVE;
                            scan_cell          <= 4'd0;
                            state              <= CHECK;
                        end else if (move_right) begin
                            candidate_kind     <= piece_kind;
                            candidate_rotation <= piece_rotation;
                            candidate_x        <= piece_x + 5'sd1;
                            candidate_y        <= piece_y;
                            check_reason       <= CHECK_MOVE;
                            scan_cell          <= 4'd0;
                            state              <= CHECK;
                        end else if (fall_count >= fall_limit) begin
                            fall_count         <= 6'd0;
                            candidate_kind     <= piece_kind;
                            candidate_rotation <= piece_rotation;
                            candidate_x        <= piece_x;
                            candidate_y        <= piece_y + 5'd1;
                            check_reason       <= CHECK_FALL;
                            scan_cell          <= 4'd0;
                            state              <= CHECK;
                        end
                    end
                end

                CHECK: begin
                    // Examine one candidate cell per clock.
                    if (collision) begin
                        if (check_reason == CHECK_FALL) begin
                            scan_cell <= 4'd0;
                            state <= LOCK;
                        end else if (check_reason == CHECK_SPAWN) begin
                            state <= OVER;
                        end else begin
                            state <= PLAY;
                        end
                    end else if (scan_cell == 4'd15) begin
                        piece_kind     <= candidate_kind;
                        piece_rotation <= candidate_rotation;
                        piece_x        <= candidate_x;
                        piece_y        <= candidate_y;
                        state          <= PLAY;
                    end else begin
                        scan_cell <= scan_cell + 4'd1;
                    end
                end

                LOCK: begin
                    // Set one cell's color ID per clock.
                    if (current_cell &&
                        (lock_x >= 6'sd0) &&
                        (lock_x < 6'sd10) &&
                        (lock_y < 6'd20)) begin
                        board_0[lock_y[4:0]] <=
                            board_0[lock_y[4:0]] |
                            (piece_color[0] ?
                             column_mask(lock_x[3:0]) : 10'b0);

                        board_1[lock_y[4:0]] <=
                            board_1[lock_y[4:0]] |
                            (piece_color[1] ?
                             column_mask(lock_x[3:0]) : 10'b0);

                        board_2[lock_y[4:0]] <=
                            board_2[lock_y[4:0]] |
                            (piece_color[2] ?
                             column_mask(lock_x[3:0]) : 10'b0);
                    end

                    if (scan_cell == 4'd15) begin
                        clear_row <= 5'd19;
                        state <= CLEAR;
                    end else begin
                        scan_cell <= scan_cell + 4'd1;
                    end
                end

                CLEAR: begin
                    if (locked_row == 10'b1111111111) begin
                        shift_row <= clear_row;
                        state <= SHIFT;
                    end else if (clear_row == 5'd0) begin
                        state <= SPAWN;
                    end else begin
                        clear_row <= clear_row - 5'd1;
                    end
                end

                SHIFT: begin
                    // Move all color planes together.
                    if (shift_row == 5'd0) begin
                        board_0[0] <= 10'b0000000000;
                        board_1[0] <= 10'b0000000000;
                        board_2[0] <= 10'b0000000000;
                        state <= CLEAR;
                    end else begin
                        board_0[shift_row] <= board_0[shift_row - 5'd1];
                        board_1[shift_row] <= board_1[shift_row - 5'd1];
                        board_2[shift_row] <= board_2[shift_row - 5'd1];
                        shift_row <= shift_row - 5'd1;
                    end
                end

                SPAWN: begin
                    candidate_kind     <= next_kind;
                    candidate_rotation <= 2'd0;
                    candidate_x        <= 5'sd3;
                    candidate_y        <= 5'd0;
                    check_reason       <= CHECK_SPAWN;
                    scan_cell          <= 4'd0;
                    fall_count         <= 6'd0;
                    state              <= CHECK;
                end

                OVER: begin
                    // Wait for a fresh Start press.
                end

                default: begin
                    state <= TITLE;
                end
            endcase
        end
    end

    // Board: 10 columns of 32 pixels, 20 rows of 24 pixels.
    // It fills the visible height and is centered horizontally.
    wire in_board =
        (pix_x >= 10'd160) && (pix_x < 10'd480) &&
        (pix_y < 10'd480);

    wire [4:0] tile_x = pix_x[9:5] - 5'd5;

    // Count scanlines rather than using division by 24.
    reg [4:0] tile_y;
    reg [4:0] pixel_in_row;

    always @(posedge clk) begin
        if (!rst_n) begin
            tile_y       <= 5'd0;
            pixel_in_row <= 5'd0;
        end else if (pix_x == 10'd0) begin
            if (pix_y == 10'd0) begin
                tile_y       <= 5'd0;
                pixel_in_row <= 5'd0;
            end else if (pix_y < 10'd480) begin
                if (pixel_in_row == 5'd23) begin
                    pixel_in_row <= 5'd0;
                    tile_y <= tile_y + 5'd1;
                end else begin
                    pixel_in_row <= pixel_in_row + 5'd1;
                end
            end
        end
    end

    wire signed [5:0] piece_dx =
        $signed({1'b0, tile_x}) -
        $signed({piece_x[4], piece_x});

    wire [4:0] piece_dy = tile_y - piece_y;

    reg [2:0] board_color;
    reg falling_pixel;

    always @* begin
        board_color = 3'd0;
        falling_pixel = 1'b0;

        if (in_board && (tile_y < 5'd20)) begin
            // tile_x stays 5 bits for the signed piece_dx math, but bitplane
            // rows are only 10 bits wide: index them with tile_x[3:0].
            board_color = {
                board_2[tile_y][tile_x[3:0]],
                board_1[tile_y][tile_x[3:0]],
                board_0[tile_y][tile_x[3:0]]
            };

            if ((state != TITLE) && (state != OVER) &&
                (piece_dx >= 6'sd0) &&
                (piece_dx < 6'sd4) &&
                (tile_y >= piece_y) &&
                (piece_dy < 5'd4)) begin
                falling_pixel = piece_cell(
                    piece_kind, piece_rotation,
                    piece_dx[1:0], piece_dy[1:0]
                );
            end
        end
    end

    wire cell_interior =
        (pix_x[4:0] != 5'd0) && (pixel_in_row != 5'd0);

    // Convert a color ID into 2-bit-per-channel RGB.
    function [5:0] color_rgb;
        input [2:0] color_id;
        begin
            case (color_id)
                3'd1: color_rgb = {2'b00, 2'b11, 2'b11}; // I: cyan
                3'd2: color_rgb = {2'b11, 2'b11, 2'b00}; // O: yellow
                3'd3: color_rgb = {2'b10, 2'b00, 2'b11}; // T: purple
                3'd4: color_rgb = {2'b00, 2'b11, 2'b00}; // S: green
                3'd5: color_rgb = {2'b11, 2'b00, 2'b00}; // Z: red
                3'd6: color_rgb = {2'b00, 2'b00, 2'b11}; // J: blue
                3'd7: color_rgb = {2'b11, 2'b10, 2'b00}; // L: orange
                default: color_rgb = {2'b00, 2'b00, 2'b00};
            endcase
        end
    endfunction

    // Five-by-seven font for the title and game-over screens.
    // Glyph rows are stored top to bottom.
    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] glyph_y;
        reg [34:0] glyph;
        begin
            case (character)
                "A": glyph = {
                    5'b01110, 5'b10001, 5'b10001, 5'b11111,
                    5'b10001, 5'b10001, 5'b10001
                };
                "E": glyph = {
                    5'b11111, 5'b10000, 5'b10000, 5'b11110,
                    5'b10000, 5'b10000, 5'b11111
                };
                "G": glyph = {
                    5'b01110, 5'b10001, 5'b10000, 5'b10111,
                    5'b10001, 5'b10001, 5'b01110
                };
                "I": glyph = {
                    5'b11111, 5'b00100, 5'b00100, 5'b00100,
                    5'b00100, 5'b00100, 5'b11111
                };
                "M": glyph = {
                    5'b10001, 5'b11011, 5'b10101, 5'b10101,
                    5'b10001, 5'b10001, 5'b10001
                };
                "O": glyph = {
                    5'b01110, 5'b10001, 5'b10001, 5'b10001,
                    5'b10001, 5'b10001, 5'b01110
                };
                "P": glyph = {
                    5'b11110, 5'b10001, 5'b10001, 5'b11110,
                    5'b10000, 5'b10000, 5'b10000
                };
                "R": glyph = {
                    5'b11110, 5'b10001, 5'b10001, 5'b11110,
                    5'b10100, 5'b10010, 5'b10001
                };
                "S": glyph = {
                    5'b01111, 5'b10000, 5'b10000, 5'b01110,
                    5'b00001, 5'b00001, 5'b11110
                };
                "T": glyph = {
                    5'b11111, 5'b00100, 5'b00100, 5'b00100,
                    5'b00100, 5'b00100, 5'b00100
                };
                "V": glyph = {
                    5'b10001, 5'b10001, 5'b10001, 5'b10001,
                    5'b10001, 5'b01010, 5'b00100
                };
                default: glyph = 35'b0;
            endcase

            case (glyph_y)
                3'd0: glyph_row = glyph[34:30];
                3'd1: glyph_row = glyph[29:25];
                3'd2: glyph_row = glyph[24:20];
                3'd3: glyph_row = glyph[19:15];
                3'd4: glyph_row = glyph[14:10];
                3'd5: glyph_row = glyph[9:5];
                3'd6: glyph_row = glyph[4:0];
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    // Header characters: "TETRIS" or "GAME OVER".
    function [7:0] header_character;
        input game_over;
        input [3:0] index;
        begin
            header_character = " ";

            if (game_over) begin
                case (index)
                    4'd0: header_character = "G";
                    4'd1: header_character = "A";
                    4'd2: header_character = "M";
                    4'd3: header_character = "E";
                    4'd5: header_character = "O";
                    4'd6: header_character = "V";
                    4'd7: header_character = "E";
                    4'd8: header_character = "R";
                    default: header_character = " ";
                endcase
            end else begin
                case (index)
                    4'd0: header_character = "T";
                    4'd1: header_character = "E";
                    4'd2: header_character = "T";
                    4'd3: header_character = "R";
                    4'd4: header_character = "I";
                    4'd5: header_character = "S";
                    default: header_character = " ";
                endcase
            end
        end
    endfunction

    function [7:0] prompt_character;
        input [3:0] index;
        begin
            case (index)
                4'd0:  prompt_character = "P";
                4'd1:  prompt_character = "R";
                4'd2:  prompt_character = "E";
                4'd3:  prompt_character = "S";
                4'd4:  prompt_character = "S";
                4'd6:  prompt_character = "S";
                4'd7:  prompt_character = "T";
                4'd8:  prompt_character = "A";
                4'd9:  prompt_character = "R";
                4'd10: prompt_character = "T";
                default: prompt_character = " ";
            endcase
        end
    endfunction

    // Header: each glyph pixel is 8x8 screen pixels.
    wire [9:0] header_x_origin =
        (state == OVER) ? 10'd32 : 10'd128;

    wire [9:0] header_width =
        (state == OVER) ? 10'd576 : 10'd384;

    wire [9:0] header_dx = pix_x - header_x_origin;
    wire [9:0] header_dy = pix_y - 10'd112;

    wire header_area =
        (pix_x >= header_x_origin) &&
        (header_dx < header_width) &&
        (pix_y >= 10'd112) && (pix_y < 10'd168);

    wire [3:0] header_index = header_dx[9:6];
    wire [2:0] header_col = header_dx[5:3];
    wire [2:0] header_row = header_dy[5:3];
    wire [4:0] header_bits = glyph_row(
        header_character(state == OVER, header_index), header_row
    );

    reg header_pixel;
    always @* begin
        header_pixel = 1'b0;
        if (header_area && (header_col < 3'd5))
            header_pixel = header_bits[3'd4 - header_col];
    end

    // Prompt: each glyph pixel is 4x4 screen pixels.
    // Eleven 32-pixel character slots are centered at x=144.
    wire [9:0] prompt_dx = pix_x - 10'd144;
    wire [9:0] prompt_dy = pix_y - 10'd240;

    wire prompt_area =
        (pix_x >= 10'd144) && (pix_x < 10'd496) &&
        (pix_y >= 10'd240) && (pix_y < 10'd268);

    wire [3:0] prompt_index = prompt_dx[8:5];
    wire [2:0] prompt_col = prompt_dx[4:2];
    wire [2:0] prompt_row = prompt_dy[4:2];
    wire [4:0] prompt_bits = glyph_row(
        prompt_character(prompt_index), prompt_row
    );

    reg prompt_pixel;
    always @* begin
        prompt_pixel = 1'b0;
        if (prompt_area && (prompt_col < 3'd5))
            prompt_pixel = prompt_bits[3'd4 - prompt_col];
    end

    reg [1:0] red;
    reg [1:0] green;
    reg [1:0] blue;

    always @* begin
        red   = 2'b00;
        green = 2'b00;
        blue  = 2'b00;

        if (display_on) begin
            if ((state == TITLE) || (state == OVER)) begin
                if (header_pixel) begin
                    if (state == OVER) begin
                        red = 2'b11;
                    end else begin
                        red   = 2'b11;
                        green = 2'b11;
                        blue  = 2'b11;
                    end
                end else if (prompt_pixel) begin
                    green = 2'b11;
                    blue  = 2'b11;
                end
            end else if (in_board && cell_interior) begin
                if (board_color != 3'd0) begin
                    {red, green, blue} = color_rgb(board_color);
                end else if (falling_pixel) begin
                    {red, green, blue} = color_rgb(piece_color);
                end else begin
                    // Empty board cells: dark blue.
                    blue = 2'b01;
                end
            end
        end
    end

    // TinyVGA PMOD output order.
    assign uo_out = {
        hsync, blue[0], green[0], red[0],
        vsync, blue[1], green[1], red[1]
    };

    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    // ena is intentionally ignored.
    wire _unused = &{ena, ui_in[7], ui_in[3:0], uio_in, 1'b0};

endmodule