`timescale 1ns/1ps
module ahb_slave (
 input wire clk, resetn, input wire HSEL, input wire HREADY,
 input wire [31:0] HADDR, HWDATA, input wire [1:0] HTRANS,
 input wire [2:0] HSIZE, input wire HWRITE,
 output wire HREADYOUT, output wire [1:0] HRESP, output wire [31:0] HRDATA,
 output wire reg_valid, output wire reg_write, output wire [31:0] reg_addr,
 output wire [31:0] reg_wdata, output wire [3:0] reg_strb,
 input wire reg_ready, input wire [31:0] reg_rdata, input wire reg_error
);
 localparam S_IDLE=0,S_EXEC=1,S_OK=2,S_ERR1=3,S_ERR2=4;
 reg [2:0] state; reg [31:0] address,read_result; reg wr;
 wire accept=HREADY && HSEL && HTRANS[1];
 assign HREADYOUT=state==S_IDLE || state==S_OK || state==S_ERR2;
 assign HRESP=(state==S_ERR1 || state==S_ERR2)?2'b01:2'b00;
 assign HRDATA=read_result;
 assign reg_valid=state==S_EXEC;
 assign reg_write=wr; assign reg_addr=address;
 // AHB write data belongs to the DATA phase, not the address-capture edge.
 assign reg_wdata=HWDATA; assign reg_strb=4'b1111;
 task automatic take_address;
   begin
     address<=HADDR; wr<=HWRITE;
     if(HSIZE!=3'b010 || HADDR[1:0]!=0) state<=S_ERR1;
     else state<=S_EXEC;
   end
 endtask
 always @(posedge clk) begin
   if(!resetn) begin state<=S_IDLE; address<=0; read_result<=0; wr<=0; end
   else case(state)
     S_IDLE: if(accept) take_address();
     S_EXEC: if(reg_ready) begin
       read_result<=reg_error?32'b0:reg_rdata;
       if(reg_error) state<=S_ERR1; else state<=S_OK;
     end
     S_OK: if(accept) take_address(); else state<=S_IDLE;
     S_ERR1: state<=S_ERR2;
     S_ERR2: if(accept) take_address(); else state<=S_IDLE;
     default: state<=S_IDLE;
   endcase
 end
endmodule
