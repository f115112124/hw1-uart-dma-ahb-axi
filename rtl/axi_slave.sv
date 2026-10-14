`timescale 1ns/1ps
// Buffered AXI4 endpoint. Register accesses happen only at reg_valid&&reg_ready.
// The address and up to four write beats are collected independently.
module axi_slave #(parameter integer AW_ACCEPT_DELAY=0) (
 input wire clk,resetn,input wire decode_error,
 input wire [31:0] awaddr,input wire [7:0] awlen,
 input wire [2:0] awsize,input wire [1:0] awburst,
 input wire awvalid,output wire awready,
 input wire [31:0] wdata,input wire [3:0] wstrb,
 input wire wlast,wvalid,output wire wready,
 output wire [1:0] bresp,output wire bvalid,input wire bready,
 input wire [31:0] araddr,input wire [7:0] arlen,
 input wire [2:0] arsize,input wire [1:0] arburst,
 input wire arvalid,output wire arready,
 output reg [31:0] rdata,output reg [1:0] rresp,
 output wire rlast,rvalid,input wire rready,
 output wire reg_valid,reg_write,output wire [31:0] reg_addr,reg_wdata,
 output wire [3:0] reg_strb,input wire reg_ready,
 input wire [31:0] reg_rdata,input wire reg_error
);
 localparam S_IDLE=0,S_READ_EXEC=1,S_READ_RESP=2,S_WRITE_COLLECT=3,
            S_WRITE_EXEC=4,S_WRITE_RESP=5;
 reg [2:0] state;
 reg [31:0] address;
 reg [8:0] total,index,wcount;
 reg aw_have,wlast_seen,bad_shape;
 reg [1:0] error_response;
 reg [31:0] words[0:3];reg [3:0] strobes[0:3];
 integer aw_wait;
 wire aw_fire=awvalid&&awready,w_fire=wvalid&&wready;
 wire [12:0] aw_bytes=({5'b0,awlen}+13'd1)<<2;
 wire [12:0] ar_bytes=({5'b0,arlen}+13'd1)<<2;
 wire aw_good=(awlen==0||awlen==3)&&awsize==2&&awburst==1&&awaddr[1:0]==0&&
   ({1'b0,awaddr[11:0]}+aw_bytes<=4096);
 wire ar_good=(arlen==0||arlen==3)&&arsize==2&&arburst==1&&araddr[1:0]==0&&
   ({1'b0,araddr[11:0]}+ar_bytes<=4096);
 // READY is derived from registered state, with no combinational VALID dependency.
 assign arready=state==S_IDLE;
 assign awready=state==S_WRITE_COLLECT&&!aw_have&&aw_wait==0;
 // Unsupported legal AXI burst shapes are drained after their AW is known.
 assign wready=state==S_WRITE_COLLECT&&!wlast_seen&&(wcount<4||(aw_have&&bad_shape));
 assign bvalid=state==S_WRITE_RESP;assign bresp=error_response;
 assign rvalid=state==S_READ_RESP;assign rlast=index==total-1;
 assign reg_valid=(state==S_READ_EXEC||state==S_WRITE_EXEC)&&error_response==0;
 assign reg_write=state==S_WRITE_EXEC;
 assign reg_addr=address+(index<<2);
 assign reg_wdata=words[index[1:0]];
 assign reg_strb=reg_write?strobes[index[1:0]]:4'hf;
 always @(posedge clk) begin
   if(!resetn) begin
     state<=S_IDLE;address<=0;total<=1;index<=0;wcount<=0;aw_have<=0;
     wlast_seen<=0;bad_shape<=0;error_response<=0;rdata<=0;rresp<=0;aw_wait<=0;
   end else case(state)
    S_IDLE: begin
      index<=0;wcount<=0;aw_have<=0;wlast_seen<=0;bad_shape<=0;error_response<=0;
      if(arvalid&&arready) begin
        address<=araddr;total<={1'b0,arlen}+1;
        error_response<=decode_error?2'b11:(!ar_good?2'b10:2'b00);
        state<=S_READ_EXEC;
      end else if(awvalid||wvalid) begin state<=S_WRITE_COLLECT;aw_wait<=AW_ACCEPT_DELAY;end
    end
    S_READ_EXEC: begin
      if(error_response!=0) begin rdata<=0;rresp<=error_response;state<=S_READ_RESP;end
      else if(reg_ready) begin
        rdata<=reg_rdata;rresp<=reg_error?2'b10:2'b00;state<=S_READ_RESP;
      end
    end
    S_READ_RESP: if(rready) begin
      if(rlast) state<=S_IDLE;
      else begin index<=index+1;state<=S_READ_EXEC;end
    end
    S_WRITE_COLLECT: begin
      if(aw_wait>0) aw_wait<=aw_wait-1;
      if(aw_fire) begin
        address<=awaddr;total<={1'b0,awlen}+1;aw_have<=1;bad_shape<=!aw_good;
        error_response<=decode_error?2'b11:(!aw_good?2'b10:2'b00);
      end
      if(w_fire) begin
        if(wcount<4) begin words[wcount[1:0]]<=wdata;strobes[wcount[1:0]]<=wstrb;end
        wcount<=wcount+1;if(wlast) wlast_seen<=1;
      end
      if(aw_have&&wlast_seen) begin
        if(wcount!=total) error_response<=2'b10;
        state<=S_WRITE_EXEC;index<=0;
      end
    end
    S_WRITE_EXEC: begin
      if(error_response!=0) state<=S_WRITE_RESP;
      else if(reg_ready) begin
        if(reg_error) begin error_response<=2'b10;state<=S_WRITE_RESP;end
        else if(index==total-1) state<=S_WRITE_RESP;
        else index<=index+1;
      end
    end
    S_WRITE_RESP: if(bready) state<=S_IDLE;
    default:state<=S_IDLE;
   endcase
 end
endmodule
