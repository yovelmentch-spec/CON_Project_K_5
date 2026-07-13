// ============================================================================
// fft_engine.sv — BRAM version
//
// Changes vs. the single-engine intermediate version:
//  1. buf_re/buf_im are now written in a dedicated always_ff block with NO
//     reset and a REGISTERED read (simple dual-port template), so Quartus
//     infers M9K block RAM instead of 16K flip-flops + giant muxes.
//  2. One write port + one read port per array. The butterfly is therefore
//     serialized over 5 cycles:
//        S_RD_EVEN  - issue read of buf[even]
//        S_RD_ODD   - issue read of buf[odd], capture u = buf[even]
//        S_MUL      - t = v * W   (v = buf[odd] on the RAM output register)
//        S_WR_EVEN  - write buf[even] = (u + t) >> 1
//        S_WR_ODD   - write buf[odd]  = (u - t) >> 1
//  3. The twiddle ROM (synchronous, block-RAM) rides in parallel: tw_addr is
//     stable from S_RD_EVEN, so the registered ROM output is valid by S_MUL.
//  4. READ-PORT LATENCY: read_re/read_im are valid ONE CYCLE after read_addr
//     is applied (registered RAM output). The top module pipelines its
//     save/mul loops accordingly.
//
// Protocol (while busy == 0):
//  - load:  drive load_valid/load_addr/load_re/load_im, one element per cycle
//           (natural order 0..n-1; bit-reversal is applied internally).
//  - start: pulse start (inverse sampled at start).
//  - read:  drive read_addr; data appears on read_re/read_im next cycle.
// ============================================================================

