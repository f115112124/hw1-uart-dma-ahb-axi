# HW1：UART＋DMA 的 AHB／AXI4 介面設計

先開啟 [完整作業 PDF](HW1_report.pdf)。需要修改文字時，使用 [報告 Markdown 版](docs/HW1_report.md)。

本專案包含作業的兩題，以及 RTL／模擬加分項。圖稿、報告、原始碼與實際測試紀錄均保留在下方資料夾。

## 這個範例在做什麼

CPU 設定 UART＋DMA 的暫存器後，DMA 自動搬移資料。提供相同功能的 AHB、AXI4 兩個版本：

- 傳送：DMA 從記憶體讀取四個 word，再由 UART 逐字元送出 `HW1!`。
- 接收：UART 收到 `RX4!`，DMA 將四個 byte 寫回四個記憶體 word。

每個 32-bit word 的低 8 bits 放一個字元，其餘 bits 為 0。此教學資料格式不做四個 byte 合併成一個 word。

![系統架構](diagrams/01_architecture.svg)

CPU 與 DMA 是兩個 Master；記憶體控制器與 IP 控制暫存器是兩個 Slave。CPU 以測試平台的 bus-functional model（BFM）產生要求，並非完整處理器 RTL。

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

FSM 圖保留可編輯的 `.dot` 原稿，MSC 保留 `.mmd` Mermaid 原稿。SVG 可放大檢視，適合放入報告。

## 執行模擬

需要 Python 3 和 Icarus Verilog（`iverilog`、`vvp`）。在這個資料夾執行：

```text
python sim/run_all.py
```

Windows 若沒有將模擬器放入 PATH，可設定：

```powershell
$env:IVERILOG = 'C:\iverilog\bin\iverilog.exe'
$env:VVP = 'C:\iverilog\bin\vvp.exe'
python sim/run_all.py
```

程式會編譯並執行 `tb_uart_dma`、`tb_ahb`、`tb_axi`。失敗會回傳非零結束碼，細節保存在 `results/`：

- `tb_*.log`：各測試平台的實際輸出。
- `tb_*_compile.log`：編譯訊息。
- `tb_*.vcd`：完整波形，可用 GTKWave 開啟。
- `summary.json`：執行時間、成功／失敗、模擬器版本、原始碼 SHA-256。
- `build/`：重新產生的模擬執行檔，可忽略，不是原始碼。

要從 VCD 更新波形預覽，可執行 `python sim/plot_vcd.py`。這個步驟只需 Python 標準函式庫，不影響 RTL 測試結果。

## 介面與設計說明

- [共同介面契約](docs/interface_contract.md)
- [AHB 設計與測試](docs/ahb_notes.md)
- [AXI4 設計與測試](docs/axi_notes.md)
- [UART＋DMA 核心設計與測試](docs/uart_notes.md)

記憶體位址為 `0x00000000` 至 `0x00000FFF`，UART＋DMA 已實作暫存器範圍為 `0x40000000` 至 `0x400000FF`。AHB 的 IP 解碼配置為 1 KiB，其中未實作 offset 回覆 ERROR；AXI 的 IP 配置為 256 bytes。

## 範圍

這是自撰的課堂教學實作，使用固定 32-bit、對齊、1／4-beat 交易。一次只路由一筆交易，在交易邊界做 round-robin 仲裁。AHB 不含 SPLIT／RETRY／LOCK；AXI 不含 WRAP、窄傳輸、非對齊、多筆 outstanding 和 out-of-order。RAM endpoint 為簡化記憶體控制器，不含外部 DRAM PHY。

UART 為固定參數 8N1，沒有 parity、流量控制、中斷與可程式化 baud rate。RX FIFO 深度為 8 bytes；DMA RX 等待接收足夠 byte 後才搬移。這份 RTL 未做 FPGA 板級驗證或正式協定相容性認證。

## 參考資料

- [Arm AMBA Specification Rev 2.0 / IHI 0011A](https://documentation-service.arm.com/static/5f916403f86e16515cdc3d71)
- [Arm AMBA AXI and ACE Protocol Specification / IHI 0022H](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)
- [OpenCores UART16550](https://opencores.org/projects/uart16550)：UART IP 類型參考。本作業沒有使用其 RTL，也不宣稱 16550 暫存器相容。
- [Icarus Verilog 官方文件](https://steveicarus.github.io/iverilog/)

照片沒有明訂協定版本、圖數或全部選配功能；本範例已明列版本與子集，供依課堂要求檢視和調整。
