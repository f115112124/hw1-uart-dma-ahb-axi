`timescale 1ns/1ps
// Two-master/two-slave, whole-transaction round robin teaching fabric.
// Address map: 4KiB RAM and 256-byte UART. Unmapped requests use an error route.
// One routed transaction at a time; every ID is implicitly zero.
module axi_interconnect (
 input wire clk,resetn,
 input wire [1:0][31:0] m_awaddr,input wire [1:0][7:0] m_awlen,
 input wire [1:0][2:0] m_awsize,input wire [1:0][1:0] m_awburst,
 input wire [1:0] m_awvalid,output reg [1:0] m_awready,
 input wire [1:0][31:0] m_wdata,input wire [1:0][3:0] m_wstrb,
 input wire [1:0] m_wlast,m_wvalid,output reg [1:0] m_wready,
 output reg [1:0][1:0] m_bresp,output reg [1:0] m_bvalid,input wire [1:0] m_bready,
 input wire [1:0][31:0] m_araddr,input wire [1:0][7:0] m_arlen,
 input wire [1:0][2:0] m_arsize,input wire [1:0][1:0] m_arburst,
 input wire [1:0] m_arvalid,output reg [1:0] m_arready,
 output reg [1:0][31:0] m_rdata,output reg [1:0][1:0] m_rresp,
 output reg [1:0] m_rlast,m_rvalid,input wire [1:0] m_rready,
 output reg [1:0][31:0] s_awaddr,output reg [1:0][7:0] s_awlen,
 output reg [1:0][2:0] s_awsize,output reg [1:0][1:0] s_awburst,
 output reg [1:0] s_awvalid,input wire [1:0] s_awready,
 output reg [1:0][31:0] s_wdata,output reg [1:0][3:0] s_wstrb,
 output reg [1:0] s_wlast,s_wvalid,input wire [1:0] s_wready,
 input wire [1:0][1:0] s_bresp,input wire [1:0] s_bvalid,output reg [1:0] s_bready,
 output reg [1:0][31:0] s_araddr,output reg [1:0][7:0] s_arlen,
 output reg [1:0][2:0] s_arsize,output reg [1:0][1:0] s_arburst,
 output reg [1:0] s_arvalid,input wire [1:0] s_arready,
 input wire [1:0][31:0] s_rdata,input wire [1:0][1:0] s_rresp,
 input wire [1:0] s_rlast,s_rvalid,output reg [1:0] s_rready,
 output reg [1:0] s_decode_error,
 output wire active,output reg owner,output reg target,output reg rr
);
 localparam F_IDLE=0,F_READ=1,F_WRITE=2;
 reg [1:0] state;reg decode_bad;reg candidate;reg [31:0] chosen_addr;
 reg [7:0] chosen_len;reg [32:0] chosen_last;
 wire [1:0] request=m_awvalid|m_arvalid;
 assign active=state!=F_IDLE;
 always @* begin
   candidate=rr;
   if(!request[rr]) candidate=!rr;
   chosen_addr=m_awvalid[candidate]?m_awaddr[candidate]:m_araddr[candidate];
   chosen_len=m_awvalid[candidate]?m_awlen[candidate]:m_arlen[candidate];
   chosen_last={1'b0,chosen_addr}+(({25'b0,chosen_len}+33'd1)<<2)-33'd1;
 end
 always @(posedge clk) begin
  if(!resetn) begin state<=F_IDLE;owner<=0;target<=0;rr<=0;decode_bad<=0;end
  else case(state)
   F_IDLE: if(|request) begin
     owner<=candidate;
     target<=chosen_addr>=32'h40000000&&chosen_addr<32'h40000100;
     decode_bad<=!((chosen_addr<32'h1000&&chosen_last<33'h1000) ||
       (chosen_addr>=32'h40000000&&chosen_last<33'h40000100));
     state<=m_awvalid[candidate]?F_WRITE:F_READ;
   end
   F_READ: if(s_rvalid[target]&&m_rready[owner]&&s_rlast[target]) begin
     state<=F_IDLE;rr<=!owner;
   end
   F_WRITE: if(s_bvalid[target]&&m_bready[owner]) begin state<=F_IDLE;rr<=!owner;end
   default:state<=F_IDLE;
  endcase
 end
 always @* begin
  m_awready=0;m_wready=0;m_bresp=0;m_bvalid=0;
  m_arready=0;m_rdata=0;m_rresp=0;m_rlast=0;m_rvalid=0;
  s_awaddr=0;s_awlen=0;s_awsize=0;s_awburst=0;s_awvalid=0;
  s_wdata=0;s_wstrb=0;s_wlast=0;s_wvalid=0;s_bready=0;
  s_araddr=0;s_arlen=0;s_arsize=0;s_arburst=0;s_arvalid=0;s_rready=0;s_decode_error=0;
  if(state==F_WRITE) begin
   s_decode_error[target]=decode_bad;
   s_awaddr[target]=m_awaddr[owner];s_awlen[target]=m_awlen[owner];
   s_awsize[target]=m_awsize[owner];s_awburst[target]=m_awburst[owner];
   s_awvalid[target]=m_awvalid[owner];m_awready[owner]=s_awready[target];
   s_wdata[target]=m_wdata[owner];s_wstrb[target]=m_wstrb[owner];
   s_wlast[target]=m_wlast[owner];s_wvalid[target]=m_wvalid[owner];
   m_wready[owner]=s_wready[target];m_bresp[owner]=s_bresp[target];
   m_bvalid[owner]=s_bvalid[target];s_bready[target]=m_bready[owner];
  end
  if(state==F_READ) begin
   s_decode_error[target]=decode_bad;
   s_araddr[target]=m_araddr[owner];s_arlen[target]=m_arlen[owner];
   s_arsize[target]=m_arsize[owner];s_arburst[target]=m_arburst[owner];
   s_arvalid[target]=m_arvalid[owner];m_arready[owner]=s_arready[target];
   m_rdata[owner]=s_rdata[target];m_rresp[owner]=s_rresp[target];
   m_rlast[owner]=s_rlast[target];m_rvalid[owner]=s_rvalid[target];
   s_rready[target]=m_rready[owner];
  end
 end
endmodule
