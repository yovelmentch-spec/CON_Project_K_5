// ============================================================================
// FFT_conv.sv — BRAM version, rev 2 (byte-array elimination)
//
// Changes vs. BRAM rev 1 (which reached 104K ALUTs / 7.1K regs / 57Kb mem):
//  Synthesis showed 96K of the remaining ALUTs were the top module's own
//  logic: the write decoders and barrel shifters of the c_buf/x_buf/y_buf
//  byte arrays (line-wide access with a variable offset, 32 lanes x 256
//  targets). This revision removes them:
//
//  1. c_buf/x_buf are DELETED. Input data is streamed: each memory line is
//     captured into a single line register (line_buf), then fed byte-by-byte
//     straight into the engine load port (LOAD_C_FEED / LOAD_X_FEED).
//     Consequence: X is now read from memory AFTER FFT(C) completes; the
//     total number of memory transactions is unchanged.
//  2. y_buf is now block RAM (y_mem): written one byte per division in
//     NORMALIZE_WAIT_DIV, and read back one byte per cycle in the new
//     WRITE_Y_FILL state, which assembles line_buf before each memory write.
//     write_data uses only static lane indexing (no barrel shifter).
//  3. line_buf is the only remaining byte storage: BYTES_PER_XMEM_LINE
//     registers, shared by the load and store paths.
//
// FSM sequence:
//   IDLE -> INIT_LOAD_C -> (LOAD_C_READ <-> LOAD_C_FEED)*
//        -> START/WAIT_FFT_C -> SAVE_FFT_C                  (c_fft = FFT(C))
//        -> INIT_LOAD_X -> (LOAD_X_READ <-> LOAD_X_FEED)*
//        -> START/WAIT_FFT_X                                (FFT(X) in engine)
//        -> POINTWISE_MUL -> LOAD_ENGINE_MUL
//        -> START/WAIT_IFFT -> SAVE_IFFT -> FIND_MAX
//        -> (NORMALIZE_READ/START/WAIT)*                    (y_mem[i] written)
//        -> INIT_WRITE_Y -> (WRITE_Y_FILL <-> WRITE_Y)* -> DONE
// ============================================================================

import xbox_def_pkg::*;

