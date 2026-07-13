module fft_engine #(
  parameter int MAX_N      = 256,
  parameter int DATA_WIDTH = 32
)(
  input  logic clk,
  input  logic rst_n,

  input  logic start,
  input  logic inverse,
  input  logic [31:0] n,

  input  logic signed [DATA_WIDTH-1:0] in_re [0:MAX_N-1],
  input  logic signed [DATA_WIDTH-1:0] in_im [0:MAX_N-1],

  output logic signed [DATA_WIDTH-1:0] out_re [0:MAX_N-1],
  output logic signed [DATA_WIDTH-1:0] out_im [0:MAX_N-1],

  output logic busy,
  output logic done
);

  typedef enum logic [2:0] {
    S_IDLE,
    S_BITREV_COPY,
    S_STAGE_INIT,
    S_BUTTERFLY_READ,
    S_BUTTERFLY_WRITE,
    S_DONE
  } state_t;

  state_t state;

  logic signed [DATA_WIDTH-1:0] buf_re [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] buf_im [0:MAX_N-1];

  logic [31:0] copy_idx;
  logic [31:0] log2n;

  logic [31:0] stage_len;
  logic [31:0] half_len;
  logic [31:0] block_base;
  logic [31:0] j_idx;

  logic [31:0] even_idx;
  logic [31:0] odd_idx;

  logic signed [DATA_WIDTH-1:0] u_re_reg;
  logic signed [DATA_WIDTH-1:0] u_im_reg;
  logic signed [DATA_WIDTH-1:0] t_re_reg;
  logic signed [DATA_WIDTH-1:0] t_im_reg;

  logic signed [DATA_WIDTH-1:0] w_re_tmp;
  logic signed [DATA_WIDTH-1:0] w_im_tmp;

  logic signed [DATA_WIDTH-1:0] v_re_tmp;
  logic signed [DATA_WIDTH-1:0] v_im_tmp;

  logic signed [DATA_WIDTH-1:0] t_re_tmp;
  logic signed [DATA_WIDTH-1:0] t_im_tmp;

  logic signed [DATA_WIDTH:0] even_re_wide;
  logic signed [DATA_WIDTH:0] even_im_wide;
  logic signed [DATA_WIDTH:0] odd_re_wide;
  logic signed [DATA_WIDTH:0] odd_im_wide;

  assign even_idx = block_base + j_idx;
  assign odd_idx  = block_base + j_idx + half_len;

  always_comb begin
    for (int i = 0; i < MAX_N; i++) begin
      out_re[i] = buf_re[i];
      out_im[i] = buf_im[i];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      busy       <= 1'b0;
      done       <= 1'b0;

      copy_idx   <= 32'd0;
      log2n      <= 32'd0;
      stage_len  <= 32'd0;
      half_len   <= 32'd0;
      block_base <= 32'd0;
      j_idx      <= 32'd0;

      u_re_reg <= '0;
      u_im_reg <= '0;
      t_re_reg <= '0;
      t_im_reg <= '0;

      w_re_tmp <= '0;
      w_im_tmp <= '0;
      v_re_tmp <= '0;
      v_im_tmp <= '0;
      t_re_tmp <= '0;
      t_im_tmp <= '0;

      even_re_wide <= '0;
      even_im_wide <= '0;
      odd_re_wide  <= '0;
      odd_im_wide  <= '0;

      for (int i = 0; i < MAX_N; i++) begin
        buf_re[i] <= '0;
        buf_im[i] <= '0;
      end
    end
    else begin
      done <= 1'b0;

      case (state)

        S_IDLE: begin
          busy <= 1'b0;

          if (start) begin
            busy     <= 1'b1;
            copy_idx <= 32'd0;
            log2n    <= calc_log2(n);

            for (int i = 0; i < MAX_N; i++) begin
              buf_re[i] <= '0;
              buf_im[i] <= '0;
            end

            state <= S_BITREV_COPY;
          end
        end

        S_BITREV_COPY: begin
          if (copy_idx < n) begin
            buf_re[bit_reverse_var(copy_idx, log2n)] <= in_re[copy_idx];
            buf_im[bit_reverse_var(copy_idx, log2n)] <= in_im[copy_idx];

            copy_idx <= copy_idx + 32'd1;
          end
          else begin
            state <= S_STAGE_INIT;
          end
        end

        S_STAGE_INIT: begin
          stage_len  <= 32'd2;
          half_len   <= 32'd1;
          block_base <= 32'd0;
          j_idx      <= 32'd0;
          state      <= S_BUTTERFLY_READ;
        end

        S_BUTTERFLY_READ: begin
          get_twiddle(stage_len, j_idx, inverse, w_re_tmp, w_im_tmp);

          v_re_tmp = buf_re[odd_idx];
          v_im_tmp = buf_im[odd_idx];

          complex_mul_q15(
            v_re_tmp,
            v_im_tmp,
            w_re_tmp,
            w_im_tmp,
            t_re_tmp,
            t_im_tmp
          );

          u_re_reg <= buf_re[even_idx];
          u_im_reg <= buf_im[even_idx];

          t_re_reg <= t_re_tmp;
          t_im_reg <= t_im_tmp;

          state <= S_BUTTERFLY_WRITE;
        end

        S_BUTTERFLY_WRITE: begin
          even_re_wide = ($signed({u_re_reg[DATA_WIDTH-1], u_re_reg}) +
                          $signed({t_re_reg[DATA_WIDTH-1], t_re_reg})) >>> 1;

          even_im_wide = ($signed({u_im_reg[DATA_WIDTH-1], u_im_reg}) +
                          $signed({t_im_reg[DATA_WIDTH-1], t_im_reg})) >>> 1;

          odd_re_wide  = ($signed({u_re_reg[DATA_WIDTH-1], u_re_reg}) -
                          $signed({t_re_reg[DATA_WIDTH-1], t_re_reg})) >>> 1;

          odd_im_wide  = ($signed({u_im_reg[DATA_WIDTH-1], u_im_reg}) -
                          $signed({t_im_reg[DATA_WIDTH-1], t_im_reg})) >>> 1;

          buf_re[even_idx] <= even_re_wide[DATA_WIDTH-1:0];
          buf_im[even_idx] <= even_im_wide[DATA_WIDTH-1:0];

          buf_re[odd_idx]  <= odd_re_wide[DATA_WIDTH-1:0];
          buf_im[odd_idx]  <= odd_im_wide[DATA_WIDTH-1:0];

          if (j_idx == half_len - 32'd1) begin
            j_idx <= 32'd0;

            if (block_base + stage_len >= n) begin
              block_base <= 32'd0;

              if (stage_len >= n) begin
                state <= S_DONE;
              end
              else begin
                half_len  <= stage_len;
                stage_len <= stage_len << 1;
                state     <= S_BUTTERFLY_READ;
              end
            end
            else begin
              block_base <= block_base + stage_len;
              state      <= S_BUTTERFLY_READ;
            end
          end
          else begin
            j_idx <= j_idx + 32'd1;
            state <= S_BUTTERFLY_READ;
          end
        end

        S_DONE: begin
          busy  <= 1'b0;
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: begin
          state <= S_IDLE;
          busy  <= 1'b0;
          done  <= 1'b0;
        end

      endcase
    end
  end

  function automatic logic [31:0] calc_log2(input logic [31:0] val);
    logic [31:0] tmp;
    begin
      tmp = val;
      calc_log2 = 32'd0;

      while (tmp > 32'd1) begin
        tmp = tmp >> 1;
        calc_log2 = calc_log2 + 32'd1;
      end
    end
  endfunction

  function automatic logic [31:0] bit_reverse_var(
    input logic [31:0] x,
    input logic [31:0] bits
  );
    logic [31:0] r;
    logic [31:0] x_tmp;
    begin
      r     = 32'd0;
      x_tmp = x;

      for (int k = 0; k < 32; k++) begin
        if (k < bits) begin
          r     = (r << 1) | (x_tmp & 32'd1);
          x_tmp = x_tmp >> 1;
        end
      end

      bit_reverse_var = r;
    end
  endfunction

  function automatic logic signed [DATA_WIDTH-1:0] q15_mul(
    input logic signed [DATA_WIDTH-1:0] a,
    input logic signed [DATA_WIDTH-1:0] b
  );
    logic signed [63:0] t;
    begin
      t = $signed(a) * $signed(b);
      t = t + 64'sd16384;
      q15_mul = t >>> 15;
    end
  endfunction

  task automatic complex_mul_q15(
    input  logic signed [DATA_WIDTH-1:0] a_re,
    input  logic signed [DATA_WIDTH-1:0] a_im,
    input  logic signed [DATA_WIDTH-1:0] b_re,
    input  logic signed [DATA_WIDTH-1:0] b_im,
    output logic signed [DATA_WIDTH-1:0] y_re,
    output logic signed [DATA_WIDTH-1:0] y_im
  );
    begin
      y_re = q15_mul(a_re, b_re) - q15_mul(a_im, b_im);
      y_im = q15_mul(a_re, b_im) + q15_mul(a_im, b_re);
    end
  endtask

  task automatic get_twiddle(
    input  logic [31:0] length,
    input  logic [31:0] j,
    input  logic        inverse,
    output logic signed [DATA_WIDTH-1:0] re,
    output logic signed [DATA_WIDTH-1:0] im
  );
    logic [31:0] k;
    logic signed [DATA_WIDTH-1:0] im_fwd;
    begin
      case (length)
        32'd2:   k = j << 7;
        32'd4:   k = j << 6;
        32'd8:   k = j << 5;
        32'd16:  k = j << 4;
        32'd32:  k = j << 3;
        32'd64:  k = j << 2;
        32'd128: k = j << 1;
        32'd256: k = j;
        default: k = 32'd0;
      endcase

      twiddle_256(k, re, im_fwd);

      if (inverse) begin
        im = -im_fwd;
      end
      else begin
        im = im_fwd;
      end
    end
  endtask

  task automatic twiddle_256(
    input  logic [31:0] k,
    output logic signed [DATA_WIDTH-1:0] re,
    output logic signed [DATA_WIDTH-1:0] im
  );
    begin
      case (k)
        32'd0: begin re = 32'sd32768; im = 32'sd0; end
        32'd1: begin re = 32'sd32758; im = -32'sd804; end
        32'd2: begin re = 32'sd32728; im = -32'sd1607; end
        32'd3: begin re = 32'sd32679; im = -32'sd2410; end
        32'd4: begin re = 32'sd32610; im = -32'sd3211; end
        32'd5: begin re = 32'sd32521; im = -32'sd4011; end
        32'd6: begin re = 32'sd32413; im = -32'sd4808; end
        32'd7: begin re = 32'sd32285; im = -32'sd5602; end
        32'd8: begin re = 32'sd32138; im = -32'sd6392; end
        32'd9: begin re = 32'sd31971; im = -32'sd7179; end
        32'd10: begin re = 32'sd31785; im = -32'sd7961; end
        32'd11: begin re = 32'sd31581; im = -32'sd8739; end
        32'd12: begin re = 32'sd31357; im = -32'sd9512; end
        32'd13: begin re = 32'sd31114; im = -32'sd10278; end
        32'd14: begin re = 32'sd30852; im = -32'sd11039; end
        32'd15: begin re = 32'sd30572; im = -32'sd11793; end
        32'd16: begin re = 32'sd30273; im = -32'sd12539; end
        32'd17: begin re = 32'sd29956; im = -32'sd13278; end
        32'd18: begin re = 32'sd29621; im = -32'sd14010; end
        32'd19: begin re = 32'sd29269; im = -32'sd14732; end
        32'd20: begin re = 32'sd28898; im = -32'sd15446; end
        32'd21: begin re = 32'sd28511; im = -32'sd16151; end
        32'd22: begin re = 32'sd28106; im = -32'sd16846; end
        32'd23: begin re = 32'sd27684; im = -32'sd17530; end
        32'd24: begin re = 32'sd27245; im = -32'sd18204; end
        32'd25: begin re = 32'sd26790; im = -32'sd18868; end
        32'd26: begin re = 32'sd26319; im = -32'sd19519; end
        32'd27: begin re = 32'sd25832; im = -32'sd20159; end
        32'd28: begin re = 32'sd25330; im = -32'sd20787; end
        32'd29: begin re = 32'sd24812; im = -32'sd21403; end
        32'd30: begin re = 32'sd24279; im = -32'sd22005; end
        32'd31: begin re = 32'sd23732; im = -32'sd22594; end
        32'd32: begin re = 32'sd23170; im = -32'sd23170; end
        32'd33: begin re = 32'sd22594; im = -32'sd23732; end
        32'd34: begin re = 32'sd22005; im = -32'sd24279; end
        32'd35: begin re = 32'sd21403; im = -32'sd24812; end
        32'd36: begin re = 32'sd20787; im = -32'sd25330; end
        32'd37: begin re = 32'sd20159; im = -32'sd25832; end
        32'd38: begin re = 32'sd19519; im = -32'sd26319; end
        32'd39: begin re = 32'sd18868; im = -32'sd26790; end
        32'd40: begin re = 32'sd18204; im = -32'sd27245; end
        32'd41: begin re = 32'sd17530; im = -32'sd27684; end
        32'd42: begin re = 32'sd16846; im = -32'sd28106; end
        32'd43: begin re = 32'sd16151; im = -32'sd28511; end
        32'd44: begin re = 32'sd15446; im = -32'sd28898; end
        32'd45: begin re = 32'sd14732; im = -32'sd29269; end
        32'd46: begin re = 32'sd14010; im = -32'sd29621; end
        32'd47: begin re = 32'sd13278; im = -32'sd29956; end
        32'd48: begin re = 32'sd12539; im = -32'sd30273; end
        32'd49: begin re = 32'sd11793; im = -32'sd30572; end
        32'd50: begin re = 32'sd11039; im = -32'sd30852; end
        32'd51: begin re = 32'sd10278; im = -32'sd31114; end
        32'd52: begin re = 32'sd9512;  im = -32'sd31357; end
        32'd53: begin re = 32'sd8739;  im = -32'sd31581; end
        32'd54: begin re = 32'sd7961;  im = -32'sd31785; end
        32'd55: begin re = 32'sd7179;  im = -32'sd31971; end
        32'd56: begin re = 32'sd6392;  im = -32'sd32138; end
        32'd57: begin re = 32'sd5602;  im = -32'sd32285; end
        32'd58: begin re = 32'sd4808;  im = -32'sd32413; end
        32'd59: begin re = 32'sd4011;  im = -32'sd32521; end
        32'd60: begin re = 32'sd3211;  im = -32'sd32610; end
        32'd61: begin re = 32'sd2410;  im = -32'sd32679; end
        32'd62: begin re = 32'sd1607;  im = -32'sd32728; end
        32'd63: begin re = 32'sd804;   im = -32'sd32758; end
        32'd64: begin re = 32'sd0;     im = -32'sd32768; end
        32'd65: begin re = -32'sd804;  im = -32'sd32758; end
        32'd66: begin re = -32'sd1607; im = -32'sd32728; end
        32'd67: begin re = -32'sd2410; im = -32'sd32679; end
        32'd68: begin re = -32'sd3211; im = -32'sd32610; end
        32'd69: begin re = -32'sd4011; im = -32'sd32521; end
        32'd70: begin re = -32'sd4808; im = -32'sd32413; end
        32'd71: begin re = -32'sd5602; im = -32'sd32285; end
        32'd72: begin re = -32'sd6392; im = -32'sd32138; end
        32'd73: begin re = -32'sd7179; im = -32'sd31971; end
        32'd74: begin re = -32'sd7961; im = -32'sd31785; end
        32'd75: begin re = -32'sd8739; im = -32'sd31581; end
        32'd76: begin re = -32'sd9512; im = -32'sd31357; end
        32'd77: begin re = -32'sd10278; im = -32'sd31114; end
        32'd78: begin re = -32'sd11039; im = -32'sd30852; end
        32'd79: begin re = -32'sd11793; im = -32'sd30572; end
        32'd80: begin re = -32'sd12539; im = -32'sd30273; end
        32'd81: begin re = -32'sd13278; im = -32'sd29956; end
        32'd82: begin re = -32'sd14010; im = -32'sd29621; end
        32'd83: begin re = -32'sd14732; im = -32'sd29269; end
        32'd84: begin re = -32'sd15446; im = -32'sd28898; end
        32'd85: begin re = -32'sd16151; im = -32'sd28511; end
        32'd86: begin re = -32'sd16846; im = -32'sd28106; end
        32'd87: begin re = -32'sd17530; im = -32'sd27684; end
        32'd88: begin re = -32'sd18204; im = -32'sd27245; end
        32'd89: begin re = -32'sd18868; im = -32'sd26790; end
        32'd90: begin re = -32'sd19519; im = -32'sd26319; end
        32'd91: begin re = -32'sd20159; im = -32'sd25832; end
        32'd92: begin re = -32'sd20787; im = -32'sd25330; end
        32'd93: begin re = -32'sd21403; im = -32'sd24812; end
        32'd94: begin re = -32'sd22005; im = -32'sd24279; end
        32'd95: begin re = -32'sd22594; im = -32'sd23732; end
        32'd96: begin re = -32'sd23170; im = -32'sd23170; end
        32'd97: begin re = -32'sd23732; im = -32'sd22594; end
        32'd98: begin re = -32'sd24279; im = -32'sd22005; end
        32'd99: begin re = -32'sd24812; im = -32'sd21403; end
        32'd100: begin re = -32'sd25330; im = -32'sd20787; end
        32'd101: begin re = -32'sd25832; im = -32'sd20159; end
        32'd102: begin re = -32'sd26319; im = -32'sd19519; end
        32'd103: begin re = -32'sd26790; im = -32'sd18868; end
        32'd104: begin re = -32'sd27245; im = -32'sd18204; end
        32'd105: begin re = -32'sd27684; im = -32'sd17530; end
        32'd106: begin re = -32'sd28106; im = -32'sd16846; end
        32'd107: begin re = -32'sd28511; im = -32'sd16151; end
        32'd108: begin re = -32'sd28898; im = -32'sd15446; end
        32'd109: begin re = -32'sd29269; im = -32'sd14732; end
        32'd110: begin re = -32'sd29621; im = -32'sd14010; end
        32'd111: begin re = -32'sd29956; im = -32'sd13278; end
        32'd112: begin re = -32'sd30273; im = -32'sd12539; end
        32'd113: begin re = -32'sd30572; im = -32'sd11793; end
        32'd114: begin re = -32'sd30852; im = -32'sd11039; end
        32'd115: begin re = -32'sd31114; im = -32'sd10278; end
        32'd116: begin re = -32'sd31357; im = -32'sd9512; end
        32'd117: begin re = -32'sd31581; im = -32'sd8739; end
        32'd118: begin re = -32'sd31785; im = -32'sd7961; end
        32'd119: begin re = -32'sd31971; im = -32'sd7179; end
        32'd120: begin re = -32'sd32138; im = -32'sd6392; end
        32'd121: begin re = -32'sd32285; im = -32'sd5602; end
        32'd122: begin re = -32'sd32413; im = -32'sd4808; end
        32'd123: begin re = -32'sd32521; im = -32'sd4011; end
        32'd124: begin re = -32'sd32610; im = -32'sd3211; end
        32'd125: begin re = -32'sd32679; im = -32'sd2410; end
        32'd126: begin re = -32'sd32728; im = -32'sd1607; end
        32'd127: begin re = -32'sd32758; im = -32'sd804; end

        default: begin
          re = 32'sd0;
          im = 32'sd0;
        end
      endcase
    end
  endtask

endmodule