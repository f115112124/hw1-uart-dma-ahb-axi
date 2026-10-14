`timescale 1ns/1ps
// Two-master, two-mapped-slave bus; arbitration is held for a whole local command.
// Includes an unmapped-address ERROR responder. Address/data slave selection is pipelined.
module ahb_interconnect (
 input wire clk, resetn, input wire [1:0] m_req, output wire [1:0] m_grant,
 input wire [63:0] m_addr,m_wdata, input wire [3:0] m_trans,
 input wire [5:0] m_size,m_burst, input wire [1:0] m_write,
 output wire [31:0] HADDR,HWDATA, output wire [1:0] HTRANS,
 output wire [2:0] HSIZE,HBURST, output wire HWRITE,
 output wire [1:0] HSEL,
 input wire [1:0] s_ready, input wire [3:0] s_resp, input wire [63:0] s_rdata,
 output reg HREADY, output reg [1:0] HRESP, output reg [31:0] HRDATA,
 output wire bus_owner, output wire bus_active
);
 localparam A_IDLE=0,A_M0=1,A_M1=2;
 reg [1:0] arb_state; reg last_owner;
 reg [1:0] data_sel; reg [1:0] default_phase;
 wire owner=arb_state==A_M1;
 wire active=arb_state!=A_IDLE;
 assign bus_owner=owner; assign bus_active=active;
 assign m_grant=arb_state==A_M0?2'b01:arb_state==A_M1?2'b10:2'b00;
 assign HADDR=active?m_addr[owner*32 +:32]:32'b0;
 assign HWDATA=active?m_wdata[owner*32 +:32]:32'b0;
 assign HTRANS=active?m_trans[owner*2 +:2]:2'b00;
 assign HSIZE=active?m_size[owner*3 +:3]:3'b010;
 assign HBURST=active?m_burst[owner*3 +:3]:3'b000;
 assign HWRITE=active?m_write[owner]:1'b0;
 assign HSEL[0]=active && HADDR<32'h00001000;
 // AHB allocation is 1 KiB; the endpoint rejects unimplemented register offsets.
 assign HSEL[1]=active && HADDR>=32'h40000000 && HADDR<32'h40000400;
 always @* begin
   HREADY=1; HRESP=0; HRDATA=0;
   case(data_sel)
     1: begin HREADY=s_ready[0];HRESP=s_resp[1:0];HRDATA=s_rdata[31:0];end
     2: begin HREADY=s_ready[1];HRESP=s_resp[3:2];HRDATA=s_rdata[63:32];end
     3: begin HREADY=default_phase==2; HRESP=2'b01; end
     default: begin end
   endcase
 end
 always @(posedge clk) begin
   if(!resetn) begin arb_state<=A_IDLE;last_owner<=1;data_sel<=0;default_phase<=0;end
   else begin
     case(arb_state)
       A_IDLE: if(m_req==3) arb_state<=last_owner?A_M0:A_M1;
               else if(m_req[0]) arb_state<=A_M0;
               else if(m_req[1]) arb_state<=A_M1;
       A_M0: if(!m_req[0] && HREADY) begin
         last_owner<=0; if(m_req[1]) arb_state<=A_M1; else arb_state<=A_IDLE;
       end
       A_M1: if(!m_req[1] && HREADY) begin
         last_owner<=1; if(m_req[0]) arb_state<=A_M0; else arb_state<=A_IDLE;
       end
     endcase
     if(default_phase==1) default_phase<=2;
     if(HREADY) begin
       default_phase<=0;
       if(!HTRANS[1]) data_sel<=0;
       else if(HSEL[0]) data_sel<=1;
       else if(HSEL[1]) data_sel<=2;
       else begin data_sel<=3;default_phase<=1;end
     end
   end
 end
endmodule
