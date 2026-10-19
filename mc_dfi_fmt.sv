// One-cycle DFI boundary stage; upstream supplies PHY-latency-aligned data enables.
module mc_dfi_fmt (
    input  logic        dfi_clk,
    input  logic        dfi_reset_n,

    input  logic        row_valid,
    input  logic        row_pc_sel,
    input  logic [2:0]  row_cmd,
    input  logic [1:0]  row_bg,
    input  logic [1:0]  row_ba,
    input  logic [13:0] row_addr,
    output logic        dfi_row_val,
    output logic [21:0] dfi_row,

    input  logic        col_valid,
    input  logic        col_pc_sel,
    input  logic [1:0]  col_cmd,
    input  logic [1:0]  col_bg,
    input  logic [1:0]  col_ba,
    input  logic [4:0]  col_addr,
    output logic        dfi_col_val,
    output logic [11:0] dfi_col,

    input  logic [63:0] wrdata,
    input  logic [7:0]  wrdata_mask,
    input  logic [1:0]  wrdata_en,
    output logic [63:0] dfi_wrdata,
    output logic [7:0]  dfi_wrdata_mask,
    output logic [1:0]  dfi_wrdata_en,

    input  logic [63:0] dfi_rddata,
    input  logic [1:0]  dfi_rddata_valid,
    input  logic [1:0]  rddata_en,
    output logic [1:0]  dfi_rddata_en,
    output logic [31:0] rddata_pc0,
    output logic [31:0] rddata_pc1,
    output logic [1:0]  rddata_valid
);

    always_ff @(posedge dfi_clk or negedge dfi_reset_n) begin
        if (!dfi_reset_n) begin
            dfi_row_val      <= 1'b0;
            dfi_row          <= '0;
            dfi_col_val      <= 1'b0;
            dfi_col          <= '0;
            dfi_wrdata       <= '0;
            dfi_wrdata_mask  <= '0;
            dfi_wrdata_en    <= '0;
            rddata_pc0       <= '0;
            rddata_pc1       <= '0;
            dfi_rddata_en    <= '0;
            rddata_valid     <= '0;
        end else begin
            dfi_row_val      <= row_valid;
            dfi_row          <= {row_pc_sel, row_cmd, row_bg, row_ba, row_addr};
            dfi_col_val      <= col_valid;
            dfi_col          <= {col_pc_sel, col_cmd, col_bg, col_ba, col_addr};

            dfi_wrdata       <= wrdata;
            dfi_wrdata_mask  <= wrdata_mask;
            dfi_wrdata_en    <= wrdata_en;

            rddata_pc0       <= dfi_rddata[31:0];
            rddata_pc1       <= dfi_rddata[63:32];
            dfi_rddata_en    <= rddata_en;
            rddata_valid     <= dfi_rddata_valid;
        end
    end

endmodule
