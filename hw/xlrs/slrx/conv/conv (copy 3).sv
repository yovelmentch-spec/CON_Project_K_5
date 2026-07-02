//=============================================================================
// File: conv.sv
// Description:
//   Optimized 5x5 convolution accelerator for SLRX.
//
//   Main optimization:
//   - CONV_SETUP loads the 5x5 kernel once.
//   - CONV_WINDOW now computes the full output feature-map, not only one pixel.
//   - CPU starts the accelerator once per convolution layer.
//   - Hardware owns the row/column loops.
//   - For each output row, hardware reads 5 input rows once, then reuses them
//     for all output columns.
//
//   This avoids per-pixel CPU polling and avoids re-reading the same 5 rows
//   for every output column.
//=============================================================================

import xbox_def_pkg::*;
import slrx_def_pkg::*;

module conv (
  input   clk,
  input   rst_n,

  slrx_regs_intrf.xlr slrx_regs_intrf,

  mem_intf_read.client_read   mem_intf_read,
  mem_intf_write.client_write mem_intf_write
);

  //===========================================================================
  // Local Parameters
  //===========================================================================
  localparam DIM_MAX_SIZE       = 32;
  localparam KERNEL_DIM         = 5;
  localparam KERNEL_SIZE        = KERNEL_DIM * KERNEL_DIM;
  localparam MAX_DOT_PROD_WIDTH = 16 + $clog2(KERNEL_SIZE);
  localparam ARR_IDX_W          = $clog2(DIM_MAX_SIZE);

  //===========================================================================
  // FSM
  //===========================================================================
  typedef enum logic [3:0] {
    IDLE,
    READ_KERNEL,
    READ_ROWS,
    WINDOW,
    CALC,
    WRITE,
    DONE
  } state_t;

  state_t state, next_state;

  //===========================================================================
  // Host command / control
  //===========================================================================
  slrx_cmd_t slrx_cmd;

  logic conv_start;
  logic conv_done;
  logic clear_done_on_read;
  logic conv_active;

  assign slrx_regs_intrf.xlr_done = conv_done;

  assign slrx_cmd =
      slrx_cmd_t'(slrx_regs_intrf.host_regs[XLR_START_RI][$clog2(NUM_SLRX_CMDS)-1:0]);

  assign conv_active =
      (slrx_cmd == CONV_SETUP) || (slrx_cmd == CONV_WINDOW);

  assign conv_start =
      slrx_regs_intrf.host_regs_valid_pulse[XLR_START_RI] && conv_active;

  assign clear_done_on_read =
      conv_active && slrx_regs_intrf.xlr_done_ack;

  //===========================================================================
  // Host registers
  //===========================================================================
  logic [XMEM_ADDR_WIDTH-1:0] conv_kernel_addr;
  logic [XMEM_ADDR_WIDTH-1:0] conv_arr_in_addr;
  logic [XMEM_ADDR_WIDTH-1:0] conv_arr_out_addr;

  logic signed [MAX_DOT_PROD_WIDTH-1:0] conv_bias_val;

  logic [ARR_IDX_W:0] conv_arr_in_dim;
  logic [ARR_IDX_W:0] conv_arr_out_dim;

  assign conv_kernel_addr  = slrx_regs_intrf.host_regs[WGT_ADDR_RI];
  assign conv_arr_in_addr  = slrx_regs_intrf.host_regs[ARR_IN_ADDR_RI];
  assign conv_arr_out_addr = slrx_regs_intrf.host_regs[ARR_OUT_ADDR_RI];
  assign conv_arr_in_dim   = slrx_regs_intrf.host_regs[ARR_IN_DIM_RI];

  assign conv_bias_val =
      $signed(slrx_regs_intrf.host_regs[CONV_BIAS_VAL_RI][MAX_DOT_PROD_WIDTH-1:0]);

  assign conv_arr_out_dim = conv_arr_in_dim - (KERNEL_DIM - 1);

  //===========================================================================
  // Kernel storage
  //===========================================================================
  logic [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] kernel;
  logic [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] kernel_ps;

  //===========================================================================
  // Row buffer: 5 rows x up to 32 bytes
  //===========================================================================
  logic [KERNEL_DIM-1:0][DIM_MAX_SIZE-1:0][7:0] conv_rows_buf;
  logic [KERNEL_DIM-1:0][DIM_MAX_SIZE-1:0][7:0] conv_rows_buf_ps;

  logic [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] conv_win;
  logic [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] conv_win_ps;

  //===========================================================================
  // Internal hardware loop indices
  //===========================================================================
  logic [ARR_IDX_W-1:0] hw_out_row_idx;
  logic [ARR_IDX_W-1:0] hw_out_row_idx_ps;

  logic [ARR_IDX_W-1:0] hw_out_col_idx;
  logic [ARR_IDX_W-1:0] hw_out_col_idx_ps;

  logic [ARR_IDX_W-1:0] buf_load_row_idx;
  logic [ARR_IDX_W-1:0] buf_load_row_idx_ps;

  logic is_last_buf_row;
  logic is_last_out_col;
  logic is_last_out_row;

  assign is_last_buf_row = (buf_load_row_idx == (KERNEL_DIM - 1));
  assign is_last_out_col = (hw_out_col_idx == (conv_arr_out_dim - 1));
  assign is_last_out_row = (hw_out_row_idx == (conv_arr_out_dim - 1));

  //===========================================================================
  // Address counters
  //===========================================================================
  logic [XMEM_ADDR_WIDTH-1:0] row_start_addr;
  logic [XMEM_ADDR_WIDTH-1:0] row_start_addr_ps;

  logic [XMEM_ADDR_WIDTH-1:0] arr_in_row_addr;
  logic [XMEM_ADDR_WIDTH-1:0] arr_in_row_addr_ps;

  logic [XMEM_ADDR_WIDTH-1:0] conv_rslt_out_addr;
  logic [XMEM_ADDR_WIDTH-1:0] conv_rslt_out_addr_ps;

  //===========================================================================
  // Output value
  //===========================================================================
  logic [7:0] conv_out_val;
  logic [7:0] conv_out_val_ps;

  assign conv_out_val_ps = calc_conv_win(kernel, conv_bias_val, conv_win);

  //===========================================================================
  // FSM combinational logic
  //===========================================================================
  always_comb begin

    // Defaults
    next_state = state;

    conv_done = 1'b0;

    mem_intf_read.mem_req        = 1'b0;
    mem_intf_read.mem_start_addr = '0;
    mem_intf_read.mem_size_bytes = '0;

    mem_intf_write.mem_req        = 1'b0;
    mem_intf_write.mem_start_addr = conv_rslt_out_addr;
    mem_intf_write.mem_size_bytes = 1;
    mem_intf_write.mem_data       = conv_out_val;

    kernel_ps             = kernel;
    conv_rows_buf_ps      = conv_rows_buf;
    conv_win_ps           = conv_win;

    hw_out_row_idx_ps     = hw_out_row_idx;
    hw_out_col_idx_ps     = hw_out_col_idx;
    buf_load_row_idx_ps   = buf_load_row_idx;

    row_start_addr_ps     = row_start_addr;
    arr_in_row_addr_ps    = arr_in_row_addr;
    conv_rslt_out_addr_ps = conv_rslt_out_addr;

    case (state)

      //=======================================================================
      // IDLE
      //=======================================================================
      IDLE: begin
        if (conv_start) begin

          if (slrx_cmd == CONV_SETUP) begin
            next_state = READ_KERNEL;
          end

          else if (slrx_cmd == CONV_WINDOW) begin
            // Start full feature-map computation.
            hw_out_row_idx_ps     = '0;
            hw_out_col_idx_ps     = '0;
            buf_load_row_idx_ps   = '0;

            row_start_addr_ps     = conv_arr_in_addr;
            arr_in_row_addr_ps    = conv_arr_in_addr;
            conv_rslt_out_addr_ps = conv_arr_out_addr;

            next_state = READ_ROWS;
          end
        end
      end

      //=======================================================================
      // READ_KERNEL
      // Load all 25 kernel bytes once.
      //=======================================================================
      READ_KERNEL: begin
        mem_intf_read.mem_req        = 1'b1;
        mem_intf_read.mem_start_addr = conv_kernel_addr;
        mem_intf_read.mem_size_bytes = KERNEL_SIZE;

        if (mem_intf_read.mem_valid) begin
          for (int r = 0; r < KERNEL_DIM; r++) begin
            for (int c = 0; c < KERNEL_DIM; c++) begin
              kernel_ps[r][c] = mem_intf_read.mem_data[r*KERNEL_DIM + c];
            end
          end

          next_state = DONE;
        end
      end

      //=======================================================================
      // READ_ROWS
      // For each output row, load 5 input rows once.
      // Then all output columns reuse these rows.
      //=======================================================================
      READ_ROWS: begin
        mem_intf_read.mem_req        = 1'b1;
        mem_intf_read.mem_start_addr = arr_in_row_addr;
        mem_intf_read.mem_size_bytes = conv_arr_in_dim;

        if (mem_intf_read.mem_valid) begin

          for (int c = 0; c < DIM_MAX_SIZE; c++) begin
            conv_rows_buf_ps[buf_load_row_idx][c] =
                (c < conv_arr_in_dim) ? mem_intf_read.mem_data[c] : 8'd0;
          end

          arr_in_row_addr_ps = arr_in_row_addr + conv_arr_in_dim;

          if (is_last_buf_row) begin
            buf_load_row_idx_ps = '0;
            next_state = WINDOW;
          end
          else begin
            buf_load_row_idx_ps = buf_load_row_idx + 1'b1;
            next_state = READ_ROWS;
          end
        end
      end

      //=======================================================================
      // WINDOW
      // Extract 5x5 window from the 5-row buffer according to hw_out_col_idx.
      //=======================================================================
      WINDOW: begin
        for (int r = 0; r < KERNEL_DIM; r++) begin
          for (int c = 0; c < KERNEL_DIM; c++) begin
            conv_win_ps[r][c] = conv_rows_buf[r][hw_out_col_idx + c];
          end
        end

        next_state = CALC;
      end

      //=======================================================================
      // CALC
      // One cycle for conv_out_val to be sampled from combinational calc.
      //=======================================================================
      CALC: begin
        next_state = WRITE;
      end

      //=======================================================================
      // WRITE
      // Write one output pixel. Then either:
      // - advance to next column without rereading rows, or
      // - advance to next output row and load 5 new rows, or
      // - finish full output image.
      //=======================================================================
      WRITE: begin
        mem_intf_write.mem_req        = 1'b1;
        mem_intf_write.mem_start_addr = conv_rslt_out_addr;
        mem_intf_write.mem_size_bytes = 1;
        mem_intf_write.mem_data       = conv_out_val;

        if (mem_intf_write.mem_ack) begin

          // Output is contiguous, so always advance output pointer after write.
          conv_rslt_out_addr_ps = conv_rslt_out_addr + 1'b1;

          if (is_last_out_col) begin

            if (is_last_out_row) begin
              next_state = DONE;
            end

            else begin
              // Move to next output row.
              hw_out_row_idx_ps   = hw_out_row_idx + 1'b1;
              hw_out_col_idx_ps   = '0;
              buf_load_row_idx_ps = '0;

              // Next output row starts one input row lower.
              row_start_addr_ps  = row_start_addr + conv_arr_in_dim;
              arr_in_row_addr_ps = row_start_addr + conv_arr_in_dim;

              next_state = READ_ROWS;
            end
          end

          else begin
            // Same output row: reuse the already loaded 5 rows.
            hw_out_col_idx_ps = hw_out_col_idx + 1'b1;
            next_state = WINDOW;
          end
        end
      end

      //=======================================================================
      // DONE
      //=======================================================================
      DONE: begin
        conv_done = 1'b1;

        if (clear_done_on_read) begin
          next_state = IDLE;
        end
      end

      default: begin
        next_state = IDLE;
      end

    endcase
  end

  //===========================================================================
  // Sequential logic
  //===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state              <= IDLE;

      kernel             <= '0;
      conv_rows_buf      <= '0;
      conv_win           <= '0;

      hw_out_row_idx     <= '0;
      hw_out_col_idx     <= '0;
      buf_load_row_idx   <= '0;

      row_start_addr     <= '0;
      arr_in_row_addr    <= '0;
      conv_rslt_out_addr <= '0;

      conv_out_val       <= '0;
    end

    else begin
      state              <= next_state;

      kernel             <= kernel_ps;
      conv_rows_buf      <= conv_rows_buf_ps;
      conv_win           <= conv_win_ps;

      hw_out_row_idx     <= hw_out_row_idx_ps;
      hw_out_col_idx     <= hw_out_col_idx_ps;
      buf_load_row_idx   <= buf_load_row_idx_ps;

      row_start_addr     <= row_start_addr_ps;
      arr_in_row_addr    <= arr_in_row_addr_ps;
      conv_rslt_out_addr <= conv_rslt_out_addr_ps;

      conv_out_val       <= conv_out_val_ps;
    end
  end

  //===========================================================================
  // Convolution function:
  //   acc = bias + sum(uint8 input * int8 kernel)
  //   if acc <= 0: 0
  //   else: acc / 256, saturated to 255
  //===========================================================================
  function automatic logic [7:0] calc_conv_win;

    input        [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] kernel;
    input signed [MAX_DOT_PROD_WIDTH-1:0]              conv_bias_val;
    input        [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] conv_win;

    logic signed [MAX_DOT_PROD_WIDTH-1:0] acc;
    logic signed [MAX_DOT_PROD_WIDTH-1:0] ret_val_int;
    logic signed [16:0]                   mult;

    begin
      acc = conv_bias_val;

      for (int r = 0; r < KERNEL_DIM; r++) begin
        for (int c = 0; c < KERNEL_DIM; c++) begin
          mult = $signed({1'b0, conv_win[r][c]}) * $signed(kernel[r][c]);
          acc  = acc + mult;
        end
      end

      if (acc <= 0) begin
        calc_conv_win = 8'd0;
      end
      else begin
        ret_val_int = acc >>> 8;

        if (|ret_val_int[MAX_DOT_PROD_WIDTH-1:8]) begin
          calc_conv_win = 8'd255;
        end
        else begin
          calc_conv_win = ret_val_int[7:0];
        end
      end
    end

  endfunction

endmodule