module fft_engine #(
  parameter int MAX_N      = 256,
  parameter int DATA_WIDTH = 32
)(
  input  logic clk,
  input  logic rst_n,

  input  logic        start,
  input  logic        inverse,
  input  logic [31:0] n,

  input  logic                         load_valid,
  input  logic [31:0]                  load_addr,
  input  logic signed [DATA_WIDTH-1:0] load_re,
  input  logic signed [DATA_WIDTH-1:0] load_im,

  input  logic [31:0]                  read_addr,
  output logic signed [DATA_WIDTH-1:0] read_re,   // valid 1 cycle after read_addr
  output logic signed [DATA_WIDTH-1:0] read_im,   // valid 1 cycle after read_addr

  output logic busy,
  output logic done
);

  localparam int AW = $clog2(MAX_N);

  typedef enum logic [3:0] {
    S_IDLE,
    S_STAGE_INIT,
    S_RD_EVEN,
    S_RD_ODD,
    S_MUL1,      // pipeline stage 1: register the raw 32x32 products (DSP output)
    S_MUL2,      // pipeline stage 2: round, shift and combine (cheap adders)
    S_WR_EVEN,
    S_WR_ODD,
    S_DONE
  } state_t;

  state_t state;

  logic inverse_reg;

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

  // pipeline registers for the raw 32x32 products (DSP output registered)
  logic signed [2*DATA_WIDTH-1:0] pr_rr;   // v_re * w_re
  logic signed [2*DATA_WIDTH-1:0] pr_ii;   // v_im * w_im
  logic signed [2*DATA_WIDTH-1:0] pr_ri;   // v_re * w_im
  logic signed [2*DATA_WIDTH-1:0] pr_ir;   // v_im * w_re

  logic signed [DATA_WIDTH:0] even_re_wide;
  logic signed [DATA_WIDTH:0] even_im_wide;
  logic signed [DATA_WIDTH:0] odd_re_wide;
  logic signed [DATA_WIDTH:0] odd_im_wide;

  assign even_idx = block_base + j_idx;
  assign odd_idx  = block_base + j_idx + half_len;

  // --------------------------------------------------------------------
  // Working buffer as inferred block RAM (simple dual port):
  // one synchronous write port, one synchronous (registered) read port.
  // NO reset, NO initialization loop — both would block RAM inference.
  // --------------------------------------------------------------------
  (* ramstyle = "M9K" *) logic signed [DATA_WIDTH-1:0] buf_re [0:MAX_N-1];
  (* ramstyle = "M9K" *) logic signed [DATA_WIDTH-1:0] buf_im [0:MAX_N-1];

  logic                         ram_we;
  logic [AW-1:0]                ram_waddr;
  logic [AW-1:0]                ram_raddr;
  logic signed [DATA_WIDTH-1:0] ram_wre;
  logic signed [DATA_WIDTH-1:0] ram_wim;
  logic signed [DATA_WIDTH-1:0] ram_rre;
  logic signed [DATA_WIDTH-1:0] ram_rim;

  always_ff @(posedge clk) begin
    if (ram_we) begin
      buf_re[ram_waddr] <= ram_wre;
      buf_im[ram_waddr] <= ram_wim;
    end
    ram_rre <= buf_re[ram_raddr];
    ram_rim <= buf_im[ram_raddr];
  end

  assign read_re = ram_rre;
  assign read_im = ram_rim;

  // Load-time bit reversal.
  // log2n depends only on n (a host register, constant for a whole run), so
  // it is computed once and REGISTERED — keeping the long n->log2 cone off
  // the RAM write-address path. bit_reverse_var is now a fixed-width wire
  // permutation plus a single barrel shift (shallow), instead of a 32-deep
  // loop. Both changes are bit-exact to the original functions.
  logic [31:0] log2n_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) log2n_r <= 32'd0;
    else        log2n_r <= calc_log2(n);
  end

  logic [31:0] load_target;
  assign load_target = bit_reverse_var(load_addr, log2n_r);

  // Butterfly write values (combinational, from registered operands)
  always_comb begin
    even_re_wide = ($signed({u_re_reg[DATA_WIDTH-1], u_re_reg}) +
                    $signed({t_re_reg[DATA_WIDTH-1], t_re_reg})) >>> 1;

    even_im_wide = ($signed({u_im_reg[DATA_WIDTH-1], u_im_reg}) +
                    $signed({t_im_reg[DATA_WIDTH-1], t_im_reg})) >>> 1;

    odd_re_wide  = ($signed({u_re_reg[DATA_WIDTH-1], u_re_reg}) -
                    $signed({t_re_reg[DATA_WIDTH-1], t_re_reg})) >>> 1;

    odd_im_wide  = ($signed({u_im_reg[DATA_WIDTH-1], u_im_reg}) -
                    $signed({t_im_reg[DATA_WIDTH-1], t_im_reg})) >>> 1;
  end

  // RAM port muxing
  always_comb begin
    ram_we    = 1'b0;
    ram_waddr = load_target[AW-1:0];
    ram_wre   = load_re;
    ram_wim   = load_im;
    ram_raddr = read_addr[AW-1:0];

    case (state)
      S_IDLE: begin
        ram_we = load_valid && (load_target < MAX_N);
      end

      S_RD_EVEN: begin
        ram_raddr = even_idx[AW-1:0];
      end

      S_RD_ODD: begin
        ram_raddr = odd_idx[AW-1:0];
      end

      S_WR_EVEN: begin
        ram_we    = 1'b1;
        ram_waddr = even_idx[AW-1:0];
        ram_wre   = even_re_wide[DATA_WIDTH-1:0];
        ram_wim   = even_im_wide[DATA_WIDTH-1:0];
      end

      S_WR_ODD: begin
        ram_we    = 1'b1;
        ram_waddr = odd_idx[AW-1:0];
        ram_wre   = odd_re_wide[DATA_WIDTH-1:0];
        ram_wim   = odd_im_wide[DATA_WIDTH-1:0];
      end

      default: ;
    endcase
  end

  // --------------------------------------------------------------------
  // Twiddle ROM (synchronous block-RAM ROM, one-cycle latency).
  // tw_addr is stable from S_RD_EVEN until the end of the butterfly, so
  // tw_re_q/tw_im_q are guaranteed valid in S_MUL.
  // --------------------------------------------------------------------
  logic [6:0]  tw_addr;
  logic [31:0] tw_k;

  always_comb begin
    case (stage_len)
      32'd2:   tw_k = j_idx << 7;
      32'd4:   tw_k = j_idx << 6;
      32'd8:   tw_k = j_idx << 5;
      32'd16:  tw_k = j_idx << 4;
      32'd32:  tw_k = j_idx << 3;
      32'd64:  tw_k = j_idx << 2;
      32'd128: tw_k = j_idx << 1;
      32'd256: tw_k = j_idx;
      default: tw_k = 32'd0;
    endcase
  end

  assign tw_addr = tw_k[6:0];

  (* ramstyle = "M9K" *) logic signed [17:0] tw_rom_re [0:127];
  (* ramstyle = "M9K" *) logic signed [17:0] tw_rom_im [0:127];

  initial begin
    tw_rom_re[0] = 18'sd32768;  tw_rom_im[0] = 18'sd0;
    tw_rom_re[1] = 18'sd32758;  tw_rom_im[1] = -18'sd804;
    tw_rom_re[2] = 18'sd32728;  tw_rom_im[2] = -18'sd1607;
    tw_rom_re[3] = 18'sd32679;  tw_rom_im[3] = -18'sd2410;
    tw_rom_re[4] = 18'sd32610;  tw_rom_im[4] = -18'sd3211;
    tw_rom_re[5] = 18'sd32521;  tw_rom_im[5] = -18'sd4011;
    tw_rom_re[6] = 18'sd32413;  tw_rom_im[6] = -18'sd4808;
    tw_rom_re[7] = 18'sd32285;  tw_rom_im[7] = -18'sd5602;
    tw_rom_re[8] = 18'sd32138;  tw_rom_im[8] = -18'sd6392;
    tw_rom_re[9] = 18'sd31971;  tw_rom_im[9] = -18'sd7179;
    tw_rom_re[10] = 18'sd31785;  tw_rom_im[10] = -18'sd7961;
    tw_rom_re[11] = 18'sd31581;  tw_rom_im[11] = -18'sd8739;
    tw_rom_re[12] = 18'sd31357;  tw_rom_im[12] = -18'sd9512;
    tw_rom_re[13] = 18'sd31114;  tw_rom_im[13] = -18'sd10278;
    tw_rom_re[14] = 18'sd30852;  tw_rom_im[14] = -18'sd11039;
    tw_rom_re[15] = 18'sd30572;  tw_rom_im[15] = -18'sd11793;
    tw_rom_re[16] = 18'sd30273;  tw_rom_im[16] = -18'sd12539;
    tw_rom_re[17] = 18'sd29956;  tw_rom_im[17] = -18'sd13278;
    tw_rom_re[18] = 18'sd29621;  tw_rom_im[18] = -18'sd14010;
    tw_rom_re[19] = 18'sd29269;  tw_rom_im[19] = -18'sd14732;
    tw_rom_re[20] = 18'sd28898;  tw_rom_im[20] = -18'sd15446;
    tw_rom_re[21] = 18'sd28511;  tw_rom_im[21] = -18'sd16151;
    tw_rom_re[22] = 18'sd28106;  tw_rom_im[22] = -18'sd16846;
    tw_rom_re[23] = 18'sd27684;  tw_rom_im[23] = -18'sd17530;
    tw_rom_re[24] = 18'sd27245;  tw_rom_im[24] = -18'sd18204;
    tw_rom_re[25] = 18'sd26790;  tw_rom_im[25] = -18'sd18868;
    tw_rom_re[26] = 18'sd26319;  tw_rom_im[26] = -18'sd19519;
    tw_rom_re[27] = 18'sd25832;  tw_rom_im[27] = -18'sd20159;
    tw_rom_re[28] = 18'sd25330;  tw_rom_im[28] = -18'sd20787;
    tw_rom_re[29] = 18'sd24812;  tw_rom_im[29] = -18'sd21403;
    tw_rom_re[30] = 18'sd24279;  tw_rom_im[30] = -18'sd22005;
    tw_rom_re[31] = 18'sd23732;  tw_rom_im[31] = -18'sd22594;
    tw_rom_re[32] = 18'sd23170;  tw_rom_im[32] = -18'sd23170;
    tw_rom_re[33] = 18'sd22594;  tw_rom_im[33] = -18'sd23732;
    tw_rom_re[34] = 18'sd22005;  tw_rom_im[34] = -18'sd24279;
    tw_rom_re[35] = 18'sd21403;  tw_rom_im[35] = -18'sd24812;
    tw_rom_re[36] = 18'sd20787;  tw_rom_im[36] = -18'sd25330;
    tw_rom_re[37] = 18'sd20159;  tw_rom_im[37] = -18'sd25832;
    tw_rom_re[38] = 18'sd19519;  tw_rom_im[38] = -18'sd26319;
    tw_rom_re[39] = 18'sd18868;  tw_rom_im[39] = -18'sd26790;
    tw_rom_re[40] = 18'sd18204;  tw_rom_im[40] = -18'sd27245;
    tw_rom_re[41] = 18'sd17530;  tw_rom_im[41] = -18'sd27684;
    tw_rom_re[42] = 18'sd16846;  tw_rom_im[42] = -18'sd28106;
    tw_rom_re[43] = 18'sd16151;  tw_rom_im[43] = -18'sd28511;
    tw_rom_re[44] = 18'sd15446;  tw_rom_im[44] = -18'sd28898;
    tw_rom_re[45] = 18'sd14732;  tw_rom_im[45] = -18'sd29269;
    tw_rom_re[46] = 18'sd14010;  tw_rom_im[46] = -18'sd29621;
    tw_rom_re[47] = 18'sd13278;  tw_rom_im[47] = -18'sd29956;
    tw_rom_re[48] = 18'sd12539;  tw_rom_im[48] = -18'sd30273;
    tw_rom_re[49] = 18'sd11793;  tw_rom_im[49] = -18'sd30572;
    tw_rom_re[50] = 18'sd11039;  tw_rom_im[50] = -18'sd30852;
    tw_rom_re[51] = 18'sd10278;  tw_rom_im[51] = -18'sd31114;
    tw_rom_re[52] = 18'sd9512;  tw_rom_im[52] = -18'sd31357;
    tw_rom_re[53] = 18'sd8739;  tw_rom_im[53] = -18'sd31581;
    tw_rom_re[54] = 18'sd7961;  tw_rom_im[54] = -18'sd31785;
    tw_rom_re[55] = 18'sd7179;  tw_rom_im[55] = -18'sd31971;
    tw_rom_re[56] = 18'sd6392;  tw_rom_im[56] = -18'sd32138;
    tw_rom_re[57] = 18'sd5602;  tw_rom_im[57] = -18'sd32285;
    tw_rom_re[58] = 18'sd4808;  tw_rom_im[58] = -18'sd32413;
    tw_rom_re[59] = 18'sd4011;  tw_rom_im[59] = -18'sd32521;
    tw_rom_re[60] = 18'sd3211;  tw_rom_im[60] = -18'sd32610;
    tw_rom_re[61] = 18'sd2410;  tw_rom_im[61] = -18'sd32679;
    tw_rom_re[62] = 18'sd1607;  tw_rom_im[62] = -18'sd32728;
    tw_rom_re[63] = 18'sd804;  tw_rom_im[63] = -18'sd32758;
    tw_rom_re[64] = 18'sd0;  tw_rom_im[64] = -18'sd32768;
    tw_rom_re[65] = -18'sd804;  tw_rom_im[65] = -18'sd32758;
    tw_rom_re[66] = -18'sd1607;  tw_rom_im[66] = -18'sd32728;
    tw_rom_re[67] = -18'sd2410;  tw_rom_im[67] = -18'sd32679;
    tw_rom_re[68] = -18'sd3211;  tw_rom_im[68] = -18'sd32610;
    tw_rom_re[69] = -18'sd4011;  tw_rom_im[69] = -18'sd32521;
    tw_rom_re[70] = -18'sd4808;  tw_rom_im[70] = -18'sd32413;
    tw_rom_re[71] = -18'sd5602;  tw_rom_im[71] = -18'sd32285;
    tw_rom_re[72] = -18'sd6392;  tw_rom_im[72] = -18'sd32138;
    tw_rom_re[73] = -18'sd7179;  tw_rom_im[73] = -18'sd31971;
    tw_rom_re[74] = -18'sd7961;  tw_rom_im[74] = -18'sd31785;
    tw_rom_re[75] = -18'sd8739;  tw_rom_im[75] = -18'sd31581;
    tw_rom_re[76] = -18'sd9512;  tw_rom_im[76] = -18'sd31357;
    tw_rom_re[77] = -18'sd10278;  tw_rom_im[77] = -18'sd31114;
    tw_rom_re[78] = -18'sd11039;  tw_rom_im[78] = -18'sd30852;
    tw_rom_re[79] = -18'sd11793;  tw_rom_im[79] = -18'sd30572;
    tw_rom_re[80] = -18'sd12539;  tw_rom_im[80] = -18'sd30273;
    tw_rom_re[81] = -18'sd13278;  tw_rom_im[81] = -18'sd29956;
    tw_rom_re[82] = -18'sd14010;  tw_rom_im[82] = -18'sd29621;
    tw_rom_re[83] = -18'sd14732;  tw_rom_im[83] = -18'sd29269;
    tw_rom_re[84] = -18'sd15446;  tw_rom_im[84] = -18'sd28898;
    tw_rom_re[85] = -18'sd16151;  tw_rom_im[85] = -18'sd28511;
    tw_rom_re[86] = -18'sd16846;  tw_rom_im[86] = -18'sd28106;
    tw_rom_re[87] = -18'sd17530;  tw_rom_im[87] = -18'sd27684;
    tw_rom_re[88] = -18'sd18204;  tw_rom_im[88] = -18'sd27245;
    tw_rom_re[89] = -18'sd18868;  tw_rom_im[89] = -18'sd26790;
    tw_rom_re[90] = -18'sd19519;  tw_rom_im[90] = -18'sd26319;
    tw_rom_re[91] = -18'sd20159;  tw_rom_im[91] = -18'sd25832;
    tw_rom_re[92] = -18'sd20787;  tw_rom_im[92] = -18'sd25330;
    tw_rom_re[93] = -18'sd21403;  tw_rom_im[93] = -18'sd24812;
    tw_rom_re[94] = -18'sd22005;  tw_rom_im[94] = -18'sd24279;
    tw_rom_re[95] = -18'sd22594;  tw_rom_im[95] = -18'sd23732;
    tw_rom_re[96] = -18'sd23170;  tw_rom_im[96] = -18'sd23170;
    tw_rom_re[97] = -18'sd23732;  tw_rom_im[97] = -18'sd22594;
    tw_rom_re[98] = -18'sd24279;  tw_rom_im[98] = -18'sd22005;
    tw_rom_re[99] = -18'sd24812;  tw_rom_im[99] = -18'sd21403;
    tw_rom_re[100] = -18'sd25330;  tw_rom_im[100] = -18'sd20787;
    tw_rom_re[101] = -18'sd25832;  tw_rom_im[101] = -18'sd20159;
    tw_rom_re[102] = -18'sd26319;  tw_rom_im[102] = -18'sd19519;
    tw_rom_re[103] = -18'sd26790;  tw_rom_im[103] = -18'sd18868;
    tw_rom_re[104] = -18'sd27245;  tw_rom_im[104] = -18'sd18204;
    tw_rom_re[105] = -18'sd27684;  tw_rom_im[105] = -18'sd17530;
    tw_rom_re[106] = -18'sd28106;  tw_rom_im[106] = -18'sd16846;
    tw_rom_re[107] = -18'sd28511;  tw_rom_im[107] = -18'sd16151;
    tw_rom_re[108] = -18'sd28898;  tw_rom_im[108] = -18'sd15446;
    tw_rom_re[109] = -18'sd29269;  tw_rom_im[109] = -18'sd14732;
    tw_rom_re[110] = -18'sd29621;  tw_rom_im[110] = -18'sd14010;
    tw_rom_re[111] = -18'sd29956;  tw_rom_im[111] = -18'sd13278;
    tw_rom_re[112] = -18'sd30273;  tw_rom_im[112] = -18'sd12539;
    tw_rom_re[113] = -18'sd30572;  tw_rom_im[113] = -18'sd11793;
    tw_rom_re[114] = -18'sd30852;  tw_rom_im[114] = -18'sd11039;
    tw_rom_re[115] = -18'sd31114;  tw_rom_im[115] = -18'sd10278;
    tw_rom_re[116] = -18'sd31357;  tw_rom_im[116] = -18'sd9512;
    tw_rom_re[117] = -18'sd31581;  tw_rom_im[117] = -18'sd8739;
    tw_rom_re[118] = -18'sd31785;  tw_rom_im[118] = -18'sd7961;
    tw_rom_re[119] = -18'sd31971;  tw_rom_im[119] = -18'sd7179;
    tw_rom_re[120] = -18'sd32138;  tw_rom_im[120] = -18'sd6392;
    tw_rom_re[121] = -18'sd32285;  tw_rom_im[121] = -18'sd5602;
    tw_rom_re[122] = -18'sd32413;  tw_rom_im[122] = -18'sd4808;
    tw_rom_re[123] = -18'sd32521;  tw_rom_im[123] = -18'sd4011;
    tw_rom_re[124] = -18'sd32610;  tw_rom_im[124] = -18'sd3211;
    tw_rom_re[125] = -18'sd32679;  tw_rom_im[125] = -18'sd2410;
    tw_rom_re[126] = -18'sd32728;  tw_rom_im[126] = -18'sd1607;
    tw_rom_re[127] = -18'sd32758;  tw_rom_im[127] = -18'sd804;
  end

  logic signed [17:0] tw_re_q;
  logic signed [17:0] tw_im_q;

  always_ff @(posedge clk) begin
    tw_re_q <= tw_rom_re[tw_addr];
    tw_im_q <= tw_rom_im[tw_addr];
  end

  // Sign-extended twiddle, conjugated for the inverse transform
  logic signed [DATA_WIDTH-1:0] w_re_ext;
  logic signed [DATA_WIDTH-1:0] w_im_ext;
  logic signed [17:0]           tw_im_sel;

  always_comb begin
    tw_im_sel = inverse_reg ? -tw_im_q : tw_im_q;
    w_re_ext  = {{(DATA_WIDTH-18){tw_re_q[17]}},   tw_re_q};
    w_im_ext  = {{(DATA_WIDTH-18){tw_im_sel[17]}}, tw_im_sel};
  end

  // --------------------------------------------------------------------
  // Main FSM (control registers only — the data lives in the RAM)
  // --------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      busy        <= 1'b0;
      done        <= 1'b0;
      inverse_reg <= 1'b0;

      stage_len  <= 32'd0;
      half_len   <= 32'd0;
      block_base <= 32'd0;
      j_idx      <= 32'd0;

      u_re_reg <= '0;
      u_im_reg <= '0;
      t_re_reg <= '0;
      t_im_reg <= '0;

      pr_rr <= '0;
      pr_ii <= '0;
      pr_ri <= '0;
      pr_ir <= '0;
    end
    else begin
      done <= 1'b0;

      case (state)

        S_IDLE: begin
          busy <= 1'b0;

          if (start) begin
            busy        <= 1'b1;
            inverse_reg <= inverse;
            state       <= S_STAGE_INIT;
          end
        end

        S_STAGE_INIT: begin
          stage_len  <= 32'd2;
          half_len   <= 32'd1;
          block_base <= 32'd0;
          j_idx      <= 32'd0;
          state      <= S_RD_EVEN;
        end

        // read of buf[even] issued combinationally this cycle
        S_RD_EVEN: begin
          state <= S_RD_ODD;
        end

        // ram_rre/ram_rim now hold buf[even]; read of buf[odd] issued
        S_RD_ODD: begin
          u_re_reg <= ram_rre;
          u_im_reg <= ram_rim;
          state    <= S_MUL1;
        end

        // Pipeline stage 1: ram_rre/ram_rim hold buf[odd] (= v) and the
        // twiddle ROM output is valid. Register the four raw 32x32 products
        // so the DSP output is captured before the round/combine adders.
        S_MUL1: begin
          pr_rr <= $signed(ram_rre) * $signed(w_re_ext);
          pr_ii <= $signed(ram_rim) * $signed(w_im_ext);
          pr_ri <= $signed(ram_rre) * $signed(w_im_ext);
          pr_ir <= $signed(ram_rim) * $signed(w_re_ext);
          state <= S_MUL2;
        end

        // Pipeline stage 2: round (+16384 >>15) and combine. Cheap adders only.
        S_MUL2: begin
          t_re_reg <= q15_round(pr_rr) - q15_round(pr_ii);
          t_im_reg <= q15_round(pr_ri) + q15_round(pr_ir);
          state    <= S_WR_EVEN;
        end

        // buf[even] <= (u+t)>>1 written combinationally this cycle
        S_WR_EVEN: begin
          state <= S_WR_ODD;
        end

        // buf[odd] <= (u-t)>>1 written; advance indices
        S_WR_ODD: begin
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
                state     <= S_RD_EVEN;
              end
            end
            else begin
              block_base <= block_base + stage_len;
              state      <= S_RD_EVEN;
            end
          end
          else begin
            j_idx <= j_idx + 32'd1;
            state <= S_RD_EVEN;
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

  // --------------------------------------------------------------------
  // Helper functions
  // --------------------------------------------------------------------
  // floor(log2(val)) as a priority encoder (MSB position). Shallow (~log
  // depth) instead of the original 32-iteration while loop. Bit-exact for
  // all val in [0, MAX_N] (this design supports N up to MAX_N = 256).
  function automatic logic [31:0] calc_log2(input logic [31:0] val);
    begin
      if      (val[AW])     calc_log2 = AW[31:0];        // val == MAX_N (256)
      else if (val[AW-1])   calc_log2 = AW[31:0] - 32'd1;
      else if (val[AW-2])   calc_log2 = AW[31:0] - 32'd2;
      else if (val[AW-3])   calc_log2 = AW[31:0] - 32'd3;
      else if (val[AW-4])   calc_log2 = AW[31:0] - 32'd4;
      else if (val[AW-5])   calc_log2 = AW[31:0] - 32'd5;
      else if (val[AW-6])   calc_log2 = AW[31:0] - 32'd6;
      else if (val[AW-7])   calc_log2 = AW[31:0] - 32'd7;
      else                  calc_log2 = 32'd0;
    end
  endfunction

  // Reverse the low `bits` bits of x. Implemented as a fixed-width wire
  // permutation of the low AW bits followed by a single barrel shift by
  // (AW - bits) — shallow, instead of the original 32-deep loop. Bit-exact
  // to the original for bits <= AW.
  function automatic logic [31:0] bit_reverse_var(
    input logic [31:0] x,
    input logic [31:0] bits
  );
    logic [AW-1:0] full;
    logic [AW-1:0] shifted;
    begin
      for (int k = 0; k < AW; k++) begin
        full[k] = x[AW-1-k];        // constant indices -> pure wires
      end
      shifted = full >> (AW[31:0] - bits);
      bit_reverse_var = {{(32-AW){1'b0}}, shifted};
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

  // Q15 rounding of an already-computed raw product (the multiply itself is
  // done and registered in S_MUL1). Bit-exact to q15_mul(a,b) for t = a*b.
  function automatic logic signed [DATA_WIDTH-1:0] q15_round(
    input logic signed [2*DATA_WIDTH-1:0] t
  );
    logic signed [2*DATA_WIDTH-1:0] tr;
    begin
      tr = t + 64'sd16384;
      q15_round = tr >>> 15;
    end
  endfunction

endmodule
