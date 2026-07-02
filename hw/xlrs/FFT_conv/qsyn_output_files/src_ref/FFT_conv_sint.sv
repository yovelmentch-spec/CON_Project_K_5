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
    LOAD_C_ADVANCE,

    INIT_LOAD_X,
    LOAD_X_READ,
    LOAD_X_ADVANCE,

    PREPARE_INPUTS,

    START_FFT_CX,
    WAIT_FFT_CX,

    POINTWISE_MUL,

    START_IFFT,
    WAIT_IFFT,

    FIND_MAX,

    NORMALIZE_START_DIV,
    NORMALIZE_WAIT_DIV,

    INIT_WRITE_Y,
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

  logic signed [7:0] c_buf [0:MAX_N-1];
  logic signed [7:0] x_buf [0:MAX_N-1];
  logic signed [7:0] y_buf [0:MAX_N-1];

  logic signed [DATA_WIDTH-1:0] c_in_re [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] c_in_im [0:MAX_N-1];

  logic signed [DATA_WIDTH-1:0] x_in_re [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] x_in_im [0:MAX_N-1];

  logic signed [DATA_WIDTH-1:0] c_fft_re [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] c_fft_im [0:MAX_N-1];

  logic signed [DATA_WIDTH-1:0] x_fft_re [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] x_fft_im [0:MAX_N-1];

  logic signed [DATA_WIDTH-1:0] mul_re [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] mul_im [0:MAX_N-1];

  logic signed [DATA_WIDTH-1:0] ifft_re [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] ifft_im [0:MAX_N-1];

  logic signed [31:0] y_raw_buf [0:MAX_N-1];

  logic fft_c_start;
  logic fft_x_start;
  logic ifft_start;

  logic fft_c_busy;
  logic fft_x_busy;
  logic ifft_busy;

  logic fft_c_done;
  logic fft_x_done;
  logic ifft_done;

  logic fft_c_done_seen;
  logic fft_x_done_seen;

  assign fft_c_start = (state == START_FFT_CX);
  assign fft_x_start = (state == START_FFT_CX);
  assign ifft_start  = (state == START_IFFT);

  fft_engine #(
    .MAX_N(MAX_N),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_fft_c (
    .clk(clk),
    .rst_n(rst_n),
    .start(fft_c_start),
    .inverse(1'b0),
    .n(n),
    .in_re(c_in_re),
    .in_im(c_in_im),
    .out_re(c_fft_re),
    .out_im(c_fft_im),
    .busy(fft_c_busy),
    .done(fft_c_done)
  );

  fft_engine #(
    .MAX_N(MAX_N),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_fft_x (
    .clk(clk),
    .rst_n(rst_n),
    .start(fft_x_start),
    .inverse(1'b0),
    .n(n),
    .in_re(x_in_re),
    .in_im(x_in_im),
    .out_re(x_fft_re),
    .out_im(x_fft_im),
    .busy(fft_x_busy),
    .done(fft_x_done)
  );

  fft_engine #(
    .MAX_N(MAX_N),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_ifft (
    .clk(clk),
    .rst_n(rst_n),
    .start(ifft_start),
    .inverse(1'b1),
    .n(n),
    .in_re(mul_re),
    .in_im(mul_im),
    .out_re(ifft_re),
    .out_im(ifft_im),
    .busy(ifft_busy),
    .done(ifft_done)
  );

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

  logic [31:0] remaining_size;
  logic [5:0]  crnt_size;

  logic [31:0] index;
  logic [31:0] safe_index;

  logic [XMEM_ADDR_WIDTH-1:0] crnt_rd_addr;
  logic [XMEM_ADDR_WIDTH-1:0] crnt_wr_addr;

  logic [BYTES_PER_XMEM_LINE-1:0][7:0] write_data;

  logic [31:0] max_abs;
  logic [31:0] current_abs;
  logic [31:0] norm_abs;
  logic [31:0] norm_num;
  logic        norm_negative;
  logic signed [31:0] norm_signed_result;

  assign safe_index = (index < MAX_N) ? index : 32'd0;

  always_comb begin
    current_abs = abs_s32(y_raw_buf[safe_index]);
    norm_abs    = abs_s32(y_raw_buf[safe_index]);
    norm_num    = norm_abs * 32'd127;

    div_a = norm_num;
    div_b = max_abs;

    norm_negative = (y_raw_buf[safe_index] < 0);
    norm_signed_result = apply_sign_floor(norm_negative, div_val, div_rem);
  end

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

  always_comb begin
    write_data = '0;

    for (int b = 0; b < BYTES_PER_XMEM_LINE; b++) begin
      if ((b < crnt_size) && ((index + b) < MAX_N)) begin
        write_data[b] = y_buf[index + b];
      end
    end
  end

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
          next_state = LOAD_C_ADVANCE;
        end
      end

      LOAD_C_ADVANCE: begin
        if (remaining_size == 0) begin
          next_state = INIT_LOAD_X;
        end
        else begin
          next_state = LOAD_C_READ;
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
          next_state = LOAD_X_ADVANCE;
        end
      end

      LOAD_X_ADVANCE: begin
        if (remaining_size == 0) begin
          next_state = PREPARE_INPUTS;
        end
        else begin
          next_state = LOAD_X_READ;
        end
      end

      PREPARE_INPUTS: begin
        if (index >= n) begin
          next_state = START_FFT_CX;
        end
      end

      START_FFT_CX: begin
        next_state = WAIT_FFT_CX;
      end

      WAIT_FFT_CX: begin
        if ((fft_c_done || fft_c_done_seen) &&
            (fft_x_done || fft_x_done_seen)) begin
          next_state = POINTWISE_MUL;
        end
      end

      POINTWISE_MUL: begin
        if (index >= n) begin
          next_state = START_IFFT;
        end
      end

      START_IFFT: begin
        next_state = WAIT_IFFT;
      end

      WAIT_IFFT: begin
        if (ifft_done) begin
          next_state = FIND_MAX;
        end
      end

      FIND_MAX: begin
        if (index >= n) begin
          next_state = NORMALIZE_START_DIV;
        end
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
            next_state = NORMALIZE_START_DIV;
          end
        end
      end

      INIT_WRITE_Y: begin
        next_state = WRITE_Y;
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

      remaining_size <= 32'd0;
      index          <= 32'd0;
      crnt_rd_addr   <= '0;
      crnt_wr_addr   <= '0;
      max_abs        <= 32'd1;

      fft_c_done_seen <= 1'b0;
      fft_x_done_seen <= 1'b0;

      for (int i = 0; i < MAX_N; i++) begin
        c_buf[i]     <= '0;
        x_buf[i]     <= '0;
        y_buf[i]     <= '0;

        c_in_re[i]   <= '0;
        c_in_im[i]   <= '0;
        x_in_re[i]   <= '0;
        x_in_im[i]   <= '0;

        mul_re[i]    <= '0;
        mul_im[i]    <= '0;

        y_raw_buf[i] <= '0;
      end
    end
    else begin

      case (state)

        INIT_LOAD_C: begin
          crnt_rd_addr      <= c_addr;
          remaining_size    <= n;
          index             <= 32'd0;
          max_abs           <= 32'd1;
          fft_c_done_seen   <= 1'b0;
          fft_x_done_seen   <= 1'b0;
        end

        LOAD_C_READ: begin
          if (mem_intf_read.mem_valid) begin
            for (int b = 0; b < BYTES_PER_XMEM_LINE; b++) begin
              if ((b < crnt_size) && ((index + b) < MAX_N)) begin
                c_buf[index + b] <= mem_intf_read.mem_data[b];
              end
            end

            crnt_rd_addr   <= crnt_rd_addr + crnt_size;
            remaining_size <= remaining_size - crnt_size;
            index          <= index + crnt_size;
          end
        end

        LOAD_C_ADVANCE: begin
          if (remaining_size == 0) begin
            index <= 32'd0;
          end
        end

        INIT_LOAD_X: begin
          crnt_rd_addr   <= x_addr;
          remaining_size <= n;
          index          <= 32'd0;
        end

        LOAD_X_READ: begin
          if (mem_intf_read.mem_valid) begin
            for (int b = 0; b < BYTES_PER_XMEM_LINE; b++) begin
              if ((b < crnt_size) && ((index + b) < MAX_N)) begin
                x_buf[index + b] <= mem_intf_read.mem_data[b];
              end
            end

            crnt_rd_addr   <= crnt_rd_addr + crnt_size;
            remaining_size <= remaining_size - crnt_size;
            index          <= index + crnt_size;
          end
        end

        LOAD_X_ADVANCE: begin
          if (remaining_size == 0) begin
            index <= 32'd0;
          end
        end

        PREPARE_INPUTS: begin
          if (index < n) begin
            c_in_re[index] <= $signed(c_buf[index]) <<< 12;
            c_in_im[index] <= 32'sd0;

            x_in_re[index] <= $signed(x_buf[index]) <<< 12;
            x_in_im[index] <= 32'sd0;

            index <= index + 32'd1;
          end
          else begin
            index <= 32'd0;
          end
        end

        START_FFT_CX: begin
          fft_c_done_seen <= 1'b0;
          fft_x_done_seen <= 1'b0;
          index           <= 32'd0;
        end

        WAIT_FFT_CX: begin
          if (fft_c_done) begin
            fft_c_done_seen <= 1'b1;
          end

          if (fft_x_done) begin
            fft_x_done_seen <= 1'b1;
          end

          if ((fft_c_done || fft_c_done_seen) &&
              (fft_x_done || fft_x_done_seen)) begin
            index <= 32'd0;
          end
        end

        POINTWISE_MUL: begin
          if (index < n) begin
            mul_re[index] <= q15_mul(c_fft_re[index], x_fft_re[index]) -
                             q15_mul(c_fft_im[index], x_fft_im[index]);

            mul_im[index] <= q15_mul(c_fft_re[index], x_fft_im[index]) +
                             q15_mul(c_fft_im[index], x_fft_re[index]);

            index <= index + 32'd1;
          end
          else begin
            index <= 32'd0;
          end
        end

        START_IFFT: begin
          index <= 32'd0;
        end

        WAIT_IFFT: begin
          if (ifft_done) begin
            for (int i = 0; i < MAX_N; i++) begin
              y_raw_buf[i] <= ifft_re[i];
            end

            max_abs <= 32'd1;
            index   <= 32'd0;
          end
        end

        FIND_MAX: begin
          if (index < n) begin
            if (current_abs > max_abs) begin
              max_abs <= current_abs;
            end

            index <= index + 32'd1;
          end
          else begin
            index <= 32'd0;
          end
        end

        NORMALIZE_START_DIV: begin
          // div_start is asserted combinationally in this state.
        end

        NORMALIZE_WAIT_DIV: begin
          if (div_done) begin
            y_buf[index] <= norm_signed_result[7:0];
            index        <= index + 32'd1;
          end
        end

        INIT_WRITE_Y: begin
          crnt_wr_addr   <= y_addr;
          remaining_size <= n;
          index          <= 32'd0;
        end

        WRITE_Y: begin
          if (mem_intf_write.mem_ack) begin
            crnt_wr_addr   <= crnt_wr_addr + crnt_size;
            remaining_size <= remaining_size - crnt_size;

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

endmodule