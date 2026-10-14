`timescale 1ns/1ps
module tb_axi;
 localparam CPB=8;
 reg clk=0;always #5 clk=~clk;
 reg resetn=0,uart_rx=1;wire uart_tx;
 reg cpu_valid=0,cpu_write=0,cpu_rsp_ready=1;
 reg [31:0] cpu_addr=0;reg [2:0] cpu_beats=1;reg [127:0] cpu_wdata=0;
 wire dma_valid,dma_write,dma_ready,dma_rsp_ready;
 wire [31:0] dma_addr;wire [2:0] dma_beats;wire [127:0] dma_wdata;
 reg dma_gate=1,release_dma_on_cpu=0;
 wire [1:0] cmd_valid={dma_valid&&dma_gate,cpu_valid};
 wire [1:0] cmd_write={dma_write,cpu_write};
 wire [1:0][31:0] cmd_addr={dma_addr,cpu_addr};
 wire [1:0][2:0] cmd_beats={dma_beats,cpu_beats};
 wire [1:0][127:0] cmd_wdata={dma_wdata,cpu_wdata};
 wire [1:0] cmd_ready,rsp_valid,rsp_error;
 wire [1:0][127:0] rsp_rdata;
 wire [1:0] rsp_ready={dma_rsp_ready,cpu_rsp_ready};
 reg [1:0] allow_r=3,allow_b=3;
 assign dma_ready=cmd_ready[1]&&dma_gate;
 wire [1:0][31:0] m_awaddr,m_wdata,m_araddr,m_rdata;
 wire [1:0][7:0] m_awlen,m_arlen;
 wire [1:0][2:0] m_awsize,m_arsize;
 wire [1:0][1:0] m_awburst,m_arburst,m_bresp,m_rresp;
 wire [1:0][3:0] m_wstrb;
 wire [1:0] m_awvalid,m_awready,m_wlast,m_wvalid,m_wready,m_bvalid,m_bready;
 wire [1:0] m_arvalid,m_arready,m_rlast,m_rvalid,m_rready;
 wire [1:0][31:0] s_awaddr,s_wdata,s_araddr,s_rdata;
 wire [1:0][7:0] s_awlen,s_arlen;
 wire [1:0][2:0] s_awsize,s_arsize;
 wire [1:0][1:0] s_awburst,s_arburst,s_bresp,s_rresp;
 wire [1:0][3:0] s_wstrb;
 wire [1:0] s_awvalid,s_awready,s_wlast,s_wvalid,s_wready,s_bvalid,s_bready;
 wire [1:0] s_arvalid,s_arready,s_rlast,s_rvalid,s_rready,s_decode_error;
 wire [1:0] reg_valid,reg_write,reg_ready,reg_error;
 wire [1:0][31:0] reg_addr,reg_wdata,reg_rdata;
 wire [1:0][3:0] reg_strb;
 wire active,owner,target,rr;
 reg stall_enable=1,inject_error=0;
 genvar g;
 generate for(g=0;g<2;g=g+1) begin: masters
  axi_master #(.AW_DELAY(g==0?0:7),.W_DELAY(g==0?9:0)) u_master (
   .clk(clk),.resetn(resetn),.cmd_valid(cmd_valid[g]),.cmd_write(cmd_write[g]),
   .cmd_addr(cmd_addr[g]),.cmd_beats(cmd_beats[g]),.cmd_wdata(cmd_wdata[g]),
   .cmd_ready(cmd_ready[g]),.rsp_valid(rsp_valid[g]),.rsp_ready(rsp_ready[g]),
   .rsp_rdata(rsp_rdata[g]),.rsp_error(rsp_error[g]),
   .awaddr(m_awaddr[g]),.awlen(m_awlen[g]),.awsize(m_awsize[g]),.awburst(m_awburst[g]),
   .awvalid(m_awvalid[g]),.awready(m_awready[g]),
   .wdata(m_wdata[g]),.wstrb(m_wstrb[g]),.wlast(m_wlast[g]),.wvalid(m_wvalid[g]),.wready(m_wready[g]),
   .bresp(m_bresp[g]),.bvalid(m_bvalid[g]),.bready(m_bready[g]),
   .araddr(m_araddr[g]),.arlen(m_arlen[g]),.arsize(m_arsize[g]),.arburst(m_arburst[g]),
   .arvalid(m_arvalid[g]),.arready(m_arready[g]),
   .rdata(m_rdata[g]),.rresp(m_rresp[g]),.rlast(m_rlast[g]),.rvalid(m_rvalid[g]),.rready(m_rready[g]),
   .allow_r(allow_r[g]),.allow_b(allow_b[g]));
 end endgenerate
 axi_interconnect fabric(.*);
 generate for(g=0;g<2;g=g+1) begin: slaves
  axi_slave #(.AW_ACCEPT_DELAY(g==0?4:0)) u_slave (
   .clk(clk),.resetn(resetn),.decode_error(s_decode_error[g]),
   .awaddr(s_awaddr[g]),.awlen(s_awlen[g]),.awsize(s_awsize[g]),.awburst(s_awburst[g]),
   .awvalid(s_awvalid[g]),.awready(s_awready[g]),
   .wdata(s_wdata[g]),.wstrb(s_wstrb[g]),.wlast(s_wlast[g]),.wvalid(s_wvalid[g]),.wready(s_wready[g]),
   .bresp(s_bresp[g]),.bvalid(s_bvalid[g]),.bready(s_bready[g]),
   .araddr(s_araddr[g]),.arlen(s_arlen[g]),.arsize(s_arsize[g]),.arburst(s_arburst[g]),
   .arvalid(s_arvalid[g]),.arready(s_arready[g]),
   .rdata(s_rdata[g]),.rresp(s_rresp[g]),.rlast(s_rlast[g]),.rvalid(s_rvalid[g]),.rready(s_rready[g]),
   .reg_valid(reg_valid[g]),.reg_write(reg_write[g]),.reg_addr(reg_addr[g]),.reg_wdata(reg_wdata[g]),
   .reg_strb(reg_strb[g]),.reg_ready(reg_ready[g]),.reg_rdata(reg_rdata[g]),.reg_error(reg_error[g]));
 end endgenerate
 axi_memory memory(.clk(clk),.resetn(resetn),.reg_valid(reg_valid[0]),.reg_write(reg_write[0]),
  .reg_addr(reg_addr[0]),.reg_wdata(reg_wdata[0]),.reg_strb(reg_strb[0]),
  .reg_ready(reg_ready[0]),.reg_rdata(reg_rdata[0]),.reg_error(reg_error[0]),
  .stall_enable(stall_enable),.inject_error(inject_error));
 uart_dma #(.CLKS_PER_BIT(CPB)) uart (
  .clk(clk),.resetn(resetn),.reg_valid(reg_valid[1]),.reg_write(reg_write[1]),
  .reg_addr(reg_addr[1]),.reg_wdata(reg_wdata[1]),.reg_strb(reg_strb[1]),
  .reg_ready(reg_ready[1]),.reg_rdata(reg_rdata[1]),.reg_error(reg_error[1]),
  .dma_cmd_valid(dma_valid),.dma_cmd_write(dma_write),.dma_cmd_addr(dma_addr),
  .dma_cmd_beats(dma_beats),.dma_cmd_wdata(dma_wdata),.dma_cmd_ready(dma_ready),
  .dma_rsp_valid(rsp_valid[1]),.dma_rsp_rdata(rsp_rdata[1]),.dma_rsp_error(rsp_error[1]),
  .dma_rsp_ready(dma_rsp_ready),.uart_rx(uart_rx),.uart_tx(uart_tx));
 integer checks=0,cycles=0,read_beats=0,write_beats=0,aw_first=0,w_first=0;
 integer r_stalls=0,b_stalls=0,w_stalls=0,ep_stalls=0,rr_contests=0;
 integer grants0=0,grants1=0,decerr_reads=0,decerr_writes=0,slverr_reads=0,slverr_writes=0;
 reg [1:0] aw_seen=0,w_seen=0;
 reg [1:0] prev_r_stall=0,prev_b_stall=0,prev_w_stall=0,prev_aw_stall=0;
 reg [1:0][31:0] saved_rdata,saved_wdata,saved_awaddr;
 reg [1:0][1:0] saved_rresp,saved_bresp;
 reg [1:0] saved_rlast,saved_wlast;
 reg contest_pending=0,expected_owner=0;
 integer k;
 task check(input condition,input string label_text);
 begin checks=checks+1;if(condition!==1'b1)$fatal(1,"AXI check failed: %s at %0t",label_text,$time);end
 endtask
 always @(posedge clk) if(resetn) begin
  cycles=cycles+1;
  if(contest_pending) begin check(active&&owner==expected_owner,"round robin contested winner");contest_pending=0;end
  if(!active && (&(m_awvalid|m_arvalid))) begin
   rr_contests=rr_contests+1;expected_owner=rr;contest_pending=1;
  end
  if(!active && |(m_awvalid|m_arvalid)) begin
   if(fabric.candidate)grants1=grants1+1;else grants0=grants0+1;
  end
  if(reg_valid[0]&&!reg_ready[0])ep_stalls=ep_stalls+1;
  for(k=0;k<2;k=k+1) begin
   if(prev_r_stall[k]) check(m_rvalid[k]&&m_rdata[k]===saved_rdata[k]&&
     m_rresp[k]===saved_rresp[k]&&m_rlast[k]===saved_rlast[k],"R payload stable under backpressure");
   if(prev_b_stall[k]) check(m_bvalid[k]&&m_bresp[k]===saved_bresp[k],"B stable under backpressure");
   if(prev_w_stall[k]) check(m_wvalid[k]&&m_wdata[k]===saved_wdata[k]&&m_wlast[k]===saved_wlast[k],"W stable under backpressure");
   if(prev_aw_stall[k]) check(m_awvalid[k]&&m_awaddr[k]===saved_awaddr[k],"AW stable under backpressure");
   prev_r_stall[k]=m_rvalid[k]&&!m_rready[k];saved_rdata[k]=m_rdata[k];saved_rresp[k]=m_rresp[k];saved_rlast[k]=m_rlast[k];
   prev_b_stall[k]=m_bvalid[k]&&!m_bready[k];saved_bresp[k]=m_bresp[k];
   prev_w_stall[k]=m_wvalid[k]&&!m_wready[k];saved_wdata[k]=m_wdata[k];saved_wlast[k]=m_wlast[k];
   prev_aw_stall[k]=m_awvalid[k]&&!m_awready[k];saved_awaddr[k]=m_awaddr[k];
   if(prev_r_stall[k])r_stalls=r_stalls+1;
   if(prev_b_stall[k])b_stalls=b_stalls+1;
   if(prev_w_stall[k])w_stalls=w_stalls+1;
   if(m_awvalid[k]&&m_awready[k]) begin
    if(!w_seen[k]&&!(m_wvalid[k]&&m_wready[k]))aw_first=aw_first+1;
    aw_seen[k]=1;
   end
   if(m_wvalid[k]&&m_wready[k]) begin
    if(!aw_seen[k])w_first=w_first+1;
    w_seen[k]=1;write_beats=write_beats+1;
   end
   if(m_bvalid[k]&&m_bready[k]) begin
    aw_seen[k]=0;w_seen[k]=0;
    if(m_bresp[k]==3)decerr_writes=decerr_writes+1;
    if(m_bresp[k]==2)slverr_writes=slverr_writes+1;
   end
   if(m_rvalid[k]&&m_rready[k])begin
    read_beats=read_beats+1;
    if(m_rresp[k]==3)decerr_reads=decerr_reads+1;
    if(m_rresp[k]==2)slverr_reads=slverr_reads+1;
   end
  end
 end
 task cpu_access(input wr,input [31:0] addr,input [2:0] beats,input [127:0] data,
                 input expected_error,output [127:0] result);
 begin
  @(negedge clk);while(!cmd_ready[0])@(negedge clk);
  cpu_valid=1;cpu_write=wr;cpu_addr=addr;cpu_beats=beats;cpu_wdata=data;
  if(release_dma_on_cpu)begin dma_gate=1;release_dma_on_cpu=0;end
  @(posedge clk);check(cmd_ready[0],"CPU command accepted");
  @(negedge clk);cpu_valid=0;
  while(!rsp_valid[0])@(negedge clk);
  check(rsp_error[0]===expected_error,"CPU error status");result=rsp_rdata[0];
  @(negedge clk);
 end
 endtask
 reg [127:0] scratch;
 task csr_write(input [31:0] offset,input [31:0] value);
 begin cpu_access(1,32'h40000000+offset,1,{96'b0,value},0,scratch);end
 endtask
 task wait_done(input expected_error);
 reg [127:0] value;integer attempts;
 begin
  value=0;attempts=0;
  while(!value[1]&&attempts<1000) begin
   cpu_access(0,32'h40000008,1,0,0,value);attempts=attempts+1;
  end
  check(value[1]&&!value[0],"DMA completion");check(value[2]===expected_error,"DMA sticky error");
 end
 endtask
 task expect_tx(input [7:0] expected);
 integer b;reg [7:0] value;
 begin
  @(negedge uart_tx);repeat(CPB/2)@(posedge clk);#1;check(!uart_tx,"UART start");
  for(b=0;b<8;b=b+1)begin repeat(CPB)@(posedge clk);#1;value[b]=uart_tx;end
  repeat(CPB)@(posedge clk);#1;check(uart_tx,"UART stop");check(value===expected,"UART transmitted byte");
  repeat(CPB/2)@(posedge clk);#1;
 end
 endtask
 task send_rx(input [7:0] value);
 integer b;
 begin
  @(negedge clk);uart_rx=0;repeat(CPB)@(negedge clk);
  for(b=0;b<8;b=b+1)begin uart_rx=value[b];repeat(CPB)@(negedge clk);end
  uart_rx=1;repeat(CPB)@(negedge clk);
 end
 endtask
 reg [127:0] result;
 integer i,before_reads,before_writes,before_grants;
 initial begin
  $dumpfile("tb_axi.vcd");$dumpvars(0,tb_axi);
  for(i=0;i<1024;i=i+1)memory.mem[i]=0;
  repeat(5)@(negedge clk);resetn=1;repeat(3)@(negedge clk);
  cpu_access(1,32'h100,4,128'h00000021000000310000005700000048,0,result);
  cpu_access(0,32'h100,4,0,0,result);
  check(result==128'h00000021000000310000005700000048,"four-beat read/write payload");
  $display("PASS AXI four-beat memory transfers with endpoint wait states");
  // R and B response backpressure, not merely local command backpressure.
  allow_r[0]=0;
  fork
   cpu_access(0,32'h100,4,0,0,result);
   begin wait(m_rvalid[0]);repeat(7)@(negedge clk);allow_r[0]=1;end
  join
  check(result==128'h00000021000000310000005700000048,"stalled read intact");
  allow_b[0]=0;
  fork
   cpu_access(1,32'h180,1,128'h89abcdef,0,result);
   begin wait(m_bvalid[0]);repeat(7)@(negedge clk);allow_b[0]=1;end
  join
  cpu_access(0,32'h180,1,0,0,result);check(result[31:0]==32'h89abcdef,"single-beat write/read");
  $display("PASS AXI independent AW/W and R/B backpressure stability");
  before_grants=grants0;
  cpu_access(0,32'h102,1,0,1,result);
  cpu_access(1,32'hffc,4,0,1,result);
  cpu_access(0,32'h100,2,0,1,result);
  check(grants0==before_grants,"invalid local commands never reach AXI bus");
  before_reads=read_beats;
  cpu_access(0,32'h80000000,4,0,1,result);
  check(read_beats==before_reads+4,"DECERR read drains four beats");
  before_writes=write_beats;
  cpu_access(1,32'h80000000,4,0,1,result);
  check(write_beats==before_writes+4,"DECERR write drains four beats before B");
  inject_error=1;before_reads=read_beats;
  cpu_access(0,32'h100,4,0,1,result);
  check(read_beats==before_reads+4,"SLVERR read completes full burst");
  cpu_access(1,32'h180,4,0,1,result);inject_error=0;
  cpu_access(0,32'h180,1,0,0,result);check(result[31:0]==32'h89abcdef,"failed write has no endpoint side effect");
  cpu_access(0,32'h40000020,1,0,1,result);
  before_reads=read_beats;
  cpu_access(0,32'h400000fc,4,0,1,result);
  check(read_beats==before_reads+4,"target-window crossing returns four DECERR beats");
  $display("PASS AXI invalid shape/4KB, full-burst DECERR and SLVERR");
  csr_write(32'h0c,32'h100);csr_write(32'h14,4);
  dma_gate=0;csr_write(32'h18,1);wait(dma_valid);
  fork
   begin expect_tx(8'h48);expect_tx(8'h57);expect_tx(8'h31);expect_tx(8'h21);end
   begin
    release_dma_on_cpu=1;cpu_access(0,32'h180,1,0,0,result);
    wait_done(0);
   end
  join
  $display("PASS AXI CPU/DMA simultaneous requests, round robin and UART TX HW1!");
  csr_write(32'h10,32'h200);csr_write(32'h18,3);
  fork
   begin send_rx(8'h52);send_rx(8'h58);send_rx(8'h34);send_rx(8'h21);end
   wait_done(0);
  join
  cpu_access(0,32'h200,4,0,0,result);
  check(result==128'h00000021000000340000005800000052,"UART RX4! DMA writeback");
  $display("PASS AXI UART RX4! DMA burst writeback with W handshake before AW");
  check(aw_first>0&&w_first>0,"both AW-before-W and W-before-AW handshakes tested");
  check(r_stalls>0&&b_stalls>0&&w_stalls>0&&ep_stalls>0,"actual backpressure exercised");
  check(rr_contests>0&&grants0>0&&grants1>0,"both masters served and contested RR verified");
  check(decerr_reads==8&&decerr_writes==1&&slverr_reads>=4&&slverr_writes>=1,"error response codes checked");
  $display("AXI ALL TESTS PASSED: assertions=%0d cycles=%0d Rbeats=%0d Wbeats=%0d AWfirst=%0d Wfirst=%0d contests=%0d grants=%0d/%0d",checks,cycles,read_beats,write_beats,aw_first,w_first,rr_contests,grants0,grants1);
  $display("AXI backpressure cycles: R=%0d B=%0d W=%0d endpoint=%0d",r_stalls,b_stalls,w_stalls,ep_stalls);
  $finish;
 end
 initial begin #1000000;$fatal(1,"AXI test timeout");end
endmodule
