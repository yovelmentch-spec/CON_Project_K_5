//=============================================================================
// File: conv.sv
// Description: Convolution Accelerator Module
//              Implements a 5x5 convolution operation with ReLU activation
//              and bias addition. Supports configurable input/output dimensions
//              up to 32x32.
//=============================================================================

import xbox_def_pkg::*;      // XMEM interface definitions
import slrx_def_pkg::*;      // SLRX register interface definitions

//=============================================================================
// Module: conv
// Description: Convolution engine with state machine control. Reads kernel
//              weights and input data from XMEM, computes convolution windows,
//              applies bias and ReLU, then writes results back to XMEM.
//=============================================================================
module conv (
  input   clk,                           // System clock
  input   rst_n,                         // Active-low asynchronous reset
  
  //---------------------------------------------------------------------------
  // Command Status Register Interface
  //---------------------------------------------------------------------------
  slrx_regs_intrf.xlr slrx_regs_intrf,   // Host registers interface for SW control

  //---------------------------------------------------------------------------
  // Memory Interfaces
  //---------------------------------------------------------------------------
  mem_intf_read.client_read   mem_intf_read,  // XMEM read interface (kernel & input data)
  mem_intf_write.client_write mem_intf_write  // XMEM write interface (output results)
);

  //===========================================================================
  // State Machine Declaration
  //===========================================================================
  enum {  
     IDLE,               // Idle state, waiting for host trigger command
     READ_KERNEL,        // Load 5x5 convolution kernel from memory
     READ_ROWS,          // Load input data rows (image or feature map) into buffer
     WINDOW,             // Extract the 5x5 convolution window from buffered rows
     CALC,               // Perform convolution calculation on the current window
     WRITE,              // Write the calculated output element back to memory
     DONE                // Operation complete, notify host via done flag
  } next_state, state;   // Current and next state registers

  //===========================================================================
  // Local Parameters
  //===========================================================================
  localparam DIM_MAX_SIZE = 32;          // Maximum supported dimension (rows/cols)
  localparam KERNEL_DIM = 5;             // Kernel dimension (fixed to 5x5)
  localparam KERNEL_SIZE = KERNEL_DIM*KERNEL_DIM;  // Total kernel elements (25)
  
  // Maximum bit-width for dot product: 8-bit data * 8-bit kernel + accumulation
  // 16 bits for multiplication + log2(25) bits for accumulation
  localparam MAX_DOT_PROD_WIDTH = 16+$clog2(KERNEL_SIZE);

  localparam ARR_IDX_W = $clog2(DIM_MAX_SIZE);  // Bit-width for array indices (0-31)

  //===========================================================================
  // Control Signals
  //===========================================================================
  logic conv_start;             // Start trigger pulse from host
  logic conv_done;              // Done flag asserted when convolution completes
  logic clear_done_on_read;     // Clear done flag when host reads done register

  //===========================================================================
  // Kernel Storage
  //===========================================================================
  logic [KERNEL_DIM-1:0] [KERNEL_DIM-1:0] [7:0] kernel;       // 5x5 convolution kernel (current)
  logic [KERNEL_DIM-1:0] [KERNEL_DIM-1:0] [7:0] kernel_ps;    // Pre-sampled kernel 

  //===========================================================================
  // Input Data Buffer
  // Description: Stores up to 5 rows of input data, each row up to 32 elements.
  //              Reading up to 32 bytes has no extra cost, so we load max size
  //              per row regardless of actual layer dimensions.
  //===========================================================================
  logic [KERNEL_DIM-1:0] [DIM_MAX_SIZE-1:0] [7:0] conv_rows_buf;      // buffer for current window
  logic [KERNEL_DIM-1:0] [DIM_MAX_SIZE-1:0] [7:0] conv_rows_buf_ps;   // Pre-sampled buffer

  //===========================================================================
  // Memory Addresses (Configured by Host)
  //===========================================================================
  logic [XMEM_ADDR_WIDTH-1:0] conv_kernel_addr;    // Start address of kernel in XMEM
  logic [XMEM_ADDR_WIDTH-1:0] conv_arr_in_addr;    // Start address of input data in XMEM
  logic [XMEM_ADDR_WIDTH-1:0] conv_arr_out_addr;   // Start address for output data in XMEM

  // Current output element address (computed during operation)
  logic [XMEM_ADDR_WIDTH-1:0] conv_rslt_out_addr;
  logic [XMEM_ADDR_WIDTH-1:0] conv_rslt_out_addr_ps;   // Pre-sampled output address

  //===========================================================================
  // Layer Configuration (from Host Registers)
  //===========================================================================
  logic [MAX_DOT_PROD_WIDTH-1:0] conv_bias_val;   // Bias value for current layer (constant)

  logic [ARR_IDX_W:0] conv_arr_in_dim;    // Input array dimension (rows/cols)
  logic [ARR_IDX_W:0] conv_arr_out_dim;   // Output array dimension (computed)

  logic [ARR_IDX_W-1:0] conv_out_row_idx; // Current output row index being computed
  logic [ARR_IDX_W-1:0] conv_out_col_idx; // Current output column index being computed

  //===========================================================================
  // Memory Addressing Signals
  //===========================================================================
  logic [XMEM_ADDR_WIDTH-1:0] arr_in_row_addr;      // Current input row address for reading
  logic [XMEM_ADDR_WIDTH-1:0] arr_in_row_addr_ps;   // Pre-sampled input row address

  //===========================================================================
  // Output Value
  //===========================================================================
  logic [7:0] conv_out_val;      // Calculated convolution output value
  logic [7:0] conv_out_val_ps;   // Pre-sampled output valueng

  //===========================================================================
  // Buffer Control
  //===========================================================================
  logic [ARR_IDX_W-1:0] buf_load_row_idx;        // Current row index being loaded into buffer
  logic [ARR_IDX_W-1:0] buf_load_row_idx_ps;     // Pre-sampled row index
  
  logic is_last_load_row;   // Flag indicating last row (row 4) is being loaded

  //===========================================================================
  // Operation Control
  //===========================================================================
  logic conv_active;   // Indicates accelerator is active (setup or window command)

  //===========================================================================
  // Host Register Interface Connections
  //===========================================================================
  
  // Propagate done flag to host interface for SW polling.
  assign slrx_regs_intrf.xlr_done = conv_done;

  // Extract command from host registers (defined in slrx_enums.svh)
  assign slrx_cmd = slrx_cmd_t'(slrx_regs_intrf.host_regs[XLR_START_RI][$clog2(NUM_SLRX_CMDS)-1:0]);

  // Accelerator is active for CONV_SETUP (load kernel) or CONV_WINDOW (execute)
  assign conv_active = (slrx_cmd == CONV_SETUP) || (slrx_cmd == CONV_WINDOW);

  // Start trigger: host writes to start register while accelerator is active
  assign conv_start = slrx_regs_intrf.host_regs_valid_pulse[XLR_START_RI] && conv_active;

  // Clear done flag when host acknowledges reading the done register
  assign clear_done_on_read = conv_active && slrx_regs_intrf.xlr_done_ack;

  //===========================================================================
  // Obtain Host Register SW provides configuration
  //===========================================================================
  assign conv_kernel_addr = slrx_regs_intrf.host_regs[WGT_ADDR_RI];     // Kernel address register
  assign conv_bias_val  = $signed(slrx_regs_intrf.host_regs[CONV_BIAS_VAL_RI][MAX_DOT_PROD_WIDTH-1:0]);  // Bias value

  assign conv_arr_in_addr  = slrx_regs_intrf.host_regs[ARR_IN_ADDR_RI];  // Input data address
  assign conv_arr_out_addr = slrx_regs_intrf.host_regs[ARR_OUT_ADDR_RI]; // Output data address
  assign conv_arr_in_dim   = slrx_regs_intrf.host_regs[ARR_IN_DIM_RI];   // Input dimension (NxN)
  
  assign conv_out_row_idx = slrx_regs_intrf.host_regs[OUT_ROW_IDX_RI];   // Output row index
  assign conv_out_col_idx = slrx_regs_intrf.host_regs[OUT_COL_IDX_RI];   // Output column index

  // Compute output dimension: input dimension reduced by kernel dimension minus 1
  // For 5x5 kernel: output_dim = input_dim - 4
  assign conv_arr_out_dim = conv_arr_in_dim - (KERNEL_DIM - 1);

  // Last row indicator: buffer row index reaches KERNEL_DIM-1 (row 4)
  assign is_last_load_row = (buf_load_row_idx == (KERNEL_DIM - 1));

  // Calculate current output destination address in XMEM:
  // Base address + (row * output_dimension) + column
  assign conv_rslt_out_addr_ps = conv_arr_out_addr + 
                                 (conv_out_row_idx * conv_arr_out_dim) + 
                                 conv_out_col_idx;

  //===========================================================================
  // State Machine - Combinational Logic
  // Description: Implements the convolution control flow using a simple
  //              non-pipelined state machine. Each state performs a specific
  //              operation: reading kernel, loading input rows, extracting
  //              windows, calculating, writing results, or completion.
  //===========================================================================
  always_comb begin
  
    //-------------------------------------------------------------------------
    // Default Output Assignments
    //-------------------------------------------------------------------------
    next_state = state;   // Stay in current state by default

    // Memory read interface defaults
    mem_intf_read.mem_size_bytes  = 0;      // Zero by default
    mem_intf_read.mem_start_addr  = 0;      
    mem_intf_read.mem_req         = 0;

    // Memory write interface defaults
    mem_intf_write.mem_size_bytes = 1;                   // Always write a single byte (8-bit output)
    mem_intf_write.mem_data       = conv_out_val;        // Continuously assigned to calculated value
    mem_intf_write.mem_start_addr = conv_rslt_out_addr;  // Continuously assigned to output address
    mem_intf_write.mem_req        = 0;                   // No request by default

    conv_done = 0;   // Done flag de-asserted by default

    // Pre-sampled signals default to current values (no change)
    buf_load_row_idx_ps = buf_load_row_idx;
    conv_rows_buf_ps    = conv_rows_buf;
    arr_in_row_addr_ps  = arr_in_row_addr;
    kernel_ps = kernel;

    //-------------------------------------------------------------------------
    // State Machine Case
    //-------------------------------------------------------------------------
    case (state)
   
      //=======================================================================
      // IDLE: Wait for host trigger
      //=======================================================================
      IDLE: 
        if (conv_start) begin
          // Determine next state based on command
          if (slrx_cmd == CONV_SETUP) begin
            // Setup only: load kernel, then go to DONE waiting for execution
            next_state = READ_KERNEL;
          end 
          else if (slrx_cmd == CONV_WINDOW) begin
            // Execute convolution: load input rows and process
            next_state = READ_ROWS;
            // Calculate starting row address: base + (output_row * input_dimension)
            arr_in_row_addr_ps = conv_arr_in_addr + (conv_out_row_idx * conv_arr_in_dim);
          end
          // Reset buffer row index for new operation
          buf_load_row_idx_ps = 0;
        end
      
      //=======================================================================
      // READ_KERNEL: Load 5x5 kernel from XMEM
      //=======================================================================
      READ_KERNEL: begin
        // Request memory read for kernel data
        mem_intf_read.mem_req = 1;
        mem_intf_read.mem_start_addr = conv_kernel_addr;
        mem_intf_read.mem_size_bytes = KERNEL_SIZE;   // Read all 25 bytes
        
        // Wait for memory to return valid data
        if (mem_intf_read.mem_valid) begin
          // Capture kernel data into pre-sampled register
          kernel_ps = mem_intf_read.mem_data[KERNEL_SIZE-1:0];
          // Kernel loaded, return to DONE state
          next_state = DONE;
        end
      end 

      //=======================================================================
      // READ_ROWS: Load input data rows into buffer
      // Description: Loads 5 rows of input data. Each row loads
      //              DIM_MAX_SIZE (32) elements regardless of actual dimension.
      //=======================================================================
      READ_ROWS: begin
      
        // Request memory read for current input row
        mem_intf_read.mem_req = 1;
        mem_intf_read.mem_start_addr = arr_in_row_addr;
        mem_intf_read.mem_size_bytes = DIM_MAX_SIZE;   // Read full row (max 32 bytes)
 
        // Pre-calculate next row address for sampling
        arr_in_row_addr_ps = arr_in_row_addr + conv_arr_in_dim;
        
        // Wait for memory to return valid data
        if (mem_intf_read.mem_valid) begin
          // Store data into current buffer row
          conv_rows_buf_ps[buf_load_row_idx] = mem_intf_read.mem_data;
          
          if (is_last_load_row) begin
            // All 5 rows loaded, proceed to window extraction
            next_state = WINDOW;
            mem_intf_read.mem_req = 0;   // De-assert read request
          end 
          else begin        
            // Not finished: advance to next buffer row
            mem_intf_read.mem_start_addr = arr_in_row_addr;  // Keep address for current row
            buf_load_row_idx_ps = buf_load_row_idx + 1;
            // Remain in READ_ROWS state to load next row
          end
        end
      end // READ_ROWS
 
      //=======================================================================
      // WINDOW: Extract convolution window from buffer
      // Description: A single-cycle state to allow sampling of the window
      //              data into the pre-sampled register.
      //=======================================================================
      WINDOW: 
        next_state = CALC;

      //=======================================================================
      // CALC: Perform convolution calculation
      // Description: A single-cycle state to allow the combinational
      //              calculation to settle and be sampled.
      //=======================================================================
      CALC:  
        next_state = WRITE;

      //=======================================================================
      // WRITE: Write calculated output element to XMEM
      //=======================================================================
      WRITE: begin
        // Request memory write
        mem_intf_write.mem_req = 1;
        
        // Wait for memory to acknowledge write completion
        if (mem_intf_write.mem_ack) begin
          next_state = DONE;
          mem_intf_write.mem_req = 0;   // De-assert write request
        end
      end 

      //=======================================================================
      // DONE: Operation complete, notify host
      //=======================================================================
      DONE: begin
        conv_done = 1;   // Assert done flag for host to read
        
        // Return to IDLE only after host acknowledges reading the done flag
        if (clear_done_on_read) begin
          next_state = IDLE;
        end
      end 
 
    endcase
   
  end // always_comb

  //===========================================================================
  // Window Extraction Logic
  // Description: Extracts a 5x5 window from the rolling buffer based on
  //              the current output column index. The window is used for
  //              convolution calculation.
  //===========================================================================
  logic [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] conv_win_ps;   // Pre-sampled window
  logic [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] conv_win;      // Current window

  // Window slicing: extract KERNEL_DIM x KERNEL_DIM window starting at conv_out_col_idx
  always_comb begin
    conv_win_ps = conv_win;   // Default: no change
     
    // Sample window during WINDOW state
    if (state == WINDOW) begin
      for (int i = 0; i < KERNEL_DIM; i++) begin
        for (int j = 0; j < KERNEL_DIM; j++) begin
          // Extract element at buffer row i, column (conv_out_col_idx + j)
          conv_win_ps[i][j] = conv_rows_buf[i][conv_out_col_idx + j];
        end
      end
    end
  end

  //===========================================================================
  // Convolution Calculation
  // Description: Compute convolution result using combinational function.
  //              The result is pre-sampled for pipelining.
  //===========================================================================
  assign conv_out_val_ps = calc_conv_win(kernel, conv_bias_val, conv_win);

  //===========================================================================
  // Sequential Logic - Sample all pre-sampled values
  // Description: All sequential registers are updated on the rising clock edge.
  //===========================================================================
  always @(posedge clk or negedge rst_n) begin
  
    if (!rst_n) begin  
      // Asynchronous reset: initialize all state variables
      state              <= IDLE;
      arr_in_row_addr    <= 0;
      buf_load_row_idx   <= 0;
      kernel             <= 0;
      conv_rows_buf      <= 0;
      conv_out_val       <= 0;
      conv_win           <= 0;
      conv_rslt_out_addr <= 0;
    end 
    else begin
      // Sample pre-sampled values on each clock edge
      state              <= next_state;
      arr_in_row_addr    <= arr_in_row_addr_ps;
      buf_load_row_idx   <= buf_load_row_idx_ps;
      kernel             <= kernel_ps;
      conv_rows_buf      <= conv_rows_buf_ps;
      conv_out_val       <= conv_out_val_ps;
      conv_win           <= conv_win_ps;
      conv_rslt_out_addr <= conv_rslt_out_addr_ps;
    end    
  end

  //===========================================================================
  // Convolution Calculation Function
  // Description: Computes a single convolution window result.
  //              Operation: bias + sum(kernel[i][j] * data[i][j])
  //              Then apply ReLU and descale by dividing by 256.
  //===========================================================================
  function automatic logic [7:0] calc_conv_win;
  
      input [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] kernel;
      input signed [MAX_DOT_PROD_WIDTH-1:0] conv_bias_val;
      input [KERNEL_DIM-1:0][KERNEL_DIM-1:0][7:0] conv_win;

      logic signed [MAX_DOT_PROD_WIDTH-1:0] acc;
      logic signed [MAX_DOT_PROD_WIDTH-1:0] mult;
      logic signed [MAX_DOT_PROD_WIDTH-1:0] descale_val;

      begin
        // acc = bias
        acc = conv_bias_val;

        // acc += input * weight
        for (int kernel_row_idx = 0; kernel_row_idx < KERNEL_DIM; kernel_row_idx++) begin
          for (int kernel_col_idx = 0; kernel_col_idx < KERNEL_DIM; kernel_col_idx++) begin

            mult = $signed({1'b0, conv_win[kernel_row_idx][kernel_col_idx]}) *
                   $signed(kernel[kernel_row_idx][kernel_col_idx]);

            acc = acc + mult;
          end
        end

        // ReLU + descale by 8 bits
        if (acc < 0) begin
          calc_conv_win = 8'd0;
        end
        else begin
          descale_val = acc >>> 8;

          // saturation to 8-bit unsigned
          if (descale_val > 255) begin
            calc_conv_win = 8'd255;
          end
          else begin
            calc_conv_win = descale_val[7:0];
          end
        end
      end
        
  endfunction
endmodule