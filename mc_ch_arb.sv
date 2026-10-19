module mc_ch_arb (
    input  logic        dfi_clk,
    input  logic        dfi_reset_n,

    input  logic        row_valid_pc0,
    input  logic        row_refresh_pc0,
    input  logic [2:0]  row_cmd_pc0,
    input  logic [1:0]  row_bg_pc0,
    input  logic [1:0]  row_ba_pc0,
    input  logic [13:0] row_addr_pc0,
    input  logic        row_valid_pc1,
    input  logic        row_refresh_pc1,
    input  logic [2:0]  row_cmd_pc1,
    input  logic [1:0]  row_bg_pc1,
    input  logic [1:0]  row_ba_pc1,
    input  logic [13:0] row_addr_pc1,
    output logic [1:0]  row_grant,

    input  logic        col_valid_pc0,
    input  logic [1:0]  col_cmd_pc0,
    input  logic [1:0]  col_bg_pc0,
    input  logic [1:0]  col_ba_pc0,
    input  logic [4:0]  col_addr_pc0,
    input  logic        col_valid_pc1,
    input  logic [1:0]  col_cmd_pc1,
    input  logic [1:0]  col_bg_pc1,
    input  logic [1:0]  col_ba_pc1,
    input  logic [4:0]  col_addr_pc1,
    output logic [1:0]  col_grant,

    input  logic [31:0] wrdata_pc0,
    input  logic [3:0]  wrdata_mask_pc0,
    input  logic        wrdata_en_pc0,
    input  logic [31:0] wrdata_pc1,
    input  logic [3:0]  wrdata_mask_pc1,
    input  logic        wrdata_en_pc1,
    output logic [63:0] dfi_wrdata,
    output logic [7:0]  dfi_wrdata_mask,
    output logic [1:0]  dfi_wrdata_en,

    input  logic [63:0] dfi_rddata,
    input  logic [1:0]  dfi_rddata_valid,
    input  logic        rddata_en_pc0,
    input  logic        rddata_en_pc1,
    output logic [1:0]  dfi_rddata_en,
    output logic [31:0] rddata_pc0,
    output logic [31:0] rddata_pc1,
    output logic [1:0]  rddata_valid,

    output logic        dfi_row_val,
    output logic [21:0] dfi_row,
    output logic        dfi_col_val,
    output logic [11:0] dfi_col
);

    logic [2:0]  selected_row_cmd;
    logic [1:0]  selected_row_bg;
    logic [1:0]  selected_row_ba;
    logic [13:0] selected_row_addr;

    logic [1:0]  selected_col_cmd;
    logic [1:0]  selected_col_bg;
    logic [1:0]  selected_col_ba;
    logic [4:0]  selected_col_addr;

    logic [63:0] combined_wrdata;
    logic [7:0]  combined_wrdata_mask;
    logic [1:0]  combined_wrdata_en;
    logic [1:0]  combined_rddata_en;

    mc_arbiter row_bus_arbiter (
        .clk              (dfi_clk),
        .reset_n          (dfi_reset_n),
        .candidate_valid  ({row_valid_pc1, row_valid_pc0}),
        .refresh_pending  ({row_refresh_pc1, row_refresh_pc0}),
        .grant            (row_grant)
    );

    mc_arbiter col_bus_arbiter (
        .clk              (dfi_clk),
        .reset_n          (dfi_reset_n),
        .candidate_valid  ({col_valid_pc1, col_valid_pc0}),
        .refresh_pending  (2'b00),
        .grant            (col_grant)
    );

    always_comb begin
        selected_row_cmd     = '0;
        selected_row_bg      = '0;
        selected_row_ba      = '0;
        selected_row_addr    = '0;

        if (row_grant[0]) begin
            selected_row_cmd  = row_cmd_pc0;
            selected_row_bg   = row_bg_pc0;
            selected_row_ba   = row_ba_pc0;
            selected_row_addr = row_addr_pc0;
        end else if (row_grant[1]) begin
            selected_row_cmd  = row_cmd_pc1;
            selected_row_bg   = row_bg_pc1;
            selected_row_ba   = row_ba_pc1;
            selected_row_addr = row_addr_pc1;
        end

        selected_col_cmd     = '0;
        selected_col_bg      = '0;
        selected_col_ba      = '0;
        selected_col_addr    = '0;

        if (col_grant[0]) begin
            selected_col_cmd  = col_cmd_pc0;
            selected_col_bg   = col_bg_pc0;
            selected_col_ba   = col_ba_pc0;
            selected_col_addr = col_addr_pc0;
        end else if (col_grant[1]) begin
            selected_col_cmd  = col_cmd_pc1;
            selected_col_bg   = col_bg_pc1;
            selected_col_ba   = col_ba_pc1;
            selected_col_addr = col_addr_pc1;
        end
    end

    assign combined_wrdata      = {wrdata_pc1, wrdata_pc0};
    assign combined_wrdata_mask = {wrdata_mask_pc1, wrdata_mask_pc0};
    assign combined_wrdata_en   = {wrdata_en_pc1, wrdata_en_pc0};
    assign combined_rddata_en   = {rddata_en_pc1, rddata_en_pc0};

    mc_dfi_fmt dfi_formatter (
        .dfi_clk          (dfi_clk),
        .dfi_reset_n      (dfi_reset_n),

        .row_valid        (|row_grant),
        .row_pc_sel       (row_grant[1]),
        .row_cmd          (selected_row_cmd),
        .row_bg           (selected_row_bg),
        .row_ba           (selected_row_ba),
        .row_addr         (selected_row_addr),
        .dfi_row_val      (dfi_row_val),
        .dfi_row          (dfi_row),

        .col_valid        (|col_grant),
        .col_pc_sel       (col_grant[1]),
        .col_cmd          (selected_col_cmd),
        .col_bg           (selected_col_bg),
        .col_ba           (selected_col_ba),
        .col_addr         (selected_col_addr),
        .dfi_col_val      (dfi_col_val),
        .dfi_col          (dfi_col),

        .wrdata           (combined_wrdata),
        .wrdata_mask      (combined_wrdata_mask),
        .wrdata_en        (combined_wrdata_en),
        .dfi_wrdata       (dfi_wrdata),
        .dfi_wrdata_mask  (dfi_wrdata_mask),
        .dfi_wrdata_en    (dfi_wrdata_en),

        .dfi_rddata       (dfi_rddata),
        .dfi_rddata_valid (dfi_rddata_valid),
        .rddata_en        (combined_rddata_en),
        .dfi_rddata_en    (dfi_rddata_en),
        .rddata_pc0       (rddata_pc0),
        .rddata_pc1       (rddata_pc1),
        .rddata_valid     (rddata_valid)
    );

endmodule
