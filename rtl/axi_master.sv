`timescale 1ns/1ps
// AXI4 teaching master: 32-bit aligned INCR, 1 or 4 beats, one outstanding.
// AW and W advance independently. IDs are fixed to zero (serialized fabric).
module axi_master #(parameter integer AW_DELAY=0, W_DELAY=0) (
 input wire clk,resetn,
 input wire cmd_valid,cmd_write, input wire [31:0] cmd_addr,
 input wire [2:0] cmd_beats, input wire [127:0] cmd_wdata,
 output wire cmd_ready, output wire rsp_valid, input wire rsp_ready,
 output reg [127:0] rsp_rdata, output reg rsp_error,
 output wire [31:0] awaddr, output wire [7:0] awlen,
 output wire [2:0] awsize, output wire [1:0] awburst,
 output wire awvalid,input wire awready,
 output wire [31:0] wdata, output wire [3:0] wstrb,
 output wire wlast,wvalid,input wire wready,
 input wire [1:0] bresp,input wire bvalid,output wire bready,
 output wire [31:0] araddr,output wire [7:0] arlen,
 output wire [2:0] arsize,output wire [1:0] arburst,
 output wire arvalid,input wire arready,
 input wire [31:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready,
 input wire allow_r,input wire allow_b
);
 localparam M_IDLE=0,M_READ_ADDR=1,M_READ_DATA=2,M_WRITE_SEND=3,
            M_WRITE_RESP=4,M_RESPONSE=5;
 reg [2:0] state;
 reg [31:0] address;
 reg [2:0] beats,wi,ri;
 reg [127:0] payload;
 reg aw_done,w_done;
 integer aw_delay_count,w_delay_count;
 wire aw_fire=awvalid&&awready, w_fire=wvalid&&wready;
 wire r_fire=rvalid&&rready;
 wire shape_ok=(cmd_beats==1 || cmd_beats==4) && cmd_addr[1:0]==0 &&
    ({1'b0,cmd_addr[11:0]}+({10'b0,cmd_beats}<<2)<=13'd4096);
 assign cmd_ready=state==M_IDLE;
 assign rsp_valid=state==M_RESPONSE;
 assign awaddr=address; assign araddr=address;
 assign awlen={5'b0,beats}-8'd1; assign arlen={5'b0,beats}-8'd1;
 assign awsize=3'd2;assign arsize=3'd2;
 assign awburst=2'b01;assign arburst=2'b01;
 assign awvalid=state==M_WRITE_SEND&&!aw_done&&aw_delay_count==0;
 assign wvalid=state==M_WRITE_SEND&&!w_done&&w_delay_count==0;
 assign wdata=payload[wi*32 +:32];assign wstrb=4'hf;
 assign wlast=wi==beats-1;
 assign bready=state==M_WRITE_RESP&&allow_b;
 assign arvalid=state==M_READ_ADDR;
 assign rready=state==M_READ_DATA&&allow_r;
 always @(posedge clk) begin
   if(!resetn) begin
     state<=M_IDLE;address<=0;beats<=1;payload<=0;wi<=0;ri<=0;
     aw_done<=0;w_done<=0;rsp_rdata<=0;rsp_error<=0;
     aw_delay_count<=0;w_delay_count<=0;
   end else case(state)
    M_IDLE: if(cmd_valid) begin
      address<=cmd_addr;beats<=cmd_beats;payload<=cmd_wdata;
      wi<=0;ri<=0;aw_done<=0;w_done<=0;rsp_rdata<=0;rsp_error<=!shape_ok;
      aw_delay_count<=AW_DELAY;w_delay_count<=W_DELAY;
      if(!shape_ok) state<=M_RESPONSE;
      else if(cmd_write) state<=M_WRITE_SEND;
      else state<=M_READ_ADDR;
    end
    M_READ_ADDR: if(arready) state<=M_READ_DATA;
    M_READ_DATA: if(r_fire) begin
      rsp_rdata[ri*32 +:32]<=rdata;
      if(rresp[1] || rlast!=(ri==beats-1)) rsp_error<=1;
      if(rlast) state<=M_RESPONSE;
      else ri<=ri+1;
    end
    M_WRITE_SEND: begin
      if(aw_delay_count>0) aw_delay_count<=aw_delay_count-1;
      if(w_delay_count>0) w_delay_count<=w_delay_count-1;
      if(aw_fire) aw_done<=1;
      if(w_fire) begin
        if(wlast) w_done<=1;else wi<=wi+1;
      end
      if((aw_done||aw_fire)&&(w_done||(w_fire&&wlast))) state<=M_WRITE_RESP;
    end
    M_WRITE_RESP: if(bvalid&&bready) begin rsp_error<=bresp[1];state<=M_RESPONSE;end
    M_RESPONSE: if(rsp_ready) state<=M_IDLE;
    default: state<=M_IDLE;
   endcase
 end
endmodule
