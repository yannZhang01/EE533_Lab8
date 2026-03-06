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

module fconvertible_fio #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 8
)(
    input                         clk,
    input                         rst,

    //********************************************************************************
    //整个架构的流程是：NetFPGA  →  FIFO/控制模块  →  CPU 或 输出接口
    //更准确的应该是：上游模块  →  设计的FIFO模块  →  下游模块
    //注意CPU在这个过程中只是"旁路访问者"，它的作用只是进入缓存的数据包（packet）进行处理
    //********************************************************************************

    //来自Netfpga（上游模块）的信号：
    input                         net_valid,   //当前周期 net_data 是有效数据。
    input  [DATA_WIDTH-1:0]       net_data,    //Netfpga 发送给FIFO的数据
    input                         net_last,    //这个信号用来判断当前给的net_data是不是整个packet的尾
    //反馈给Netfpga（上游模块）的信号：
    output reg                    net_ready,   // 发送给NetFPGA输入端的握手信号，表示当前模块是否可以接收新的net_data

    //给到下游模块的信号：
    output reg                    out_valid,   //本周期 out_data 是有效数据，模块告诉下游模块“我这拍有数据要发送”
    output reg [DATA_WIDTH-1:0]   out_data,    //给到下游模块的数据
    output reg                    out_last,    //此信号用来判断当前给到下游模块的out_data是否为Packet的尾
    //来自下游模块的信号：
    input                         out_ready,   //下游block告诉设计的FIFO模块“我可以接收来自你的数据包”

    //***************************************************************
    //CPU作为“旁路访问者”，他是如何访问FIFO模块的 ？
    //CPU → 控制寄存器 → 控制逻辑 → SRAM ***************** 这个非常重要
    //所以CPU发出的信号是在访问控制寄存器，而不是直接访问SRAM
    //***************************************************************

    //来自CPU(processor)的的信号：
    input                         proc_cs,     //片选信号，CPU告诉控制寄存器堆“我要在当前周期访问你”
    input                         proc_wr,     //CPU发出的写使能，proc_wr=1意味着当前周期CPU要对控制寄存器进行写操作， proc_wr=0意味着当前CPU要对控制寄存器进行读操作
    input  [3:0]                  proc_addr,   //CPU要访问的控制寄存器堆的地址
    input  [31:0]                 proc_wdata,  //CPU要写入控制寄存器的数
    //从控制寄存器对应地址读出的数：
    output reg [31:0]             proc_rdata,  //CPU从控制寄存器中读出的数

    //****************************************************
    //但是本次设计要求CPU具有对包含数据的 SRAM 的完全访问权限
    //所以我们还需要添加CPU → SRAM
    //****************************************************

    //来自CPU的信号：
    input                         proc_mem_en,     //CPU在本周期要直接访问SRAM
    input  [ADDR_WIDTH-1:0]       proc_mem_addr,   //CPU访问的SRAM的及具体地址
    input                         proc_mem_wr,     //proc_mem_wr = 1意味着要对SRAM进行写操作， proc_mem_wr = 0意味着要对SRAM进行读操作
    input  [DATA_WIDTH-1:0]       proc_mem_wdata,  //CPU在本周期要写入SRAM的数据
    //CPU从SRAM中读取的数据：
    output reg [DATA_WIDTH-1:0]   proc_mem_rdata,   

    
    output reg                    pkt_ready,    //给CPU看的信号，告诉CPU已经有一个完整的packet存入到FIFO中
    output reg                    fifo_full     //给上游模块看的（Netfpga）,告诉Netfpga已经存入完整的包，不能继续缓存数据
);

    //state machine的几种状态
    localparam S_IDLE      = 3'd0;  //空闲，等待新包
    localparam S_RECEIVE   = 3'd1;  //接收中，写入 FIFO/BRAM
    localparam S_WAIT_PROC = 3'd2;  //包已入 FIFO，等待 CPU 启动处理
    localparam S_PROC      = 3'd3;  //CPU 处理包
    localparam S_OUTPUT    = 3'd4;  //把 packet 送出给下游

    reg [2:0] state, next_state;

    reg [ADDR_WIDTH-1:0] head_addr;  //表示packet的起始点
    reg [ADDR_WIDTH-1:0] tail_addr;  //表示packet的结束位置 （指的是下一个即将写的位置）
    // head 和 tail只是用来标定整个packet的起始点和终止点，真正起到读指针的是read_ptr

    reg [ADDR_WIDTH-1:0] read_ptr;   //CPU用来读取packet的指针，它是真正扮演FIFO中读指针的角色

    reg                    bram_a_we;
    reg  [ADDR_WIDTH-1:0]  bram_a_addr;
    reg  [DATA_WIDTH-1:0]  bram_a_wdata;
    wire [DATA_WIDTH-1:0]  bram_a_rdata; 

    reg                    bram_b_we;
    reg  [ADDR_WIDTH-1:0]  bram_b_addr;
    reg  [DATA_WIDTH-1:0]  bram_b_wdata;
    wire [DATA_WIDTH-1:0]  bram_b_rdata;

    //Memory-Mapped Control Register
    reg [31:0] ctrl_reg;   //CPU 可以通过 proc_cs / proc_addr / proc_wdata 来读写它。

    wire proc_start_pulse = ctrl_reg[0];   //？？？？？？？？？
    wire proc_done_pulse  = ctrl_reg[1];   //？？？？？？？？？？？

    dual_port_bram u_bram (
        .clka(clk),
        .dina(bram_a_wdata),
        .addra(bram_a_addr),
        .wea(bram_a_we),
        .douta(bram_a_rdata),

        .clkb(clk),
        .dinb(bram_b_wdata),
        .addrb(bram_b_addr),
        .web(bram_b_we),
        .doutb(bram_b_rdata)
    );

    reg                    net_ready_next;
    reg                    pkt_ready_next;
    reg                    fifo_full_next;
    //port A的next状态
    reg                    bram_a_we_next;
    reg  [ADDR_WIDTH-1:0]  bram_a_addr_next;
    reg  [DATA_WIDTH-1:0]  bram_a_wdata_next;
    //port B的next状态
    reg                    bram_b_we_next;
    reg  [ADDR_WIDTH-1:0]  bram_b_addr_next;
    reg  [DATA_WIDTH-1:0]  bram_b_wdata_next;

    reg streaming_valid; 

    always @(state or net_valid or net_last or proc_start_pulse or proc_done_pulse or proc_mem_en or proc_mem_addr or proc_mem_wdata or proc_mem_wr or read_ptr)
    begin
        next_state = state;

        bram_a_we_next   = 1'b0;
        bram_a_addr_next = {ADDR_WIDTH{1'b0}};
        bram_a_wdata_next= {DATA_WIDTH{1'b0}};

        bram_b_we_next   = 1'b0;
        bram_b_addr_next = {ADDR_WIDTH{1'b0}};
        bram_b_wdata_next= {DATA_WIDTH{1'b0}};

        net_ready_next = 1'b0;
        pkt_ready_next = 1'b0;
        fifo_full_next = 1'b0;

        case (state)
            S_IDLE: begin
                net_ready_next = 1'b1;
                if (net_valid) begin
                    next_state = S_RECEIVE;
                    // on receiving first cycle, BRAM A write will be requested by sequential logic
                end
            end

            S_RECEIVE: begin
                net_ready_next = 1'b1;
                // if net_valid and net_last -> mark packet ready and move to wait_proc
                if (net_valid && net_last) begin
                    pkt_ready_next = 1'b1;
                    fifo_full_next = 1'b1;
                    next_state = S_WAIT_PROC;
                end
                // BRAM A write when net_valid is handled in sequential block using state/net_valid
            end

            S_WAIT_PROC: begin
                fifo_full_next = 1'b1;
                pkt_ready_next = 1'b1;
                if (proc_start_pulse) begin
                    next_state = S_PROC;
                end
            end

            S_PROC: begin
                if (proc_done_pulse) begin
                    next_state = S_OUTPUT;
                end
            end

            S_OUTPUT: begin
                // outputs handled in sequential block (streaming)
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase

        if (proc_mem_en) begin
            bram_b_addr_next = proc_mem_addr;
            bram_b_wdata_next= proc_mem_wdata;
            bram_b_we_next   = proc_mem_wr;
        end else if (state == S_OUTPUT) begin
            // when streaming (S_OUTPUT) the BRAM_B address should be read_ptr (registered)
            bram_b_addr_next = read_ptr;
            bram_b_we_next   = 1'b0;
        end else begin
            bram_b_addr_next = {ADDR_WIDTH{1'b0}};
            bram_b_we_next   = 1'b0;
        end
    end


    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;

            head_addr  <= {ADDR_WIDTH{1'b0}};
            tail_addr  <= {ADDR_WIDTH{1'b0}};
            read_ptr   <= {ADDR_WIDTH{1'b0}};

            ctrl_reg   <= 32'd0;

            pkt_ready  <= 1'b0;
            fifo_full  <= 1'b0;

            bram_a_we   <= 1'b0;
            bram_a_addr <= {ADDR_WIDTH{1'b0}};
            bram_a_wdata<= {DATA_WIDTH{1'b0}};

            bram_b_we   <= 1'b0;
            bram_b_addr <= {ADDR_WIDTH{1'b0}};
            bram_b_wdata<= {DATA_WIDTH{1'b0}};

            proc_mem_rdata <= {DATA_WIDTH{1'b0}};
            proc_rdata <= 32'd0;

            out_valid <= 1'b0;
            out_data  <= {DATA_WIDTH{1'b0}};
            out_last  <= 1'b0;
            streaming_valid <= 1'b0;

            // auxiliary
            first_word_in_packet <= 1'b0;
        end else begin
            // commit next state
            state <= next_state;

            // default: update pkt_ready/fifo_full from combinational next signals
            // (they are registered outputs now)
            pkt_ready <= pkt_ready_next;
            fifo_full <= fifo_full_next;

            // BRAM A: write when in S_RECEIVE and net_valid (original behavior)
            // We register the control signals based on state & net_valid to avoid multi-driver
            if (state == S_RECEIVE && net_valid) begin
                bram_a_we   <= 1'b1;
                bram_a_addr <= tail_addr;
                bram_a_wdata<= net_data;
                tail_addr   <= tail_addr + 1'b1; // advance tail on write
                first_word_in_packet <= 1'b0;
            end else begin
                bram_a_we <= 1'b0;
                // keep bram_a_addr/bram_a_wdata default or previous (we set zeros on reset)
                bram_a_addr <= bram_a_addr; 
                bram_a_wdata<= bram_a_wdata;
            end

            // When entering receive from idle with valid -> head_addr set to current tail (start of packet)
            if (state == S_IDLE && net_valid) begin
                head_addr <= tail_addr;
                first_word_in_packet <= 1'b1;
            end

            // read_ptr setup: when finishing proc and moving to output stage, set read_ptr=head_addr
            if (state == S_PROC && next_state == S_OUTPUT) begin
                read_ptr <= head_addr;
            end

            // bram_b controls are registered from combinational decisions (proc_mem_en or S_OUTPUT)
            bram_b_we   <= bram_b_we_next;
            bram_b_addr <= bram_b_addr_next;
            bram_b_wdata<= bram_b_wdata_next;

            // proc_mem_rdata: capture BRAM B data when proc_mem_en (synchronous read)
            if (proc_mem_en) begin
                proc_mem_rdata <= bram_b_rdata;
            end else if (state == S_OUTPUT) begin
                // hold value during streaming if no proc_mem_en
                proc_mem_rdata <= proc_mem_rdata;
            end else begin
                proc_mem_rdata <= proc_mem_rdata;
            end

            // Streaming / output behavior: implement original streaming FSM but registered here
            if (state == S_OUTPUT) begin
                // set streaming_valid to 1 at beginning of S_OUTPUT (registered)
                streaming_valid <= 1'b1;
                out_valid <= streaming_valid;    // out_valid is delayed by one cycle like original code
                out_data  <= bram_b_rdata;

                // determine out_last based on read_ptr vs tail_addr
                if (read_ptr == (tail_addr - 1'b1)) begin
                    out_last <= 1'b1;
                end else begin
                    out_last <= 1'b0;
                end

                // advance read_ptr when out_valid & out_ready (same as original)
                if (out_valid && out_ready) begin
                    read_ptr <= read_ptr + 1'b1;
                    if (out_last) begin
                        // when finishing packet, advance head_addr to tail_addr (packet consumed)
                        head_addr <= tail_addr;
                    end
                end
            end else begin
                // not streaming: clear streaming signals
                streaming_valid <= 1'b0;
                out_valid <= 1'b0;
                out_data  <= {DATA_WIDTH{1'b0}};
                out_last  <= 1'b0;
            end

            // CPU register access and writes (synchronous) - consolidate here to avoid multiple writers
            if (proc_cs && proc_wr) begin
                case (proc_addr)
                    4'd0: begin
                        head_addr <= proc_wdata[ADDR_WIDTH-1:0];
                    end
                    4'd1: begin
                        tail_addr <= proc_wdata[ADDR_WIDTH-1:0];
                    end
                    4'd2: begin
                        // ctrl_reg bits [1:0] set by CPU writes (OR behavior preserved)
                        ctrl_reg[1:0] <= ctrl_reg[1:0] | proc_wdata[1:0];
                    end
                    default: begin
                        // no change
                    end
                endcase
            end

            // CPU readbacks (synchronous read response)
            if (proc_cs && !proc_wr) begin
                case (proc_addr)
                    4'd0: proc_rdata <= {24'd0, head_addr};
                    4'd1: proc_rdata <= {24'd0, tail_addr};
                    4'd2: proc_rdata <= {29'd0, fifo_full, pkt_ready, ctrl_reg[0]};
                    default: proc_rdata <= 32'd0;
                endcase
            end else begin
                proc_rdata <= proc_rdata; // hold
            end

            // ctrl_reg bit-clear events (original behavior preserved):
            // original code cleared ctrl_reg[0] when entering S_PROC (next_state == S_PROC)
            if (next_state == S_PROC) begin
                ctrl_reg[0] <= 1'b0;
            end
            // clear ctrl_reg[1] when proc_done_pulse occurred during S_PROC
            if (proc_done_pulse && (state == S_PROC)) begin
                ctrl_reg[1] <= 1'b0;
            end

        end
    end

    // ------------------------------------------------------------------
    // Combinational outputs that drive top-level ports and BRAM ports
    // (these are derived from registered signals; no register is driven elsewhere)
    // ------------------------------------------------------------------
    // net_ready is a registered output (we registered net_ready_next into pkt_ready/fifo_full above).
    // To preserve behaviour where net_ready drives are combinational in original:
    // we expose net_ready as combinational from current state (but it's OK to register it too).
    // Here choose to drive net_ready combinationally based on state to match original immediacy.
    always @(*) begin
        // keep compatibility with original: net_ready asserted when in IDLE or RECEIVE
        if (state == S_IDLE || state == S_RECEIVE) begin
            net_ready = 1'b1;
        end else begin
            net_ready = 1'b0;
        end
    end
endmodule
    // BRAM ports: use the registered bram_a_* and bram_b_* signals (these are regs assigned in the sync block)
    // bram_a_* and bram_b_* are already declared as regs and connected to the dual_port_bram instance