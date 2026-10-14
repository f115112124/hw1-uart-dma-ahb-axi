# HW1：UART＋DMA 的 AHB／AXI4 介面設計

可以先看 [完整作業 PDF](HW1_report.pdf)。如果要修改文字，可以用 [報告 Markdown 版](docs/HW1_report.md)。

這裡整理了 HW1 的兩題，以及 RTL 和模擬的加分內容。圖稿、報告、原始碼和測試紀錄都放在這個資料夾裡。

## 這個範例在做什麼

CPU 先設定 UART＋DMA 的暫存器，再讓 DMA 自動搬移資料。這個範例有 AHB 和 AXI4 兩個版本，做的事情相同：

- 傳送：DMA 從記憶體讀取四個 word，再由 UART 逐字元送出 `HW1!`。
- 接收：UART 收到 `RX4!`，DMA 將四個 byte 寫回四個記憶體 word。

每個 32-bit word 的低 8 bits 放一個字元，其餘 bits 都是 0。為了讓資料比較好看懂，這裡每個 word 只放一個字元，沒有把四個 byte 合併成一個 word。

![系統架構](diagrams/01_architecture.svg)

CPU 和 DMA 是兩個 Master；記憶體控制器和 IP 控制暫存器是兩個 Slave。模擬中的 CPU 用測試平台的 bus-functional model（BFM）送出讀寫要求，沒有實作完整的處理器 RTL。

## 作業內容對照

| 要求 | 對應檔案 |
| --- | --- |
| AHB Master wrapper FSM | `diagrams/03_ahb_master.svg`、`rtl/ahb_master.sv` |
| AHB Slave wrapper FSM | `diagrams/04_ahb_slave.svg`、`rtl/ahb_slave.sv` |
| AXI Master wrapper FSM | `diagrams/05_axi_master.svg`、`rtl/axi_master.sv` |
| AXI Slave wrapper FSM | `diagrams/06_axi_slave.svg`、`rtl/axi_slave.sv` |
| 多 Master、多 Slave | 架構圖、兩種 interconnect、各整合測試平台 |
| burst | AHB INCR4、AXI4 INCR，四筆 32-bit word |
| AHB Message Sequence Chart | `diagrams/08_ahb_tx.svg`、`diagrams/09_ahb_rx.svg` |
| AXI Message Sequence Chart | `diagrams/10_axi_tx.svg`、`diagrams/11_axi_rx.svg` |
| 加分 RTL／simulation | `rtl/`、`sim/`、`results/` |

FSM 圖有可編輯的 `.dot` 原稿，MSC 則有 `.mmd` Mermaid 原稿。SVG 圖片可以放大看，也可以放進報告。

## 執行模擬

先安裝 Python 3 和 Icarus Verilog（`iverilog`、`vvp`），再到這個資料夾執行：

```text
python sim/run_all.py
```

Windows 如果找不到模擬器，可以先設定它的路徑：

```powershell
$env:IVERILOG = 'C:\iverilog\bin\iverilog.exe'
$env:VVP = 'C:\iverilog\bin\vvp.exe'
python sim/run_all.py
```

程式會編譯並執行 `tb_uart_dma`、`tb_ahb`、`tb_axi` 這三組測試。如果測試失敗，程式會回傳非零結束碼。詳細結果會放在 `results/`：

- `tb_*.log`：每組測試的實際輸出。
- `tb_*_compile.log`：編譯訊息。
- `tb_*.vcd`：完整波形，可用 GTKWave 開啟。
- `summary.json`：執行時間、成功／失敗、模擬器版本、原始碼 SHA-256。
- `build/`：模擬時產生的執行檔，下次執行會重新產生，不需要當成原始碼保存。

如果要用 VCD 更新波形預覽，可以執行 `python sim/plot_vcd.py`。這個步驟只用到 Python 標準函式庫，不會改變 RTL 測試結果。

## 介面與設計說明

- [模組之間怎麼接](docs/interface_contract.md)
- [AHB 設計與測試](docs/ahb_notes.md)
- [AXI4 設計與測試](docs/axi_notes.md)
- [UART＋DMA 核心設計與測試](docs/uart_notes.md)

記憶體使用 `0x00000000` 到 `0x00000FFF`，UART＋DMA 的暫存器使用 `0x40000000` 到 `0x400000FF`。AHB 會把 1 KiB 的位址範圍分配給這個 IP；如果存取的 offset 沒有對應的暫存器，就回覆 ERROR。AXI 分配給這個 IP 的範圍則是 256 bytes。

## 這個範例支援到哪裡

這是供課堂使用的範例，資料寬度固定為 32-bit，位址需要對齊，每筆交易傳 1 或 4 個 beat。匯流排一次處理一筆交易，完成後用 round-robin 決定下一個由哪個 Master 使用。AHB 沒有加入 SPLIT／RETRY／LOCK；AXI 沒有加入 WRAP、窄傳輸、非對齊、多筆 outstanding 和 out-of-order。記憶體控制器也做了簡化，使用 RAM 模型，沒有外部 DRAM PHY。

UART 固定使用 8N1，沒有 parity、流量控制或中斷，baud rate 也不能透過暫存器調整。RX FIFO 可以放 8 bytes；DMA 接收時會先等足夠的 byte 收齊，再開始搬移。這份 RTL 做了模擬測試，還沒有放到 FPGA 板上驗證，也沒有經過正式的協定相容性認證。

## 參考資料

- [Arm AMBA Specification Rev 2.0 / IHI 0011A](https://documentation-service.arm.com/static/5f916403f86e16515cdc3d71)
- [Arm AMBA AXI and ACE Protocol Specification / IHI 0022H](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)
- [OpenCores UART16550](https://opencores.org/projects/uart16550)：用來參考 UART IP 的類型。這份作業沒有使用它的 RTL，暫存器設計也沒有做成與 16550 相容。
- [Icarus Verilog 官方文件](https://steveicarus.github.io/iverilog/)

作業照片沒有寫明協定版本、圖的張數或需要哪些選配功能，所以這裡把採用的版本和支援範圍列出來，方便對照課堂要求調整。
