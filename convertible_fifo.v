`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Group 13
// Engineer: 
// 
// Create Date:    18:52:44 03/05/2026 
// Design Name:    Network Processor Integration
// Module Name:    convertible_fifo 
// Project Name:   Lab 8
// Target Devices: FIFO
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////

module convertible_fifo #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 8,
    parameter PTR_WIDTH  = ADDR_WIDTH + 1   // head/tail 用 one-past-last 语义
)(
    input  wire                     clk,
    input  wire                     rst,

    // NetFPGA -> FIFO
    input  wire [DATA_WIDTH-1:0]    fifo_input_data,
    input  wire                     fifo_input_valid,
    input  wire                     fifo_input_last,  
    output wire                     fifo_input_ready,
    output wire                     fifo_full,

    // CPU 直接访问 FIFO SRAM
    input  wire                     cpu_sram_en,
    input  wire                     cpu_sram_we,
    input  wire [ADDR_WIDTH-1:0]    sram_addr_port,
    input  wire [DATA_WIDTH-1:0]    sram_data_in_port,
    output wire [DATA_WIDTH-1:0]    sram_data_out_port,
    output wire                     sram_addr_in_range,
    output wire                     cpu_sram_grant,

    // CPU 访问 head / tail register
    input  wire                     cpu_head_we,
    input  wire [PTR_WIDTH-1:0]     cpu_head_wdata,
    input  wire                     cpu_tail_we,
    input  wire [PTR_WIDTH-1:0]     cpu_tail_wdata,
    output wire [PTR_WIDTH-1:0]     head_addr_reg,
    output wire [PTR_WIDTH-1:0]     tail_addr_reg,


    // CPU 控制
    output reg                      packet_ready,   // 一个 packet 已经完整缓存，CPU 可处理
    input  wire                     cpu_start_send, // CPU 处理完成，开始向下游送

    
    // FIFO -> downstream
    output reg [DATA_WIDTH-1:0]    fifo_output_data,
    output reg                     fifo_output_valid,
    output reg                     fifo_output_last,
    input  wire                    fifo_output_ready,




    //==============================
    // status / debug
    //==============================
    output reg                      overflow_err,
    output reg                      CPU_access_tail_head_invalid,
    output reg                      illegal_cpu_addr_err,
    output wire [2:0]               state_dbg
);

    //============================================================
    // State encoding
    //============================================================
    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_RECV      = 3'd1;
    localparam [2:0] S_CPU       = 3'd2;
    localparam [2:0] S_SEND_ADDR = 3'd3;
    localparam [2:0] S_SEND_DATA = 3'd4;

    localparam [PTR_WIDTH-1:0] PTR_ZERO  = {PTR_WIDTH{1'b0}};
    localparam [PTR_WIDTH-1:0] PTR_ONE   = {{(PTR_WIDTH-1){1'b0}}, 1'b1};



    reg [2:0] state;



    // Head / Tail register
    reg [PTR_WIDTH-1:0] head_addr;
    reg [PTR_WIDTH-1:0] tail_addr;



    // BRAM Port A: NetFPGA input / CPU direct SRAM access
    reg  [DATA_WIDTH-1:0] bram_dina;
    reg  [ADDR_WIDTH-1:0] bram_addra;
    reg  [0:0]            bram_wea;  
    wire [DATA_WIDTH-1:0] bram_douta;

    // BRAM Port B: Head address -> downstream
    reg ; [DATA_WIDTH-1:0] bram_dinb;
    reg  [ADDR_WIDTH-1:0] bram_addrb;
    reg ; [0:0]            bram_web;
    wire [DATA_WIDTH-1:0] bram_doutb;




    //============================================================
    // Internal wires
    //============================================================
    wire rx_phase;
    wire mem_has_space;
    wire [PTR_WIDTH-1:0] head_plus_one;


    assign state_dbg = state;

    assign rx_phase      = (state == S_IDLE) || (state == S_RECV);
    assign mem_has_space = (tail_addr < DEPTH_VAL);
    assign head_plus_one = head_addr + PTR_ONE;

    //============================================================
    // NetFPGA side status
    //============================================================
    assign fifo_input_ready = rx_phase && mem_has_space;
    assign fifo_full        = ~fifo_input_ready;



    //============================================================
    // Head / Tail register readback
    //============================================================
    assign head_addr_reg = head_addr;
    assign tail_addr_reg = tail_addr;

    //============================================================
    // Downstream output
    // 注意：由于 BRAM 同步读，这里采用 SEND_ADDR -> SEND_DATA 两拍输出
    //============================================================
    assign fifo_output_valid = (state == S_SEND_DATA);
    assign fifo_output_data  = bram_doutb;
    assign fifo_output_last  = (state == S_SEND_DATA) &&
                               (head_plus_one == tail_addr);

//*************************************************************************************************************************************
    // CPU SRAM direct access block
    wire  [ADDR_WIDTH-1:0]    head_addr_No_MSB;
    wire  [ADDR_WIDTH-1:0]    tail_addr_No_MSB;
    wire  no_wrap  = (head_addr_No_MSB <= tail_addr_No_MSB);
    wire  in_upper = (sram_addr_port >= head_addr_No_MSB);
    wire  in_lower = (sram_addr_port <  tail_addr_No_MSB);

    assign head_addr_No_MSB = head_addr [ADDR_WIDTH-1:0];
    assign tail_addr_No_MSB = tail_addr [ADDR_WIDTH-1:0];

    assign sram_addr_in_range =
            (no_wrap  && in_upper && in_lower) ||
            (!no_wrap && (in_upper || in_lower));


// wire [ADDR_WIDTH:0] fifo_count;
// assign fifo_count = tail_addr - head_addr;

// wire [ADDR_WIDTH:0] addr_offset;
// assign addr_offset = {1'b0, sram_addr_port} - head_addr;

// assign sram_addr_in_range = (addr_offset < fifo_count);


    // CPU head/tail update block
    wire                     cpu_reg_update;
    wire                     cpu_reg_update_legal;
    wire [PTR_WIDTH-1:0]     send_head;
    wire [PTR_WIDTH-1:0]     send_tail;
    wire [PTR_WIDTH-1:0]     updated_val;
    wire [PTR_WIDTH-1:0]     DEPTH_VAL;
    wire [PTR_WIDTH-1:0]     head_move;
    wire [PTR_WIDTH-1:0]     tail_move;

    assign cpu_reg_update = cpu_head_we || cpu_tail_we
    assign DEPTH_VAL = tail_addr - head_addr;
    assign head_move = cpu_head_wdata - head_addr;
    assign tail_move = cpu_tail_wdata - head_addr;
    assign cpu_reg_update_legal = (!cpu_head_we || (head_move <= DEPTH_VAL)) && (!cpu_tail_we || (tail_move <= DEPTH_VAL));

    assign send_head = (cpu_reg_update && cpu_reg_update_legal)? cpu_head_wdata : head_addr;
    assign send_tail = (cpu_reg_update && cpu_reg_update_legal)? cpu_tail_wdata : tail_addr;












    // Instantiation
    dual_port_bram u_dual_port_bram (
        .clka  (clk),
        .dina  (bram_dina),
        .addra (bram_addra),
        .wea   (bram_wea),
        .douta (bram_douta),

        .clkb  (clk),
        .dinb  (bram_dinb),
        .addrb (bram_addrb),
        .web   (bram_web),
        .doutb (bram_doutb)
    );

    // BRAM Port A input
    always @(*) begin
    //always @(state or tail_addr or fifo_input_data or fifo_input_valid or fifo_input_ready or sram_addr_port or sram_data_in_port or cpu_sram_en or cpu_sram_we or sram_addr_in_range) begin
        bram_addra = {ADDR_WIDTH{1'b0}};
        bram_dina  = {DATA_WIDTH{1'b0}};
        bram_wea   = 1'b0;
        case (state)
            S_IDLE, S_RECV: begin
                bram_addra = tail_addr[ADDR_WIDTH-1:0];
                bram_dina  = fifo_input_data;
                bram_wea   = fifo_input_valid && fifo_input_ready;
            end

            S_CPU: begin
                bram_addra = sram_addr_port;
                bram_dina  = sram_data_in_port;
                bram_wea   = cpu_sram_en && cpu_sram_we && sram_addr_in_range;
            end

            default: begin
                bram_addra = {ADDR_WIDTH{1'b0}};
                bram_dina  = {DATA_WIDTH{1'b0}};
                bram_wea   = 1'b0;
            end
        endcase
    end


    // BRAM Port A output_to CPU
    always @(*) begin
        fifo_output_data   = {DATA_WIDTH{1'b0}};
        fifo_output_valid  = 1'b0;
        fifo_output_last   = 1'b0;

        case (state)
            S_SEND_ADDR, S_SEND_DATA: begin
                if () begin
                fifo_output_data   = {DATA_WIDTH{1'b0}};
                fifo_output_valid  = 1'b0;
                fifo_output_last   = 1'b0;
                end
            end

            default:begin
                fifo_output_data   = {DATA_WIDTH{1'b0}};
                fifo_output_valid  = 1'b0;
                fifo_output_last   = 1'b0;
            end
        endcase
    end

    // BRAM Port B input_to downstream block
    always @(head_addr) begin
        bram_addrb = head_addr [ADDR_WIDTH-1:0]
        bram_dinb = {DATA_WIDTH{1'b0}};
        bram_web  = 1'b0;
    end
  
    //BRAM Port B ouput
//******************************************************
 output wire                     fifo_input_ready,
    output wire                     fifo_full,//

 output wire [DATA_WIDTH-1:0]    sram_data_out_port,//
    output wire                     sram_addr_in_range,
    output wire                     cpu_sram_grant,


 output wire [PTR_WIDTH-1:0]     head_addr_reg,
    output wire [PTR_WIDTH-1:0]     tail_addr_reg,


 output reg                      packet_ready,   //

CPU_access_tail_head_invalid


    output reg [DATA_WIDTH-1:0]    fifo_output_data,//
    output reg                     fifo_output_valid,
    output reg                     fifo_output_last,


    output reg                      overflow_err,
    output reg                      illegal_cpu_addr_err,
    output wire [2:0]               state_dbg
//***********************************************************

    // FSM
    always @(posedge clk or posedge rst) begin 
        if (rst) begin
            state                <= S_IDLE;
            head_addr            <= PTR_ZERO;
            tail_addr            <= PTR_ZERO;
            bram_addrb           <= {ADDR_WIDTH{1'b0}};
            packet_ready         <= 1'b0;
            overflow_err         <= 1'b0;
            illegal_cpu_addr_err <= 1'b0;
        
        end else begin
            case (state)
                S_IDLE: begin
                    if (fifo_input_valid && fifo_overflow_err!) begin
                        tail_addr <= tail_addr + PTR_ONE;
                        bram_wea  <= 1'b1; 
                        state  <= S_RECV;
                    end 
                end

                S_RECV: begin
                    if ((head_addr[PTR_WIDTH-1] ^ tail_addr[PTR_WIDTH-1]) && (head_addr[PTR_WIDTH-2:0] == tail_addr[PTR_WIDTH-2:0]) ) begin
                        fifo_overflow_err <= 1'b1;
                        bram_wea          <= 1'b0;
                        state  <= S_IDLE;
                    end else begin
                        if (fifo_input_valid) begin
                            tail_addr <= tail_addr + PTR_ONE;
                                if (fifo_input_last) begin
                                    state        <= S_CPU_A;
                                    packet_ready <= 1'b1;
                                    bram_wea     <= 1'b0;
                                    fifo_full    <= 1'b1;
                                end
                        end
                    end
                end

                //CPU access head/tail reg
                S_CPU_A: begin
                    head_addr <= send_head;
                    tail_addr <= send_tail;
                    CPU_access_tail_head_invalid  <= ~cpu_reg_update_legal;
                    state  <= S_CPU_P;
                end

                //CPU process FIFO
                S_CPU_P: begin
                    if (cpu_start_send) 
                        packet_ready <= 1'b0;

                    if (send_head < send_tail) begin
                        bram_addrb <= send_head[ADDR_WIDTH-1:0];
                        head_addr  <= send_head;
                        tail_addr  <= send_tail;
                        state      <= S_SEND_ADDR;
                    end else begin
                        // CPU 把 packet 改成空包，直接回 IDLE
                        head_addr  <= PTR_ZERO;
                        tail_addr  <= PTR_ZERO;
                        state      <= S_IDLE;
                    end
                end
            
        

                //------------------------------------------------
                // 给 BRAM 一个拍锁存 addrb
                //------------------------------------------------
                S_SEND_ADDR: begin
                    state <= S_SEND_DATA;
                end

                //------------------------------------------------
                // 当前 bram_doutb 对应 head_addr
                //------------------------------------------------
                S_SEND_DATA: begin
                    if (fifo_output_ready) begin
                        if (head_plus_one == tail_addr) begin
                            // 最后一个字已被下游接收
                            head_addr  <= PTR_ZERO;
                            tail_addr  <= PTR_ZERO;
                            bram_addrb <= {ADDR_WIDTH{1'b0}};
                            state      <= S_IDLE;
                        end else begin
                            // 继续读下一字
                            head_addr  <= head_plus_one;
                            bram_addrb <= head_plus_one[ADDR_WIDTH-1:0];
                            state      <= S_SEND_ADDR;
                        end
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule