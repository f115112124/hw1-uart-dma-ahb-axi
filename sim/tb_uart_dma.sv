`timescale 1ns/1ps
module tb_uart_dma;
    localparam integer CPB=8;
    reg clk=0;
    always #5 clk=~clk;
    reg resetn=0;
    reg reg_valid=0,reg_write=0;
    reg [31:0] reg_addr=0,reg_wdata=0;
    reg [3:0] reg_strb=4'hf;
    wire reg_ready,reg_error;
    wire [31:0] reg_rdata;
    wire cmd_valid,cmd_write;
    wire [31:0] cmd_addr;
    wire [2:0] cmd_beats;
    wire [127:0] cmd_wdata;
    wire cmd_ready;
    reg rsp_valid=0,rsp_error=0;
    reg [127:0] rsp_rdata=0;
    wire rsp_ready,uart_tx;
    reg uart_rx=1;
    uart_dma #(.CLKS_PER_BIT(CPB)) dut (
        .clk(clk),.resetn(resetn),.reg_valid(reg_valid),.reg_write(reg_write),
        .reg_addr(reg_addr),.reg_wdata(reg_wdata),.reg_strb(reg_strb),
        .reg_ready(reg_ready),.reg_rdata(reg_rdata),.reg_error(reg_error),
        .dma_cmd_valid(cmd_valid),.dma_cmd_write(cmd_write),.dma_cmd_addr(cmd_addr),
        .dma_cmd_beats(cmd_beats),.dma_cmd_wdata(cmd_wdata),.dma_cmd_ready(cmd_ready),
        .dma_rsp_valid(rsp_valid),.dma_rsp_rdata(rsp_rdata),
        .dma_rsp_error(rsp_error),.dma_rsp_ready(rsp_ready),
        .uart_rx(uart_rx),.uart_tx(uart_tx));

    reg [31:0] memory [0:1023];
    integer cycles=0,pending=0,delay_count=0,command_count=0;
    integer model_index;
    reg fail_next=0;
    reg last_write;
    reg [31:0] last_addr;
    reg [2:0] last_beats;
    reg [127:0] last_wdata;
    assign cmd_ready = resetn && !pending && !rsp_valid && cycles%5==0;
    always @(posedge clk) begin
        if (!resetn) begin
            cycles<=0; pending<=0; delay_count<=0; command_count<=0;
            rsp_valid<=0; rsp_error<=0; rsp_rdata<=0;
        end else begin
            cycles<=cycles+1;
            if (cmd_valid && cmd_ready) begin
                if (cmd_addr[1:0]!=0 || (cmd_beats!=1 && cmd_beats!=4))
                    $fatal(1,"Illegal DMA command escaped endpoint");
                pending<=1; delay_count<=11; command_count<=command_count+1;
                last_write<=cmd_write; last_addr<=cmd_addr;
                last_beats<=cmd_beats; last_wdata<=cmd_wdata;
                rsp_error<=fail_next; fail_next<=0;
                rsp_rdata<=0;
                for (model_index=0;model_index<4;model_index=model_index+1)
                    if (model_index<cmd_beats) begin
                        if (cmd_write && !fail_next)
                            memory[(cmd_addr>>2)+model_index]<=cmd_wdata[model_index*32 +: 32];
                        if (!cmd_write)
                            rsp_rdata[model_index*32 +: 32]<=memory[(cmd_addr>>2)+model_index];
                    end
            end
            if (pending && delay_count>0) begin
                delay_count<=delay_count-1;
                if (delay_count==1) rsp_valid<=1;
            end
            if (rsp_valid && rsp_ready) begin rsp_valid<=0; pending<=0; end
        end
    end

    integer checks=0;
    task check;
        input condition;
        input string text;
        begin
            checks=checks+1;
            if (condition!==1'b1) $fatal(1,"CHECK FAILED: %s at %0t",text,$time);
        end
    endtask
    task csr_write;
        input [31:0] offset,value;
        input expected_error;
        begin
            @(negedge clk);
            reg_valid=1; reg_write=1; reg_addr=32'h40000000+offset;
            reg_wdata=value; reg_strb=4'hf;
            @(posedge clk);
            check(reg_ready,"CSR ready");
            check(reg_error===expected_error,"CSR write error response");
            @(negedge clk); reg_valid=0;
        end
    endtask
    task csr_read;
        input [31:0] offset;
        input expected_error;
        output [31:0] value;
        begin
            @(negedge clk);
            reg_valid=1; reg_write=0; reg_addr=32'h40000000+offset;
            @(posedge clk);
            value=reg_rdata;
            check(reg_ready,"CSR ready");
            check(reg_error===expected_error,"CSR read error response");
            @(negedge clk); reg_valid=0;
        end
    endtask
    task wait_dma_done;
        input expected_error;
        reg [31:0] value;
        integer attempts;
        begin
            value=0; attempts=0;
            while (!value[1] && attempts<4000) begin
                csr_read(8'h08,0,value); attempts=attempts+1;
            end
            check(value[1] && !value[0],"DMA completes and clears busy");
            check(value[2]===expected_error,"DMA final error status");
        end
    endtask
    integer tx_frames=0;
    task expect_tx_byte;
        input [7:0] expected;
        integer b;
        reg [7:0] observed;
        begin
            @(negedge uart_tx);
            repeat(CPB/2) @(posedge clk);
            #1; check(uart_tx===0,"UART TX start bit");
            for (b=0;b<8;b=b+1) begin
                repeat(CPB) @(posedge clk);
                #1; observed[b]=uart_tx;
            end
            repeat(CPB) @(posedge clk);
            #1; check(uart_tx===1,"UART TX stop bit");
            check(observed===expected,"UART TX byte LSB-first");
            check(!dut.dma_done,"DMA TX cannot complete before entire final stop bit");
            repeat(CPB/2) @(posedge clk);
            #1; tx_frames=tx_frames+1;
        end
    endtask
    task send_rx_byte;
        input [7:0] value;
        integer b;
        begin
            @(negedge clk); uart_rx=0;
            repeat(CPB) @(negedge clk);
            for (b=0;b<8;b=b+1) begin
                uart_rx=value[b]; repeat(CPB) @(negedge clk);
            end
            uart_rx=1; repeat(CPB) @(negedge clk);
        end
    endtask

    reg [31:0] status_value;
    integer before_commands,i;
    initial begin
        $dumpfile("tb_uart_dma.vcd");
        $dumpvars(0,tb_uart_dma);
        for(i=0;i<1024;i=i+1) memory[i]=0;
        memory[64]=32'hDEAD0048;
        memory[65]=32'hBEEF0057;
        memory[66]=32'hCAFE0031;
        memory[67]=32'hBABE0021;
        memory[68]=32'h12340041;
        repeat(5) @(negedge clk); resetn=1;
        repeat(3) @(negedge clk);
        check(uart_tx===1,"UART idle high after reset");
        csr_read(8'h04,1,status_value);
        csr_read(8'h20,1,status_value);
        csr_read(8'h09,1,status_value);
        csr_write(32'h100,32'h55,1);
        csr_write(32'h10c,32'habcd,1);
        csr_read(8'h0c,0,status_value);
        check(status_value==0,"Unimplemented AHB-slot offsets cannot alias implemented CSR");
        csr_write(8'h08,32'hffffffff,1);
        csr_write(8'h14,2,1);
        csr_read(8'h14,0,status_value);
        check(status_value==4,"Illegal LEN leaves old LEN unchanged");
        csr_write(8'h0c,32'h00000ffc,0);
        csr_write(8'h18,1,1);
        csr_write(8'h0c,32'h00000102,0);
        csr_write(8'h18,1,1);
        csr_read(8'h08,0,status_value);
        check(!status_value[0] && command_count==0,"Invalid START emits no DMA command");
        $display("PASS: bad CSR, alignment, invalid LEN and invalid START");

        csr_write(8'h0c,32'h100,0);
        before_commands=command_count;
        fork
            begin
                expect_tx_byte(8'h48); expect_tx_byte(8'h57);
                expect_tx_byte(8'h31); expect_tx_byte(8'h21);
            end
            begin
                csr_write(8'h18,1,0);
                csr_write(8'h18,1,1);
                csr_write(8'h0c,32'h300,1);
                wait_dma_done(0);
            end
        join
        check(command_count==before_commands+1,"TX uses one DMA burst command");
        check(!last_write && last_addr==32'h100 && last_beats==4,"TX DMA command fields");
        check(tx_frames==4,"All HW1! bytes serialized");
        $display("PASS: DMA TX4 reads words and serializes HW1! including stop bits");

        csr_write(8'h10,32'h200,0);
        before_commands=command_count;
        fork
            begin
                csr_write(8'h18,3,0);
                csr_read(8'h04,1,status_value);
                wait_dma_done(0);
            end
            begin
                repeat(10) @(negedge clk);
                send_rx_byte(8'h52); send_rx_byte(8'h58);
                send_rx_byte(8'h34); send_rx_byte(8'h21);
            end
        join
        check(command_count==before_commands+1,"RX uses one DMA burst command");
        check(last_write && last_addr==32'h200 && last_beats==4,"RX DMA command fields");
        check(last_wdata==128'h00000021000000340000005800000052,"RX packs byte per 32-bit word");
        check(memory[128]==32'h52 && memory[129]==32'h58 &&
              memory[130]==32'h34 && memory[131]==32'h21,"RX4 memory data");
        $display("PASS: UART RX4 collects RX4! and writes four words after command backpressure");

        send_rx_byte(8'h61); send_rx_byte(8'h62);
        send_rx_byte(8'h63); send_rx_byte(8'h64);
        repeat(10) @(negedge clk);
        csr_read(8'h08,0,status_value);
        check(status_value[7:4]==4,"RX FIFO retains four bytes before DMA START");
        csr_write(8'h10,32'h240,0);
        csr_write(8'h18,3,0);
        wait_dma_done(0);
        check(memory[144]==32'h61 && memory[147]==32'h64,"RX DMA drains prefilled FIFO");
        $display("PASS: RX FIFO buffers before START and drains in arrival order");

        csr_write(8'h14,1,0);
        csr_write(8'h0c,32'h110,0);
        fork
            expect_tx_byte(8'h41);
            begin csr_write(8'h18,1,0); wait_dma_done(0); end
        join
        check(last_beats==1 && tx_frames==5,"Single-word TX supported");
        $display("PASS: DMA TX single-word command");

        fail_next=1;
        csr_write(8'h18,1,0);
        wait_dma_done(1);
        check(uart_tx===1 && !dut.tx_busy,"Failed memory read does not serialize stale data");
        check(tx_frames==5,"No unexpected TX frame on DMA error");
        $display("PASS: DMA read response error terminates with sticky error");

        send_rx_byte(8'h7a);
        repeat(10) @(negedge clk);
        fail_next=1;
        csr_write(8'h10,32'h280,0);
        csr_write(8'h18,3,0);
        wait_dma_done(1);
        check(memory[160]==0,"Failed DMA write is not committed by response model");
        $display("PASS: DMA write response error propagates to STATUS");
        $display("UART_DMA ALL TESTS PASSED (%0d assertions, %0d commands, %0d UART TX frames)",
                 checks,command_count,tx_frames);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"UART DMA test timeout");
    end
endmodule
