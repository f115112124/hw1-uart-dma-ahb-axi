# Shared RTL interface contract

All modules use `clk` and synchronous active-low `resetn`. Rising-edge transfers.

## Master wrapper local command interface

Inputs: `cmd_valid`, `cmd_write`, `cmd_addr[31:0]`, `cmd_beats[2:0]`, `cmd_wdata[127:0]`.
Output: `cmd_ready`. Accept only on `cmd_valid && cmd_ready`.
Supported beat counts are 1 and 4; each beat is a 32-bit aligned word, address increments by 4.
Word zero is bits [31:0], word one [63:32], and so on.
Outputs: `rsp_valid`, `rsp_rdata[127:0]`, `rsp_error`; input: `rsp_ready`.
Hold response stable while `rsp_valid && !rsp_ready`. One command outstanding per wrapper.
Wrappers must reject invalid local command shape/boundary without emitting an illegal bus request.

## Slave wrapper endpoint interface

Outputs: `reg_valid`, `reg_write`, `reg_addr[31:0]`, `reg_wdata[31:0]`, `reg_strb[3:0]`.
Inputs: `reg_ready`, `reg_rdata[31:0]`, `reg_error`.
Endpoint operation commits exactly once on `reg_valid && reg_ready` at the clock edge.
Read data and error are valid in that handshake. Endpoint can stall by deasserting ready.
Bus byte addresses are retained; UART core uses reg_addr[7:0].

## uart_dma module

Parameter: `CLKS_PER_BIT=8` (accelerated simulation UART 8N1).
Endpoint inputs: `reg_valid`, `reg_write`, `reg_addr[31:0]`, `reg_wdata[31:0]`, `reg_strb[3:0]`.
Endpoint outputs: `reg_ready`, `reg_rdata[31:0]`, `reg_error`.
DMA outputs: `dma_cmd_valid`, `dma_cmd_write`, `dma_cmd_addr[31:0]`, `dma_cmd_beats[2:0]`, `dma_cmd_wdata[127:0]`.
DMA input: `dma_cmd_ready`.
DMA inputs: `dma_rsp_valid`, `dma_rsp_rdata[127:0]`, `dma_rsp_error`; output: `dma_rsp_ready`.
UART input `uart_rx`; output `uart_tx`.

Address map: memory 0x00000000-0x00000FFF, UART/DMA registers 0x40000000-0x400000FF.
Register offsets: TXDATA=0x00 (write low byte), RXDATA=0x04 (read/pop), STATUS=0x08,
DMA_SRC=0x0C, DMA_DST=0x10, DMA_LEN=0x14 (1 or 4 words), DMA_CTRL=0x18.
CTRL bit0 START, bit1 direction (0 memory-to-UART TX, 1 UART RX-to-memory).
STATUS bit0 DMA busy, bit1 DMA done, bit2 error, bit3 UART TX busy, bits7:4 RX FIFO count.
Done/error clear on a new accepted START. Each memory word carries one UART byte in bits7:0.
DMA TX done means all bytes have been serialized, including stop bits. DMA RX done means bus write response received.
UART RX FIFO minimum depth 4. No UART flow control, parity, or configurable baud in this teaching implementation.

## Integration and tests

Each protocol testbench instantiates TWO master wrappers (CPU BFM + uart_dma) and TWO slave wrappers
(4 KiB memory endpoint + uart_dma register endpoint). Interconnect arbitrates whole transactions.
CPU is a testbench bus-functional model, not a processor core. AHB has explicit request/grant.
AXI supports fixed per-master IDs or a single outstanding routed transaction with ID tied to 0.
Shared bus serializes at most one transaction at a time; fairness should be round robin at transaction boundaries.
Exercise CPU memory access while DMA requests bus ownership, full duplex directions in separate runs,
four-beat reads/writes, slave wait/backpressure, and malformed/unmapped accesses.
