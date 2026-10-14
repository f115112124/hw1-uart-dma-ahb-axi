`timescale 1ns/1ps
// Teaching UART + DMA endpoint. Single clock domain, synchronous active-low reset.
module uart_dma #(
    parameter integer CLKS_PER_BIT = 8,
    parameter integer RX_FIFO_DEPTH = 8
) (
    input wire clk, input wire resetn,
    input wire reg_valid, input wire reg_write,
    input wire [31:0] reg_addr, input wire [31:0] reg_wdata,
    input wire [3:0] reg_strb,
    output wire reg_ready, output reg [31:0] reg_rdata,
    output reg reg_error,
    output wire dma_cmd_valid, output wire dma_cmd_write,
    output wire [31:0] dma_cmd_addr, output wire [2:0] dma_cmd_beats,
    output wire [127:0] dma_cmd_wdata, input wire dma_cmd_ready,
    input wire dma_rsp_valid, input wire [127:0] dma_rsp_rdata,
    input wire dma_rsp_error, output wire dma_rsp_ready,
    input wire uart_rx, output wire uart_tx
);
    localparam [3:0] D_IDLE=0, D_TX_CMD=1, D_TX_RSP=2,
                     D_TX_LAUNCH=3, D_TX_WAIT=4,
                     D_RX_COLLECT=5, D_RX_CMD=6, D_RX_RSP=7;
    reg [3:0] dma_state;
    reg [31:0] dma_src, dma_dst, dma_len;
    reg dma_direction, dma_busy, dma_done, sticky_error;
    reg [127:0] dma_buffer;
    reg [2:0] byte_index;
    wire tx_busy, tx_done;
    wire rx_byte_valid, rx_frame_error;
    wire [7:0] rx_byte;
    reg [7:0] rx_fifo [0:RX_FIFO_DEPTH-1];
    integer fifo_rd, fifo_wr, fifo_count;

    function automatic [31:0] merge_bytes;
        input [31:0] old_value, new_value;
        input [3:0] enables;
        integer j;
        begin
            merge_bytes = old_value;
            for (j=0; j<4; j=j+1)
                if (enables[j]) merge_bytes[j*8 +: 8] = new_value[j*8 +: 8];
        end
    endfunction
    wire [31:0] new_len = merge_bytes(dma_len, reg_wdata, reg_strb);
    wire start_request = reg_write && reg_addr[7:0]==8'h18 &&
                         reg_strb[0] && reg_wdata[0];
    wire [31:0] start_address = reg_wdata[1] ? dma_dst : dma_src;
    wire start_shape_ok = (dma_len==1 || dma_len==4) &&
                          start_address[1:0]==0 &&
                          start_address <= (32'h00001000 - (dma_len << 2));

    assign reg_ready = 1'b1;
    always @* begin
        reg_rdata = 32'b0;
        // AHB reserves a 1-KiB peripheral slot; only its first 256 bytes exist.
        reg_error = (reg_addr[1:0] != 0) || (reg_addr[9:8] != 0);
        case (reg_addr[7:0])
            8'h00: begin
                if (!reg_write) reg_error=1'b1;
                if (reg_write && reg_strb[0] && (tx_busy || dma_busy)) reg_error=1'b1;
            end
            8'h04: begin
                if (reg_write || fifo_count==0 || (dma_busy && dma_direction))
                    reg_error=1'b1;
                if (fifo_count!=0) reg_rdata={24'b0,rx_fifo[fifo_rd]};
            end
            8'h08: begin
                reg_rdata[0]=dma_busy;
                reg_rdata[1]=dma_done;
                reg_rdata[2]=sticky_error;
                reg_rdata[3]=tx_busy;
                reg_rdata[7:4]=fifo_count;
                if (reg_write) reg_error=1'b1;
            end
            8'h0c: begin
                reg_rdata=dma_src;
                if (reg_write && dma_busy) reg_error=1'b1;
            end
            8'h10: begin
                reg_rdata=dma_dst;
                if (reg_write && dma_busy) reg_error=1'b1;
            end
            8'h14: begin
                reg_rdata=dma_len;
                if (reg_write && (dma_busy || (new_len!=1 && new_len!=4)))
                    reg_error=1'b1;
            end
            8'h18: begin
                reg_rdata={30'b0,dma_direction,1'b0};
                if (reg_write && dma_busy) reg_error=1'b1;
                if (reg_write && reg_strb[0] && reg_wdata[7:2]!=0) reg_error=1'b1;
                if (start_request && (!start_shape_ok || tx_busy)) reg_error=1'b1;
            end
            default: reg_error=1'b1;
        endcase
    end
    wire reg_commit = reg_valid && reg_ready && !reg_error;
    wire software_tx = reg_commit && reg_write && reg_addr[7:0]==8'h00 && reg_strb[0];
    wire dma_tx = dma_state==D_TX_LAUNCH && !tx_busy;
    wire tx_start = software_tx || dma_tx;
    wire [7:0] tx_data = dma_tx ? dma_buffer[byte_index*32 +: 8] : reg_wdata[7:0];
    wire software_pop = reg_commit && !reg_write && reg_addr[7:0]==8'h04;
    wire dma_pop = dma_state==D_RX_COLLECT && fifo_count!=0;
    wire fifo_pop = software_pop || dma_pop;
    wire fifo_push = rx_byte_valid && (fifo_count<RX_FIFO_DEPTH || fifo_pop);

    assign dma_cmd_valid = dma_state==D_TX_CMD || dma_state==D_RX_CMD;
    assign dma_cmd_write = dma_state==D_RX_CMD;
    assign dma_cmd_addr = dma_state==D_RX_CMD ? dma_dst : dma_src;
    assign dma_cmd_beats = dma_len[2:0];
    assign dma_cmd_wdata = dma_buffer;
    assign dma_rsp_ready = dma_state==D_TX_RSP || dma_state==D_RX_RSP;

    uart_hw1_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) tx_engine (
        .clk(clk), .resetn(resetn), .start(tx_start), .data(tx_data),
        .busy(tx_busy), .done(tx_done), .tx(uart_tx));
    uart_hw1_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) rx_engine (
        .clk(clk), .resetn(resetn), .rx(uart_rx), .data(rx_byte),
        .valid(rx_byte_valid), .frame_error(rx_frame_error));

    always @(posedge clk) begin
        if (!resetn) begin
            fifo_rd<=0; fifo_wr<=0; fifo_count<=0;
        end else begin
            if (fifo_push) begin
                rx_fifo[fifo_wr]<=rx_byte;
                if (fifo_wr==RX_FIFO_DEPTH-1) fifo_wr<=0;
                else fifo_wr<=fifo_wr+1;
            end
            if (fifo_pop) begin
                if (fifo_rd==RX_FIFO_DEPTH-1) fifo_rd<=0;
                else fifo_rd<=fifo_rd+1;
            end
            case ({fifo_push,fifo_pop})
                2'b10: fifo_count<=fifo_count+1;
                2'b01: fifo_count<=fifo_count-1;
                default: fifo_count<=fifo_count;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            dma_src<=0; dma_dst<=0; dma_len<=4; dma_direction<=0;
            dma_busy<=0; dma_done<=0; sticky_error<=0;
            dma_state<=D_IDLE; dma_buffer<=0; byte_index<=0;
        end else begin
            if (rx_frame_error || (rx_byte_valid && !fifo_push)) sticky_error<=1'b1;
            if (reg_commit && reg_write) begin
                case (reg_addr[7:0])
                    8'h0c: dma_src<=merge_bytes(dma_src,reg_wdata,reg_strb);
                    8'h10: dma_dst<=merge_bytes(dma_dst,reg_wdata,reg_strb);
                    8'h14: dma_len<=new_len;
                    8'h18: if (reg_strb[0]) dma_direction<=reg_wdata[1];
                    default: begin end
                endcase
            end
            case (dma_state)
                D_IDLE: if (reg_commit && start_request) begin
                    dma_busy<=1; dma_done<=0; sticky_error<=0;
                    byte_index<=0; dma_buffer<=0;
                    if (reg_wdata[1]) dma_state<=D_RX_COLLECT;
                    else dma_state<=D_TX_CMD;
                end
                D_TX_CMD: if (dma_cmd_ready) dma_state<=D_TX_RSP;
                D_TX_RSP: if (dma_rsp_valid) begin
                    if (dma_rsp_error) begin
                        sticky_error<=1; dma_busy<=0; dma_done<=1; dma_state<=D_IDLE;
                    end else begin
                        dma_buffer<=dma_rsp_rdata; dma_state<=D_TX_LAUNCH;
                    end
                end
                D_TX_LAUNCH: if (!tx_busy) dma_state<=D_TX_WAIT;
                D_TX_WAIT: if (tx_done) begin
                    if (byte_index+1==dma_len) begin
                        dma_busy<=0; dma_done<=1; dma_state<=D_IDLE;
                    end else begin
                        byte_index<=byte_index+1; dma_state<=D_TX_LAUNCH;
                    end
                end
                D_RX_COLLECT: if (dma_pop) begin
                    dma_buffer[byte_index*32 +: 32]<={24'b0,rx_fifo[fifo_rd]};
                    if (byte_index+1==dma_len) dma_state<=D_RX_CMD;
                    else byte_index<=byte_index+1;
                end
                D_RX_CMD: if (dma_cmd_ready) dma_state<=D_RX_RSP;
                D_RX_RSP: if (dma_rsp_valid) begin
                    sticky_error<=sticky_error | dma_rsp_error; dma_busy<=0; dma_done<=1;
                    dma_state<=D_IDLE;
                end
                default: begin dma_state<=D_IDLE; dma_busy<=0; sticky_error<=1; end
            endcase
        end
    end
endmodule

module uart_hw1_tx #(parameter integer CLKS_PER_BIT=8) (
    input wire clk, input wire resetn, input wire start,
    input wire [7:0] data, output wire busy, output reg done, output reg tx
);
    localparam [1:0] T_IDLE=0,T_START=1,T_DATA=2,T_STOP=3;
    reg [1:0] state;
    integer bit_clock;
    reg [2:0] bit_index;
    reg [7:0] shift_data;
    assign busy = state!=T_IDLE;
    always @(posedge clk) begin
        if (!resetn) begin
            state<=T_IDLE; bit_clock<=0; bit_index<=0;
            shift_data<=0; tx<=1; done<=0;
        end else begin
            done<=0;
            case(state)
                T_IDLE: begin
                    tx<=1; bit_clock<=0;
                    if (start) begin tx<=0; shift_data<=data; state<=T_START; end
                end
                T_START: if (bit_clock==CLKS_PER_BIT-1) begin
                    bit_clock<=0; bit_index<=0; tx<=shift_data[0]; state<=T_DATA;
                end else bit_clock<=bit_clock+1;
                T_DATA: if (bit_clock==CLKS_PER_BIT-1) begin
                    bit_clock<=0;
                    if (bit_index==7) begin tx<=1; state<=T_STOP; end
                    else begin bit_index<=bit_index+1; tx<=shift_data[bit_index+1]; end
                end else bit_clock<=bit_clock+1;
                T_STOP: if (bit_clock==CLKS_PER_BIT-1) begin
                    bit_clock<=0; state<=T_IDLE; done<=1;
                end else bit_clock<=bit_clock+1;
            endcase
        end
    end
endmodule

module uart_hw1_rx #(parameter integer CLKS_PER_BIT=8) (
    input wire clk, input wire resetn, input wire rx,
    output reg [7:0] data, output reg valid, output reg frame_error
);
    localparam [1:0] R_IDLE=0,R_START=1,R_DATA=2,R_STOP=3;
    reg [1:0] state;
    reg rx_meta,rx_sync;
    integer bit_clock;
    reg [2:0] bit_index;
    reg [7:0] shift_data;
    always @(posedge clk) begin
        if (!resetn) begin
            rx_meta<=1; rx_sync<=1; state<=R_IDLE; bit_clock<=0;
            bit_index<=0; shift_data<=0; data<=0; valid<=0; frame_error<=0;
        end else begin
            rx_meta<=rx; rx_sync<=rx_meta; valid<=0; frame_error<=0;
            case(state)
                R_IDLE: if (!rx_sync) begin bit_clock<=0; state<=R_START; end
                R_START: if (bit_clock==(CLKS_PER_BIT/2)-1) begin
                    bit_clock<=0;
                    if (!rx_sync) begin state<=R_DATA; bit_index<=0; end
                    else state<=R_IDLE;
                end else bit_clock<=bit_clock+1;
                R_DATA: if (bit_clock==CLKS_PER_BIT-1) begin
                    bit_clock<=0; shift_data[bit_index]<=rx_sync;
                    if (bit_index==7) state<=R_STOP;
                    else bit_index<=bit_index+1;
                end else bit_clock<=bit_clock+1;
                R_STOP: if (bit_clock==CLKS_PER_BIT-1) begin
                    bit_clock<=0; state<=R_IDLE;
                    if (rx_sync) begin data<=shift_data; valid<=1; end
                    else frame_error<=1;
                end else bit_clock<=bit_clock+1;
            endcase
        end
    end
endmodule
