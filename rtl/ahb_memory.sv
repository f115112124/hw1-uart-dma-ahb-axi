`timescale 1ns/1ps
module ahb_memory #(parameter integer WAIT_CYCLES=2) (
 input wire clk,resetn,reg_valid,reg_write,
 input wire [31:0] reg_addr,reg_wdata,input wire [3:0] reg_strb,
 output wire reg_ready,output wire [31:0] reg_rdata,output wire reg_error
);
 reg [31:0] mem[0:1023]; integer wait_count; integer j;
 assign reg_ready=wait_count>=WAIT_CYCLES;
 assign reg_error=reg_addr>=4096 || reg_addr[1:0]!=0;
 assign reg_rdata=reg_error?0:mem[reg_addr[11:2]];
 always @(posedge clk) begin
   if(!resetn) begin wait_count<=0;for(j=0;j<1024;j=j+1)mem[j]<=0;end
   else if(reg_valid) begin
     if(reg_ready) begin
       wait_count<=0;
       if(reg_write && !reg_error)
         for(j=0;j<4;j=j+1)if(reg_strb[j])mem[reg_addr[11:2]][j*8 +:8]<=reg_wdata[j*8 +:8];
     end else wait_count<=wait_count+1;
   end else wait_count<=0;
 end
endmodule
