`timescale 1ns/1ps
module tb_ahb;
 reg clk=0; always #5 clk=~clk;
 reg resetn=0;
 reg cp_valid=0,cp_write=0,cp_rsp_ready=0;
 reg [31:0] cp_addr=0;reg [2:0]cp_beats=1;reg[127:0]cp_wdata=0;
 wire d_valid,d_write,d_ready,d_rsp_valid,d_rsp_ready,d_rsp_error;
 wire[31:0]d_addr;wire[2:0]d_beats;wire[127:0]d_wdata,d_rdata;
 wire[1:0]cmd_ready,rsp_valid,rsp_error,req,grant;
 wire[255:0]rsp_data;
 wire[1:0]cmd_valid={d_valid,cp_valid},cmd_write={d_write,cp_write};
 wire[1:0]rsp_ready={d_rsp_ready,cp_rsp_ready};
 wire[63:0]cmd_addr={d_addr,cp_addr};wire[5:0]cmd_beats={d_beats,cp_beats};
 wire[255:0]cmd_wdata={d_wdata,cp_wdata};
 wire[63:0]ma,mwd;wire[3:0]mt;wire[5:0]ms,mb;wire[1:0]mw;
 wire[31:0]ha,hwd,hrd;wire[1:0]ht,hsel,hresp;
 wire[2:0]hs,hb;wire hw,hready,owner,active;
 wire[1:0]sready;wire[3:0]sresp;wire[63:0]srdata;
 wire[1:0]rv,rw,rrdy,rerr;wire[63:0]ra,rwd,rrd;wire[7:0]rs;
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:masters
   ahb_master master(.clk(clk),.resetn(resetn),.cmd_valid(cmd_valid[g]),
    .cmd_write(cmd_write[g]),.cmd_addr(cmd_addr[g*32 +:32]),
    .cmd_beats(cmd_beats[g*3 +:3]),.cmd_wdata(cmd_wdata[g*128 +:128]),
    .cmd_ready(cmd_ready[g]),.rsp_valid(rsp_valid[g]),.rsp_rdata(rsp_data[g*128 +:128]),
    .rsp_error(rsp_error[g]),.rsp_ready(rsp_ready[g]),
    .HBUSREQ(req[g]),.HGRANT(grant[g]),.HADDR(ma[g*32 +:32]),
    .HTRANS(mt[g*2 +:2]),.HBURST(mb[g*3 +:3]),.HSIZE(ms[g*3 +:3]),
    .HWRITE(mw[g]),.HWDATA(mwd[g*32 +:32]),.HREADY(hready),.HRESP(hresp),.HRDATA(hrd));
 end endgenerate
 ahb_interconnect bus(.clk(clk),.resetn(resetn),.m_req(req),.m_grant(grant),
   .m_addr(ma),.m_wdata(mwd),.m_trans(mt),.m_size(ms),.m_burst(mb),.m_write(mw),
   .HADDR(ha),.HWDATA(hwd),.HTRANS(ht),.HSIZE(hs),.HBURST(hb),.HWRITE(hw),.HSEL(hsel),
   .s_ready(sready),.s_resp(sresp),.s_rdata(srdata),.HREADY(hready),.HRESP(hresp),
   .HRDATA(hrd),.bus_owner(owner),.bus_active(active));
 generate for(g=0;g<2;g=g+1)begin:slaves
   ahb_slave slave(.clk(clk),.resetn(resetn),.HSEL(hsel[g]),.HREADY(hready),
    .HADDR(ha),.HWDATA(hwd),.HTRANS(ht),.HSIZE(hs),.HWRITE(hw),
    .HREADYOUT(sready[g]),.HRESP(sresp[g*2 +:2]),.HRDATA(srdata[g*32 +:32]),
    .reg_valid(rv[g]),.reg_write(rw[g]),.reg_addr(ra[g*32 +:32]),
    .reg_wdata(rwd[g*32 +:32]),.reg_strb(rs[g*4 +:4]),
    .reg_ready(rrdy[g]),.reg_rdata(rrd[g*32 +:32]),.reg_error(rerr[g]));
 end endgenerate
 ahb_memory #(.WAIT_CYCLES(2)) memory(.clk(clk),.resetn(resetn),
   .reg_valid(rv[0]),.reg_write(rw[0]),.reg_addr(ra[31:0]),.reg_wdata(rwd[31:0]),
   .reg_strb(rs[3:0]),.reg_ready(rrdy[0]),.reg_rdata(rrd[31:0]),.reg_error(rerr[0]));
 reg uart_rx=1;wire uart_tx;wire uart_err;
 // AHB selects a full 1 KiB slot. Only the first 256 bytes are the CSR window.
 wire uart_window=ra[41:40]==0;
 assign rerr[1]=uart_err || !uart_window;
 uart_dma #(.CLKS_PER_BIT(8)) uart(.clk(clk),.resetn(resetn),
   .reg_valid(rv[1] && uart_window),.reg_write(rw[1]),.reg_addr(ra[63:32]),
   .reg_wdata(rwd[63:32]),.reg_strb(rs[7:4]),.reg_ready(rrdy[1]),
   .reg_rdata(rrd[63:32]),.reg_error(uart_err),
   .dma_cmd_valid(d_valid),.dma_cmd_write(d_write),.dma_cmd_addr(d_addr),
   .dma_cmd_beats(d_beats),.dma_cmd_wdata(d_wdata),.dma_cmd_ready(d_ready),
   .dma_rsp_valid(d_rsp_valid),.dma_rsp_rdata(d_rdata),.dma_rsp_error(d_rsp_error),
   .dma_rsp_ready(d_rsp_ready),.uart_rx(uart_rx),.uart_tx(uart_tx));
 assign d_ready=cmd_ready[1];assign d_rsp_valid=rsp_valid[1];
 assign d_rdata=rsp_data[255:128];assign d_rsp_error=rsp_error[1];

 integer waits=0,errors=0,busy_cycles=0,conflicts=0,completed[0:1];
 integer accepted=0,mem_commits=0,csr_commits=0;
 integer burst_count=0,burst_expected=0,burst_total=0;
 reg[31:0]burst_next;reg burst_write;
 reg err_first=0,prev_wait=0,prev_err=0;
 reg[31:0] held_addr,held_wdata;reg[1:0]held_trans;reg[2:0]held_burst;
 reg held_write;
 always @(posedge clk) if(resetn)begin
   if(req==3)conflicts=conflicts+1;
   if(!hready)waits=waits+1;
   if(ht==1 && hready)busy_cycles=busy_cycles+1;
   if(hready && ht[1])begin
     accepted=accepted+1;
     if(hs!=2)$fatal(1,"AHB transfer was not 32-bit");
     if(ht==2)begin
       if(burst_count!=0)$fatal(1,"AHB NONSEQ interrupted fixed burst");
       if(hb!=0 && hb!=3)$fatal(1,"AHB unsupported burst encoding");
       burst_expected=hb==3?4:1;burst_count=1;burst_next=ha+4;burst_write=hw;
       if(burst_expected==4)begin
         burst_total=burst_total+1;
         if(ha[9:0]>1008)$fatal(1,"AHB INCR4 crossed 1 KiB");
       end
     end else begin
       if(burst_count==0 || hb!=3 || ha!==burst_next || hw!==burst_write)
          $fatal(1,"AHB SEQ burst address/control mismatch");
       burst_count=burst_count+1;burst_next=burst_next+4;
     end
     if(burst_count==burst_expected)burst_count=0;
   end
   if(hready && ht==1 && burst_count==0)$fatal(1,"AHB fixed burst ended with BUSY");
   if(rv[0] && rrdy[0])mem_commits=mem_commits+1;
   if(rv[1] && rrdy[1])csr_commits=csr_commits+1;
   if(rsp_valid[0]&&rsp_ready[0])completed[0]=completed[0]+1;
   if(rsp_valid[1]&&rsp_ready[1])completed[1]=completed[1]+1;
   if(hresp==1 && !hready)begin
     if(err_first)$fatal(1,"AHB ERROR first phase exceeded one cycle");
     err_first=1;
   end else if(hresp==1 && hready)begin
     if(!err_first)$fatal(1,"AHB ERROR missing first phase");
     err_first=0;errors=errors+1;burst_count=0;
   end else if(err_first)$fatal(1,"AHB ERROR response was not two cycles");
   if(prev_wait && !prev_err) begin
     if(ha!==held_addr || ht!==held_trans || hb!==held_burst || hw!==held_write)
       $fatal(1,"AHB address/control changed during normal wait");
     if(held_write && hwd!==held_wdata)$fatal(1,"AHB write data changed during wait");
   end
   prev_wait=!hready;prev_err=hresp==1;
   held_addr=ha;held_trans=ht;held_burst=hb;held_write=hw;held_wdata=hwd;
 end
 task automatic command(input bit wr,input[31:0]addr,input[2:0]beats,
   input[127:0]data,input bit expect_error,output[127:0]result);
   reg[127:0]held;reg held_error;integer n;
   begin
     @(negedge clk);cp_valid=1;cp_write=wr;cp_addr=addr;cp_beats=beats;cp_wdata=data;
     while(!cmd_ready[0])@(negedge clk);
     @(negedge clk);cp_valid=0;n=0;
     while(!rsp_valid[0])begin @(negedge clk);n=n+1;if(n>2000)$fatal(1,"CPU command timeout");end
     result=rsp_data[127:0];held=result;held_error=rsp_error[0];
     repeat(3)begin @(negedge clk);
       if(!rsp_valid[0]||rsp_data[127:0]!==held||rsp_error[0]!==held_error)
          $fatal(1,"AHB local response changed under backpressure");
     end
     if(rsp_error[0]!==expect_error)$fatal(1,"AHB unexpected error at address %h",addr);
     cp_rsp_ready=1;@(negedge clk);cp_rsp_ready=0;
   end
 endtask
 reg[127:0]result;
 task automatic write_reg(input[31:0]addr,input[31:0]data);
   reg[127:0]discard;begin command(1,addr,1,{96'b0,data},0,discard);end
 endtask
 task automatic wait_done;
   integer n;reg[127:0]status;
   begin n=0;status=0;
     while(!status[1])begin
       command(0,32'h40000008,1,0,0,status);n=n+1;
       if(n>200)$fatal(1,"UART DMA done timeout");
     end
     if(status[2])$fatal(1,"UART DMA status error");
   end
 endtask
 task automatic serial_send(input[7:0]value);
   integer j;begin
     @(negedge clk);uart_rx=0;repeat(8)@(negedge clk);
     for(j=0;j<8;j=j+1)begin uart_rx=value[j];repeat(8)@(negedge clk);end
     uart_rx=1;repeat(10)@(negedge clk);
   end
 endtask
 reg[7:0]serial_bytes[0:7];integer serial_count=0;reg[7:0]serial_value;integer k;
 initial forever begin
   @(negedge uart_tx);
   if(resetn)begin
     repeat(4)@(posedge clk);if(uart_tx!==0)$fatal(1,"UART bad start bit");
     for(k=0;k<8;k=k+1)begin repeat(8)@(posedge clk);serial_value[k]=uart_tx;end
     repeat(8)@(posedge clk);if(uart_tx!==1)$fatal(1,"UART bad stop bit");
     serial_bytes[serial_count]=serial_value;serial_count=serial_count+1;
   end
 end
 integer before_addr,before_mem,i;
 initial begin
   $dumpfile("tb_ahb.vcd");$dumpvars(0,tb_ahb);
   completed[0]=0;completed[1]=0;
   repeat(5)@(negedge clk);resetn=1;
   command(1,32'h100,4,{32'h21,32'h31,32'h57,32'h48},0,result);
   command(0,32'h100,4,0,0,result);
   if(result!=={32'h21,32'h31,32'h57,32'h48})$fatal(1,"AHB INCR4 memory mismatch");
   $display("CHECK AHB INCR4 write/read, waits, local response backpressure");
   write_reg(32'h4000000c,32'h100);write_reg(32'h40000014,4);
   write_reg(32'h40000018,1);
   command(1,32'h200,4,{32'hdddd,32'hcccc,32'hbbbb,32'haaaa},0,result);
   wait_done();
   if(serial_count!=4 || serial_bytes[0]!="H" || serial_bytes[1]!="W" ||
      serial_bytes[2]!="1" || serial_bytes[3]!="!")$fatal(1,"UART TX expected HW1!");
   $display("CHECK AHB DMA TX serial bytes HW1!; CPU and DMA share bus");
   write_reg(32'h40000010,32'h300);write_reg(32'h40000018,3);
   fork
     begin serial_send("R");serial_send("X");serial_send("4");serial_send("!");end
     begin repeat(35)command(0,32'h200,4,0,0,result);end
   join
   wait_done();command(0,32'h300,4,0,0,result);
   if(result!=={32'h21,32'h34,32'h58,32'h52})$fatal(1,"UART RX expected RX4!");
   $display("CHECK AHB DMA RX serial bytes RX4! written to memory");
   command(0,32'h80000000,1,0,1,result);
   command(0,32'h400000fc,1,0,1,result);
   command(1,32'h40000008,1,32'hffff,1,result);
   command(0,32'h40000100,1,0,1,result);
   before_addr=accepted;
   command(0,32'h40000018,4,0,1,result);
   if(accepted-before_addr!=2)$fatal(1,"AHB did not abort burst after second-beat ERROR");
   before_addr=accepted;before_mem=mem_commits;
   command(0,32'h102,1,0,1,result);
   command(0,32'h3f8,4,0,1,result);
   command(0,32'h100,2,0,1,result);
   if(accepted!=before_addr||mem_commits!=before_mem)$fatal(1,"Malformed command reached AHB bus");
   command(1,32'h3f0,4,{32'h4,32'h3,32'h2,32'h1},0,result);
   command(0,32'h3f0,4,0,0,result);
   if(result!=={32'h4,32'h3,32'h2,32'h1})$fatal(1,"AHB boundary legal burst mismatch");
   $display("CHECK AHB unmapped/reserved/readonly ERROR, malformed shape, 1 KiB boundaries");
   if(waits<10||busy_cycles<6||errors!=5||completed[1]!=2||conflicts==0||burst_total<10)
     $fatal(1,"AHB coverage missing waits=%0d busy=%0d errors=%0d dma=%0d conflicts=%0d",waits,busy_cycles,errors,completed[1],conflicts);
   if(mem_commits+csr_commits+1!=accepted)$fatal(1,"AHB endpoint commit count mismatch");
   $display("PASS tb_ahb: waits=%0d BUSY=%0d bursts=%0d errors=%0d contention_cycles=%0d CPU=%0d DMA=%0d accepted=%0d",waits,busy_cycles,burst_total,errors,conflicts,completed[0],completed[1],accepted);
   #30;$finish;
 end
 initial begin #2000000;$fatal(1,"AHB test global timeout");end
endmodule
