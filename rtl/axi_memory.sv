`timescale 1ns/1ps
module axi_memory (
 input wire clk,resetn,input wire reg_valid,reg_write,
 input wire [31:0] reg_addr,reg_wdata,input wire [3:0] reg_strb,
 output wire reg_ready,output wire [31:0] reg_rdata,output wire reg_error,
 input wire stall_enable,input wire inject_error
);
 reg [31:0] mem[0:1023];reg [2:0] phase;integer j;
 assign reg_ready=!stall_enable||phase==3;
 assign reg_error=reg_addr>=32'h1000||reg_addr[1:0]!=0||inject_error;
 assign reg_rdata=reg_error?0:mem[reg_addr[11:2]];
 always @(posedge clk) begin
  if(!resetn) phase<=0;
  else begin
   phase<=phase+1;
   if(reg_valid&&reg_ready&&reg_write&&!reg_error)
    for(j=0;j<4;j=j+1) if(reg_strb[j]) mem[reg_addr[11:2]][j*8 +:8]<=reg_wdata[j*8 +:8];
  end
 end
endmodule