module FFT_conv (
  input        clk,
  input        rst_n,

  input        [XBOX_NUM_REGS-1:0][31:0] host_regs,
  input  logic [XBOX_NUM_REGS-1:0]       host_regs_valid_pulse,
  output logic [XBOX_NUM_REGS-1:0][31:0] host_regs_data_out,
  output logic [XBOX_NUM_REGS-1:0]       host_regs_valid_out,
  input  logic [XBOX_NUM_REGS-1:0]       host_regs_read_pulse,

  mem_intf_read.client_read   mem_intf_read,
  mem_intf_write.client_write mem_intf_write
);

  localparam int MAX_N      = 256;
  localparam int DATA_WIDTH = 32;
  localparam int AW         = $clog2(MAX_N);

  enum {
     C_ADDR_REG_IDX     = 0,
     X_ADDR_REG_IDX     = 1,
     Y_ADDR_REG_IDX     = 2,
     N_REG_IDX          = 3,
     MODE_REG_IDX       = 4,
     START_REG_IDX      = 5,
     DONE_REG_IDX       = 6
  } regs_idx;

  typedef enum logic [4:0] {
    IDLE,

    INIT_LOAD_C,
    LOAD_C_READ,
    LOAD_C_FEED,

    START_FFT_C,
    WAIT_FFT_C,
    SAVE_FFT_C,

    INIT_LOAD_X,
    LOAD_X_READ,
    LOAD_X_FEED,

    START_FFT_X,
    WAIT_FFT_X,

    POINTWISE_MUL,

    LOAD_ENGINE_MUL,
    START_IFFT,
    WAIT_IFFT,
    SAVE_IFFT,

    FIND_MAX,

    NORMALIZE_READ,
    NORMALIZE_START_DIV,
    NORMALIZE_WAIT_DIV,

    INIT_WRITE_Y,
    WRITE_Y_FILL,
    WRITE_Y,

    DONE
  } state_t;

  state_t state;
  state_t next_state;

  logic [XMEM_ADDR_WIDTH-1:0] c_addr;
  logic [XMEM_ADDR_WIDTH-1:0] x_addr;
  logic [XMEM_ADDR_WIDTH-1:0] y_addr;

  logic [31:0] n;
  logic [31:0] mode;

  logic start_accel;
  logic accel_done;
  logic clear_done_on_read;

  assign c_addr = host_regs[C_ADDR_REG_IDX][XMEM_ADDR_WIDTH-1:0];
  assign x_addr = host_regs[X_ADDR_REG_IDX][XMEM_ADDR_WIDTH-1:0];
  assign y_addr = host_regs[Y_ADDR_REG_IDX][XMEM_ADDR_WIDTH-1:0];

  assign n    = host_regs[N_REG_IDX];
  assign mode = host_regs[MODE_REG_IDX];

  assign start_accel = host_regs[START_REG_IDX][0] &&
                       host_regs_valid_pulse[START_REG_IDX];

  assign clear_done_on_read = host_regs_read_pulse[DONE_REG_IDX];

  // --------------------------------------------------------------------
  // The only remaining byte storage: one memory line, statically indexed
  // on the memory-interface side, single-byte dynamic access on the
  // engine/RAM side.
  // --------------------------------------------------------------------
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] line_buf;
  logic [5:0]                          line_size;   // bytes captured in line_buf
  logic [5:0]                          byte_idx;

  // --------------------------------------------------------------------
  // Loop index and helpers
  // --------------------------------------------------------------------
  logic [31:0] remaining_size;
  logic [5:0]  crnt_size;

  logic [31:0] index;
  logic [31:0] idx_m1;
  logic [31:0] idx_m2;    // for the 2-cycle-latency pointwise multiply pipeline
  logic        in_body;   // pipelined-loop body: a write lands this cycle

  logic [XMEM_ADDR_WIDTH-1:0] crnt_rd_addr;
  logic [XMEM_ADDR_WIDTH-1:0] crnt_wr_addr;

  logic [BYTES_PER_XMEM_LINE-1:0][7:0] write_data;

  logic [31:0] max_abs;
  logic [31:0] current_abs;
  logic [31:0] norm_num;
  logic        norm_negative;
  logic signed [31:0] norm_signed_result;

  assign idx_m1  = index - 32'd1;
  assign idx_m2  = index - 32'd2;
  assign in_body = (index >= 32'd1) && (index <= n);

  // --------------------------------------------------------------------
  // Shared FFT engine signals (declared before the RAM blocks that use them)
  // --------------------------------------------------------------------
  logic fft_start;
  logic fft_inverse;
  logic fft_busy;
  logic fft_done;

  logic                         eng_load_valid;
  logic [31:0]                  eng_load_addr;
  logic signed [DATA_WIDTH-1:0] eng_load_re;
  logic signed [DATA_WIDTH-1:0] eng_load_im;

  logic [31:0]                  eng_read_addr;
  logic signed [DATA_WIDTH-1:0] eng_read_re;
  logic signed [DATA_WIDTH-1:0] eng_read_im;

  // --------------------------------------------------------------------
  // Block RAM: c_fft (FFT(C) spectrum). Written in SAVE_FFT_C,
  // read in POINTWISE_MUL. No reset, registered read -> M9K inference.
  // --------------------------------------------------------------------
  (* ramstyle = "M9K" *) logic signed [DATA_WIDTH-1:0] cfft_re_mem [0:MAX_N-1];
  (* ramstyle = "M9K" *) logic signed [DATA_WIDTH-1:0] cfft_im_mem [0:MAX_N-1];

  logic                         cfft_we;
  logic [AW-1:0]                cfft_waddr;
  logic [AW-1:0]                cfft_raddr;
  logic signed [DATA_WIDTH-1:0] cfft_rre;
  logic signed [DATA_WIDTH-1:0] cfft_rim;

  always_ff @(posedge clk) begin
    if (cfft_we) begin
      cfft_re_mem[cfft_waddr] <= eng_read_re;
      cfft_im_mem[cfft_waddr] <= eng_read_im;
    end
    cfft_rre <= cfft_re_mem[cfft_raddr];
    cfft_rim <= cfft_im_mem[cfft_raddr];
  end

  assign cfft_we    = (state == SAVE_FFT_C) && in_body;
  assign cfft_waddr = idx_m1[AW-1:0];
  assign cfft_raddr = index[AW-1:0];

  // --------------------------------------------------------------------
  // Block RAM: mul (pointwise product). Written in POINTWISE_MUL,
  // read in LOAD_ENGINE_MUL.
  // --------------------------------------------------------------------
  (* ramstyle = "M9K" *) logic signed [DATA_WIDTH-1:0] mul_re_mem [0:MAX_N-1];
  (* ramstyle = "M9K" *) logic signed [DATA_WIDTH-1:0] mul_im_mem [0:MAX_N-1];

  logic                         mul_we;
  logic [AW-1:0]                mul_waddr;
  logic [AW-1:0]                mul_raddr;
  logic signed [DATA_WIDTH-1:0] mul_wre;
  logic signed [DATA_WIDTH-1:0] mul_wim;
  logic signed [DATA_WIDTH-1:0] mul_rre;
  logic signed [DATA_WIDTH-1:0] mul_rim;

  // pointwise-multiply pipeline: raw 32x32 products registered one cycle,
  // rounded/combined and written the next. Write therefore lags the RAM
  // read by 2 cycles (idx_m2).
  logic signed [2*DATA_WIDTH-1:0] pp_rr;   // cfft_re * xfft_re
  logic signed [2*DATA_WIDTH-1:0] pp_ii;   // cfft_im * xfft_im
  logic signed [2*DATA_WIDTH-1:0] pp_ri;   // cfft_re * xfft_im
  logic signed [2*DATA_WIDTH-1:0] pp_ir;   // cfft_im * xfft_re

  always_ff @(posedge clk) begin
    if (mul_we) begin
      mul_re_mem[mul_waddr] <= mul_wre;
      mul_im_mem[mul_waddr] <= mul_wim;
    end
    mul_rre <= mul_re_mem[mul_raddr];
    mul_rim <= mul_im_mem[mul_raddr];
  end

  // stage 2 valid: pp_* hold element (index-2), written to address index-2
  assign mul_we    = (state == POINTWISE_MUL) && (index >= 32'd2) && (index <= n + 32'd1);
  assign mul_waddr = idx_m2[AW-1:0];
  assign mul_raddr = index[AW-1:0];
  assign mul_wre   = q15_round_top(pp_rr) - q15_round_top(pp_ii);
  assign mul_wim   = q15_round_top(pp_ri) + q15_round_top(pp_ir);

  // --------------------------------------------------------------------
  // Block RAM: y_raw (IFFT real output). Written in SAVE_IFFT,
  // read in FIND_MAX and NORMALIZE_READ.
  // --------------------------------------------------------------------
  (* ramstyle = "M9K" *) logic signed [31:0] yraw_mem [0:MAX_N-1];

  logic               yraw_we;
  logic [AW-1:0]      yraw_waddr;
  logic [AW-1:0]      yraw_raddr;
  logic signed [31:0] yraw_r;

  always_ff @(posedge clk) begin
    if (yraw_we) begin
      yraw_mem[yraw_waddr] <= eng_read_re;
    end
    yraw_r <= yraw_mem[yraw_raddr];
  end

  assign yraw_we    = (state == SAVE_IFFT) && in_body;
  assign yraw_waddr = idx_m1[AW-1:0];
  // FIND_MAX streams index 0..n; during NORMALIZE_* index is frozen, so the
  // RAM output register holds y_raw[index] stable for the whole division.
  assign yraw_raddr = index[AW-1:0];

  // --------------------------------------------------------------------
  // Block RAM: y (normalized 8-bit output). Written one byte per division
  // in NORMALIZE_WAIT_DIV, read back one byte per cycle in WRITE_Y_FILL.
  // --------------------------------------------------------------------
  (* ramstyle = "M9K" *) logic [7:0] y_mem [0:MAX_N-1];

  logic          y_we;
  logic [AW-1:0] y_waddr;
  logic [AW-1:0] y_raddr;
  logic [7:0]    y_rq;
  logic [31:0]   y_fill_addr;

  always_ff @(posedge clk) begin
    if (y_we) begin
      y_mem[y_waddr] <= norm_signed_result[7:0];
    end
    y_rq <= y_mem[y_raddr];
  end

  // (y_we is assigned after the divider instantiation — it depends on div_done)
  assign y_waddr     = index[AW-1:0];
  assign y_fill_addr = index + {26'd0, byte_idx};
  assign y_raddr     = y_fill_addr[AW-1:0];

  // --------------------------------------------------------------------
  // Single shared FFT engine (BRAM-based, read latency 1 cycle)
  // --------------------------------------------------------------------
  assign fft_start   = (state == START_FFT_C) ||
                       (state == START_FFT_X) ||
                       (state == START_IFFT);

  assign fft_inverse = (state == START_IFFT);

  // reads are consumed one cycle after the address is applied
  assign eng_read_addr = index;

  fft_engine #(
    .MAX_N(MAX_N),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_fft (
    .clk(clk),
    .rst_n(rst_n),
    .start(fft_start),
    .inverse(fft_inverse),
    .n(n),
    .load_valid(eng_load_valid),
    .load_addr(eng_load_addr),
    .load_re(eng_load_re),
    .load_im(eng_load_im),
    .read_addr(eng_read_addr),
    .read_re(eng_read_re),
    .read_im(eng_read_im),
    .busy(fft_busy),
    .done(fft_done)
  );

  // --------------------------------------------------------------------
  // Engine load port driver.
  // LOAD_C_FEED / LOAD_X_FEED: one byte per cycle from line_buf, converted
  // to Q15 on the fly (single 32:1 byte mux — no barrel shifter).
  // LOAD_ENGINE_MUL: pipelined feed from the mul RAM (1-cycle latency).
  // --------------------------------------------------------------------
  always_comb begin
    eng_load_valid = 1'b0;
    eng_load_addr  = index;
    eng_load_re    = '0;
    eng_load_im    = '0;

    case (state)
      LOAD_C_FEED,
      LOAD_X_FEED: begin
        if ((byte_idx < line_size) && (index < n)) begin
          eng_load_valid = 1'b1;
          eng_load_re    = $signed(line_buf[byte_idx]) <<< 12;
          eng_load_im    = '0;
        end
      end

      LOAD_ENGINE_MUL: begin
        if (in_body) begin
          eng_load_valid = 1'b1;
          eng_load_addr  = idx_m1;
          eng_load_re    = mul_rre;
          eng_load_im    = mul_rim;
        end
      end

      default: ;
    endcase
  end

  // --------------------------------------------------------------------
  // Divider
  // --------------------------------------------------------------------
  logic        div_start;
  logic        div_busy;
  logic        div_done;
  logic        div_valid;
  logic        div_dbz;
  logic [31:0] div_a;
  logic [31:0] div_b;
  logic [31:0] div_val;
  logic [31:0] div_rem;

  assign div_start = (state == NORMALIZE_START_DIV);

  divu_int #(
    .WIDTH(32)
  ) u_div (
    .clk(clk),
    .rst_n(rst_n),
    .start(div_start),
    .busy(div_busy),
    .done(div_done),
    .valid(div_valid),
    .dbz(div_dbz),
    .a(div_a),
    .b(div_b),
    .val(div_val),
    .rem(div_rem)
  );

  assign y_we = (state == NORMALIZE_WAIT_DIV) && div_done;

  // Normalization operands come from the y_raw RAM output register (yraw_r),
  // which is stable during NORMALIZE_START_DIV / NORMALIZE_WAIT_DIV.
  always_comb begin
    current_abs = abs_s32(yraw_r);
    norm_num    = abs_s32(yraw_r) * 32'd127;

    div_a = norm_num;
    div_b = max_abs;

    norm_negative = (yraw_r < 0);
    norm_signed_result = apply_sign_floor(norm_negative, div_val, div_rem);
  end

  // --------------------------------------------------------------------
  // Host DONE register handling (unchanged)
  // --------------------------------------------------------------------
  logic [XBOX_NUM_REGS-1:0][31:0] host_regs_data_out_ps;

  always_comb begin
    host_regs_data_out_ps = host_regs_data_out;

    if (accel_done) begin
      host_regs_data_out_ps[DONE_REG_IDX][0] = 1'b1;
    end
    else if (clear_done_on_read) begin
      host_regs_data_out_ps[DONE_REG_IDX][0] = 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      host_regs_data_out <= '0;
    end
    else begin
      host_regs_data_out <= host_regs_data_out_ps;
    end
  end

  always_comb begin
    host_regs_valid_out = '0;
    host_regs_valid_out[DONE_REG_IDX] = host_regs_data_out[DONE_REG_IDX][0];
  end

  assign crnt_size = (remaining_size >= BYTES_PER_XMEM_LINE) ?
                     BYTES_PER_XMEM_LINE[$clog2(BYTES_PER_XMEM_LINE):0] :
                     remaining_size[$clog2(BYTES_PER_XMEM_LINE):0];

  // Static lane indexing only — line_buf was filled by WRITE_Y_FILL
  always_comb begin
    write_data = '0;

    for (int b = 0; b < BYTES_PER_XMEM_LINE; b++) begin
      if (b < crnt_size) begin
        write_data[b] = line_buf[b];
      end
    end
  end

  // --------------------------------------------------------------------
  // Next-state logic
  // --------------------------------------------------------------------
  always_comb begin
    next_state = state;

    mem_intf_read.mem_req        = 1'b0;
    mem_intf_read.mem_start_addr = crnt_rd_addr;
    mem_intf_read.mem_size_bytes = crnt_size;

    mem_intf_write.mem_req        = 1'b0;
    mem_intf_write.mem_start_addr = crnt_wr_addr;
    mem_intf_write.mem_size_bytes = crnt_size;
    mem_intf_write.mem_data       = write_data;

    accel_done = 1'b0;

    case (state)

      IDLE: begin
        if (start_accel) begin
          next_state = INIT_LOAD_C;
        end
      end

      INIT_LOAD_C: begin
        next_state = LOAD_C_READ;
      end

      LOAD_C_READ: begin
        mem_intf_read.mem_req        = 1'b1;
        mem_intf_read.mem_start_addr = crnt_rd_addr;
        mem_intf_read.mem_size_bytes = crnt_size;

        if (mem_intf_read.mem_valid) begin
          mem_intf_read.mem_req = 1'b0;
          next_state = LOAD_C_FEED;
        end
      end

      // feed the captured line into the engine, one byte per cycle
      LOAD_C_FEED: begin
        if (byte_idx >= line_size) begin
          if (remaining_size == 0) begin
            next_state = START_FFT_C;
          end
          else begin
            next_state = LOAD_C_READ;
          end
        end
      end

      START_FFT_C: begin
        next_state = WAIT_FFT_C;
      end

      WAIT_FFT_C: begin
        if (fft_done) begin
          next_state = SAVE_FFT_C;
        end
      end

      // pipelined: runs index 0..n, write of element n-1 lands at index==n
      SAVE_FFT_C: begin
        if (index >= n) begin
          next_state = INIT_LOAD_X;
        end
      end

      INIT_LOAD_X: begin
        next_state = LOAD_X_READ;
      end

      LOAD_X_READ: begin
        mem_intf_read.mem_req        = 1'b1;
        mem_intf_read.mem_start_addr = crnt_rd_addr;
        mem_intf_read.mem_size_bytes = crnt_size;

        if (mem_intf_read.mem_valid) begin
          mem_intf_read.mem_req = 1'b0;
          next_state = LOAD_X_FEED;
        end
      end

      LOAD_X_FEED: begin
        if (byte_idx >= line_size) begin
          if (remaining_size == 0) begin
            next_state = START_FFT_X;
          end
          else begin
            next_state = LOAD_X_READ;
          end
        end
      end

      START_FFT_X: begin
        next_state = WAIT_FFT_X;
      end

      WAIT_FFT_X: begin
        if (fft_done) begin
          next_state = POINTWISE_MUL;
        end
      end

      // pipelined (2-cycle mult): products of element i-2 written at index==i.
      // Loop runs to n+1 so the last element (n-1) is written; exit at n+2.
      POINTWISE_MUL: begin
        if (index >= n + 32'd2) begin
          next_state = LOAD_ENGINE_MUL;
        end
      end

      // pipelined: engine element i-1 loaded from mul RAM at index==i
      LOAD_ENGINE_MUL: begin
        if (index >= n) begin
          next_state = START_IFFT;
        end
      end

      START_IFFT: begin
        next_state = WAIT_IFFT;
      end

      WAIT_IFFT: begin
        if (fft_done) begin
          next_state = SAVE_IFFT;
        end
      end

      // pipelined: y_raw[i-1] <= engine.read (real part)
      SAVE_IFFT: begin
        if (index >= n) begin
          next_state = FIND_MAX;
        end
      end

      // pipelined: compares element i-1 while issuing read of element i
      FIND_MAX: begin
        if (index >= n) begin
          next_state = NORMALIZE_READ;
        end
      end

      // issue y_raw RAM read; data valid next cycle and held by the RAM
      // output register through the division
      NORMALIZE_READ: begin
        next_state = NORMALIZE_START_DIV;
      end

      NORMALIZE_START_DIV: begin
        next_state = NORMALIZE_WAIT_DIV;
      end

      NORMALIZE_WAIT_DIV: begin
        if (div_done) begin
          if (index + 1 >= n) begin
            next_state = INIT_WRITE_Y;
          end
          else begin
            next_state = NORMALIZE_READ;
          end
        end
      end

      INIT_WRITE_Y: begin
        next_state = WRITE_Y_FILL;
      end

      // pipelined y_mem read: byte_idx runs 0..crnt_size, line_buf[k-1]
      // captures y_mem[index+k-1] at byte_idx==k
      WRITE_Y_FILL: begin
        if (byte_idx >= crnt_size) begin
          next_state = WRITE_Y;
        end
      end

      WRITE_Y: begin
        mem_intf_write.mem_req        = 1'b1;
        mem_intf_write.mem_start_addr = crnt_wr_addr;
        mem_intf_write.mem_size_bytes = crnt_size;
        mem_intf_write.mem_data       = write_data;

        if (mem_intf_write.mem_ack) begin
          mem_intf_write.mem_req = 1'b0;

          if (remaining_size <= crnt_size) begin
            next_state = DONE;
          end
          else begin
            next_state = WRITE_Y_FILL;
          end
        end
      end

      DONE: begin
        accel_done = 1'b1;

        if (clear_done_on_read) begin
          next_state = IDLE;
        end
      end

      default: begin
        next_state = IDLE;
      end

    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
    end
    else begin
      state <= next_state;
    end
  end

  // --------------------------------------------------------------------
  // Datapath registers. NOTE: no reset loops over any RAM array —
  // their contents are fully overwritten before every use.
  // --------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

      remaining_size <= 32'd0;
      index          <= 32'd0;
      byte_idx       <= 6'd0;
      line_size      <= 6'd0;
      line_buf       <= '0;
      crnt_rd_addr   <= '0;
      crnt_wr_addr   <= '0;
      max_abs        <= 32'd1;

      pp_rr <= '0;
      pp_ii <= '0;
      pp_ri <= '0;
      pp_ir <= '0;
    end
    else begin

      case (state)

        INIT_LOAD_C: begin
          crnt_rd_addr   <= c_addr;
          remaining_size <= n;
          index          <= 32'd0;
          byte_idx       <= 6'd0;
          max_abs        <= 32'd1;
        end

        LOAD_C_READ: begin
          if (mem_intf_read.mem_valid) begin
            line_buf       <= mem_intf_read.mem_data;
            line_size      <= crnt_size;
            byte_idx       <= 6'd0;

            crnt_rd_addr   <= crnt_rd_addr + crnt_size;
            remaining_size <= remaining_size - crnt_size;
          end
        end

        // engine load driven combinationally; advance both counters
        LOAD_C_FEED: begin
          if (byte_idx < line_size) begin
            byte_idx <= byte_idx + 6'd1;
            index    <= index + 32'd1;
          end
        end

        START_FFT_C: begin
          index <= 32'd0;
        end

        WAIT_FFT_C: begin
          if (fft_done) begin
            index <= 32'd0;
          end
        end

        // c_fft RAM write happens via cfft_we (combinational above)
        SAVE_FFT_C: begin
          if (index >= n) begin
            index <= 32'd0;
          end
          else begin
            index <= index + 32'd1;
          end
        end

        INIT_LOAD_X: begin
          crnt_rd_addr   <= x_addr;
          remaining_size <= n;
          index          <= 32'd0;
          byte_idx       <= 6'd0;
        end

        LOAD_X_READ: begin
          if (mem_intf_read.mem_valid) begin
            line_buf       <= mem_intf_read.mem_data;
            line_size      <= crnt_size;
            byte_idx       <= 6'd0;

            crnt_rd_addr   <= crnt_rd_addr + crnt_size;
            remaining_size <= remaining_size - crnt_size;
          end
        end

        LOAD_X_FEED: begin
          if (byte_idx < line_size) begin
            byte_idx <= byte_idx + 6'd1;
            index    <= index + 32'd1;
          end
        end

        START_FFT_X: begin
          index <= 32'd0;
        end

        WAIT_FFT_X: begin
          if (fft_done) begin
            index <= 32'd0;
          end
        end

        // stage 1: register the raw products for element index-1 (the RAM
        // outputs cfft_r* / eng_read_* are valid when index is in 1..n).
        // stage 2 (round/combine/write) happens combinationally via mul_we.
        POINTWISE_MUL: begin
          pp_rr <= $signed(cfft_rre) * $signed(eng_read_re);
          pp_ii <= $signed(cfft_rim) * $signed(eng_read_im);
          pp_ri <= $signed(cfft_rre) * $signed(eng_read_im);
          pp_ir <= $signed(cfft_rim) * $signed(eng_read_re);

          if (index >= n + 32'd2) begin
            index <= 32'd0;
          end
          else begin
            index <= index + 32'd1;
          end
        end

        LOAD_ENGINE_MUL: begin
          if (index >= n) begin
            index <= 32'd0;
          end
          else begin
            index <= index + 32'd1;
          end
        end

        START_IFFT: begin
          index <= 32'd0;
        end

        WAIT_IFFT: begin
          if (fft_done) begin
            max_abs <= 32'd1;
            index   <= 32'd0;
          end
        end

        // y_raw RAM write happens via yraw_we (combinational above)
        SAVE_IFFT: begin
          if (index >= n) begin
            index <= 32'd0;
          end
          else begin
            index <= index + 32'd1;
          end
        end

        // pipelined max scan: yraw_r holds element index-1
        FIND_MAX: begin
          if (in_body) begin
            if (current_abs > max_abs) begin
              max_abs <= current_abs;
            end
          end

          if (index >= n) begin
            index <= 32'd0;
          end
          else begin
            index <= index + 32'd1;
          end
        end

        NORMALIZE_READ: begin
          // y_raw RAM read issued (yraw_raddr = index); data next cycle
        end

        NORMALIZE_START_DIV: begin
          // div_start asserted combinationally; operands from yraw_r
        end

        // y_mem write happens via y_we (combinational above)
        NORMALIZE_WAIT_DIV: begin
          if (div_done) begin
            index <= index + 32'd1;
          end
        end

        INIT_WRITE_Y: begin
          crnt_wr_addr   <= y_addr;
          remaining_size <= n;
          index          <= 32'd0;
          byte_idx       <= 6'd0;
        end

        // pipelined y_mem read into line_buf:
        // at byte_idx==k (k>=1), y_rq holds y_mem[index+k-1]
        WRITE_Y_FILL: begin
          if ((byte_idx >= 6'd1) && (byte_idx <= crnt_size)) begin
            line_buf[byte_idx - 6'd1] <= y_rq;
          end

          if (byte_idx >= crnt_size) begin
            byte_idx <= 6'd0;
          end
          else begin
            byte_idx <= byte_idx + 6'd1;
          end
        end

        WRITE_Y: begin
          if (mem_intf_write.mem_ack) begin
            crnt_wr_addr   <= crnt_wr_addr + crnt_size;
            remaining_size <= remaining_size - crnt_size;
            byte_idx       <= 6'd0;

            if (remaining_size <= crnt_size) begin
              index <= 32'd0;
            end
            else begin
              index <= index + crnt_size;
            end
          end
        end

        DONE: begin
          index          <= 32'd0;
          remaining_size <= 32'd0;
          byte_idx       <= 6'd0;
        end

        default: begin
        end

      endcase
    end
  end

  function automatic logic [31:0] abs_s32(
    input logic signed [31:0] val
  );
    begin
      if (val < 0) begin
        abs_s32 = $unsigned(-val);
      end
      else begin
        abs_s32 = $unsigned(val);
      end
    end
  endfunction

  function automatic logic signed [31:0] apply_sign_floor(
    input logic        negative,
    input logic [31:0] quotient,
    input logic [31:0] remainder
  );
    begin
      if (negative) begin
        if (remainder != 0) begin
          apply_sign_floor = -$signed({1'b0, quotient[30:0]}) - 32'sd1;
        end
        else begin
          apply_sign_floor = -$signed({1'b0, quotient[30:0]});
        end
      end
      else begin
        apply_sign_floor = $signed({1'b0, quotient[30:0]});
      end
    end
  endfunction

  function automatic logic signed [31:0] q15_mul(
    input logic signed [31:0] a,
    input logic signed [31:0] b
  );
    logic signed [63:0] t;
    begin
      t = $signed(a) * $signed(b);
      t = t + 64'sd16384;
      q15_mul = t >>> 15;
    end
  endfunction

  // Q15 rounding of an already-computed raw product (multiply done and
  // registered in pp_*). Bit-exact to q15_mul(a,b) for t = a*b.
  function automatic logic signed [31:0] q15_round_top(
    input logic signed [63:0] t
  );
    logic signed [63:0] tr;
    begin
      tr = t + 64'sd16384;
      q15_round_top = tr >>> 15;
    end
  endfunction

endmodule
