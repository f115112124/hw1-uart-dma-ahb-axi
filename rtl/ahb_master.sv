`timescale 1ns/1ps
// Conservative AMBA 2 AHB subset: SINGLE/INCR4, aligned words, OKAY/ERROR.
// One data beat outstanding; BUSY cycles preserve a fixed burst between beats.
module ahb_master (
 input wire clk, resetn,
 input wire cmd_valid, cmd_write, input wire [31:0] cmd_addr,
 input wire [2:0] cmd_beats, input wire [127:0] cmd_wdata,
 output wire cmd_ready, output wire rsp_valid,
 output reg [127:0] rsp_rdata, output reg rsp_error, input wire rsp_ready,
 output wire HBUSREQ, input wire HGRANT,
 output reg [31:0] HADDR, output reg [1:0] HTRANS,
 output wire [2:0] HBURST, output wire [2:0] HSIZE,
 output wire HWRITE, output wire [31:0] HWDATA,
 input wire HREADY, input wire [1:0] HRESP, input wire [31:0] HRDATA
);
 localparam M_IDLE=0,M_REQ=1,M_ADDR=2,M_DATA=3,M_ERR2=4,M_RSP=5;
 reg [2:0] state, beats, beat;
 reg wr; reg [31:0] base; reg [127:0] words;
 wire shape_ok=(cmd_beats==1 || cmd_beats==4) && cmd_addr[1:0]==0 &&
               ({1'b0,cmd_addr[9:0]}+({8'b0,cmd_beats}<<2)<=11'd1024);
 assign cmd_ready=state==M_IDLE;
 assign rsp_valid=state==M_RSP;
 assign HBUSREQ=state==M_REQ || state==M_ADDR || state==M_DATA || state==M_ERR2;
 assign HSIZE=3'b010;
 assign HBURST=beats==4 ? 3'b011 : 3'b000;
 assign HWRITE=wr;
 assign HWDATA=words[beat*32 +:32];
 always @* begin
   HADDR=base+({29'b0,beat}<<2); HTRANS=2'b00;
   if(state==M_ADDR) HTRANS=beat==0 ? 2'b10 : 2'b11;
   if(state==M_DATA && beat+1<beats) begin
     HTRANS=2'b01; HADDR=base+(({29'b0,beat}+1)<<2);
   end
 end
 always @(posedge clk) begin
   if(!resetn) begin state<=M_IDLE; beats<=1; beat<=0; wr<=0; base<=0;
     words<=0; rsp_rdata<=0; rsp_error<=0; end
   else case(state)
     M_IDLE: if(cmd_valid) begin
       wr<=cmd_write; base<=cmd_addr; beats<=cmd_beats; words<=cmd_wdata;
       beat<=0; rsp_rdata<=0; rsp_error<=!shape_ok;
       if(shape_ok) state<=M_REQ; else state<=M_RSP;
     end
     M_REQ: if(HGRANT && HREADY) state<=M_ADDR;
     M_ADDR: if(HREADY) state<=M_DATA;
     M_DATA: begin
       if(HRESP==2'b01 && !HREADY) begin rsp_error<=1; state<=M_ERR2; end
       else if(HREADY) begin
         if(HRESP!=0) begin rsp_error<=1; state<=M_RSP; end
         else begin
           if(!wr) rsp_rdata[beat*32 +:32]<=HRDATA;
           if(beat+1==beats) state<=M_RSP;
           else begin beat<=beat+1; state<=M_ADDR; end
         end
       end
     end
     M_ERR2: if(HREADY) state<=M_RSP;
     M_RSP: if(rsp_ready) state<=M_IDLE;
     default: state<=M_IDLE;
   endcase
 end
endmodule
