module divu_int #(
    parameter int WIDTH = 32
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,

    output reg              busy,
    output reg              done,
    output reg              valid,
    output reg              dbz,

    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,

    output reg  [WIDTH-1:0] val,
    output reg  [WIDTH-1:0] rem
);

    reg [WIDTH-1:0] b1;
    reg [WIDTH-1:0] quo, quo_next;
    reg [WIDTH:0]   acc, acc_next;
    reg [$clog2(WIDTH)-1:0] i;

    always_comb begin
        if (acc >= {1'b0, b1}) begin
            acc_next = acc - {1'b0, b1};
            {acc_next, quo_next} = {acc_next[WIDTH-1:0], quo, 1'b1};
        end
        else begin
            {acc_next, quo_next} = {acc, quo} << 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy  <= 1'b0;
            done  <= 1'b0;
            valid <= 1'b0;
            dbz   <= 1'b0;

            val   <= '0;
            rem   <= '0;

            b1    <= '0;
            quo   <= '0;
            acc   <= '0;
            i     <= '0;
        end
        else begin
            done <= 1'b0;

            if (start && !busy) begin
                valid <= 1'b0;
                i     <= '0;

                if (b == '0) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    valid <= 1'b0;
                    dbz   <= 1'b1;
                    val   <= '0;
                    rem   <= '0;
                end
                else begin
                    busy <= 1'b1;
                    dbz  <= 1'b0;
                    b1   <= b;

                    // Important: this matches the original algorithm structure
                    {acc, quo} <= {{WIDTH{1'b0}}, a, 1'b0};
                end
            end
            else if (busy) begin
                if (i == WIDTH - 1) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    valid <= 1'b1;
                    val   <= quo_next;
                    rem   <= acc_next[WIDTH:1];
                end
                else begin
                    i   <= i + 1'b1;
                    acc <= acc_next;
                    quo <= quo_next;
                end
            end
        end
    end

endmodule