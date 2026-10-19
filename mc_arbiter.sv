module mc_arbiter #(
    parameter int CREDIT_CTR_WIDTH = 8
) (
    input  logic                       clk,
    input  logic                       reset_n,
    input  logic [1:0]                 candidate_valid,
    input  logic [1:0]                 refresh_pending,
    output logic [1:0]                 grant
);

    localparam logic [CREDIT_CTR_WIDTH-1:0] CREDIT_MAX = {CREDIT_CTR_WIDTH{1'b1}};

    logic [CREDIT_CTR_WIDTH-1:0] credit_pc0;
    logic [CREDIT_CTR_WIDTH-1:0] credit_pc1;

    always_comb begin
        grant = 2'b00;

        case (candidate_valid)
            2'b01: grant = 2'b01;
            2'b10: grant = 2'b10;
            2'b11: begin
                if (refresh_pending[0] || refresh_pending[1]) begin
                    if (refresh_pending[0])
                        grant = 2'b01;
                    else
                        grant = 2'b10;
                end else if (credit_pc1 > credit_pc0) begin
                    grant = 2'b10;
                end else begin
                    grant = 2'b01;
                end
            end
            default: grant = 2'b00;
        endcase
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            credit_pc0 <= '0;
            credit_pc1 <= '0;
        end else begin
            if (grant[0])
                credit_pc0 <= '0;
            else if (candidate_valid[0] && grant[1] && credit_pc0 != CREDIT_MAX)
                credit_pc0 <= credit_pc0 + 1'b1;

            if (grant[1])
                credit_pc1 <= '0;
            else if (candidate_valid[1] && grant[0] && credit_pc1 != CREDIT_MAX)
                credit_pc1 <= credit_pc1 + 1'b1;
        end
    end

endmodule
