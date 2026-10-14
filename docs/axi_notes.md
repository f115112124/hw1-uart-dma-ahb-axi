# AXI4：設計、狀態機與測試說明

這份說明對應 `rtl/axi_master.sv`、`axi_slave.sv`、`axi_interconnect.sv`、`axi_memory.sv` 與 `sim/tb_axi.sv`，可以搭配程式一起看。

## 這次做的功能

- 32-bit 資料、4-byte 對齊；每次命令為 1 或 4 個 word。
- 使用 AXI4 INCR：`AxBURST=01`、`AxSIZE=2`、`AxLEN=0/3`。AXI 的單筆傳輸用 LEN=0 表示，AXI BURST 編碼裡沒有 SINGLE 這個選項。
- 每個 master wrapper 一次只處理一個讀或寫命令；共享互連也要等目前交易完成，才讓下一個交易通過。ID 固定為 0，省略 ID ports，因此不需要調整回覆順序。
- 2 masters：CPU 測試模型和 UART 模組旁的 DMA。CPU 由 testbench BFM 模擬讀寫行為。2 slaves：4 KiB 記憶體和 UART/DMA 控制暫存器。UART 收發核心、DMA、wrapper 是分開做的；DMA 是這份作業另外加入的功能，不是第三方 UART 原本就有的功能。
- UART 控制操作採單筆，DMA 記憶體操作可單筆或四筆 burst。
- 這次沒有做 multiple outstanding、out-of-order、WRAP、FIXED、exclusive、cache/coherency、非對齊或 narrow transfers，也沒有做完整的 AXI 相容性認證。
- 所有模組使用共同時脈；reset 為低有效的同步 reset。硬體 reset 不會清除 RAM 內容，RAM 由 testbench 初始化。

## 各通道怎麼握手

只有在時脈上升緣，`xVALID && xREADY` 成立時，才算完成該通道的一筆傳送。VALID 已經拉高、READY 還沒拉高時，VALID 與 payload（這次要送的位址、資料或回覆內容）都要保持不變。讀寫資料的計數也只有在對應握手完成時才增加。送出方有資料就要提出 VALID，不必先等接收方拉高 READY。

AW 和 W 的握手彼此獨立。Master 先保存這次最多四筆的 payload，再用各自的進度旗標記錄 AW 位址和 W 資料送到哪裡；WVALID 不等待 AWREADY。Slave 則準備一份 AW 暫存器與最多四筆 W 資料緩衝，位址或資料先到都可以接收。等所有 W 握手完成、AW 也已接收後，再逐筆執行內部操作，最後送出 B 回覆。

## Master wrapper 的 FSM

| 狀態 | 動作 | 轉移條件 |
|---|---|---|
| `M_IDLE` | `cmd_ready=1`；接收位址、方向、筆數、資料 | 命令不合法→`M_RESPONSE` 並回 error；讀→`M_READ_ADDR`；寫→`M_WRITE_SEND` |
| `M_READ_ADDR` | 維持 ARVALID 與 AR payload | ARVALID && ARREADY→`M_READ_DATA` |
| `M_READ_DATA` | RREADY 由接收允許訊號控制；握手才保存一筆 RDATA | 非最後一筆→留在本狀態；接受 RLAST→`M_RESPONSE` |
| `M_WRITE_SEND` | AWVALID 與 WVALID 各自維持；用 `aw_done`、`w_done` 分別記錄進度；最後一筆 W 設 WLAST | AW 已握手且最後一筆 W 已握手→`M_WRITE_RESP` |
| `M_WRITE_RESP` | BREADY 由接收允許訊號控制 | BVALID && BREADY→記錄 BRESP，進入 `M_RESPONSE` |
| `M_RESPONSE` | 保持 rsp_valid/rsp_rdata/rsp_error | rsp_valid && rsp_ready→`M_IDLE` |

讀取時會逐筆檢查：`RRESP[1]` 為高，或 RLAST 與預期筆數不一致時，就設起 `rsp_error`，並保留到這個命令結束。遇到 SLVERR/DECERR 仍會繼續接收後續合法 burst 資料，直到 RLAST。寫入則要收到那一筆 B 回覆，才算完成整個交易。

`AW_DELAY`、`W_DELAY` 是合成時決定的延遲參數，也可以設為 0。Testbench 用它們安排位址先到或資料先到的情況。`allow_r`、`allow_b` 用來控制是否接收 R/B 回覆，讓測試能刻意製造 backpressure（暫時不接收）；一般使用時可接 1。

## Slave wrapper 的 FSM

| 狀態 | 動作 | 轉移條件 |
|---|---|---|
| `S_IDLE` | ARREADY=1，優先處理讀取；清除前次命令的收集紀錄 | AR 握手→`S_READ_EXEC`；否則看到 AWVALID 或 WVALID→`S_WRITE_COLLECT` |
| `S_READ_EXEC` | 合法存取拉 reg_valid；等待內部 reg_ready；已知錯誤則產生 error beat | 內部握手，或已知錯誤→`S_READ_RESP` |
| `S_READ_RESP` | 保持 RVALID/RDATA/RRESP；index=total−1 時 RLAST=1 | R 握手且最後一筆→`S_IDLE`；否則 index+1→`S_READ_EXEC` |
| `S_WRITE_COLLECT` | AW 與 W 各自握手保存，記錄 WLAST | 已保存 AW、已收到 WLAST→`S_WRITE_EXEC` |
| `S_WRITE_EXEC` | 依序以 reg_valid/reg_ready 執行每筆；WSTRB 保存在緩衝區，再傳給內部記憶體或暫存器 | 完成最後一筆或已知錯誤→`S_WRITE_RESP`；否則 index+1 留在此狀態 |
| `S_WRITE_RESP` | 保持 BVALID/BRESP，不等待 BREADY 才拉 BVALID | BVALID && BREADY→`S_IDLE` |

內部記憶體或暫存器只在 `reg_valid && reg_ready` 的時脈邊緣，確定執行這筆讀寫。例如寫入記憶體，或讀 RXDATA 並從 FIFO 取出資料，都只會做一次。這個設計會先收齊整個 W burst，再開始內部寫入，讓 AW/W 不同先後、等待情況和 B 回覆比較容易檢查。

## 互連怎麼分配使用權與判斷位址

`F_IDLE` 會看兩個 master 的 ARVALID/AWVALID。兩者都提出請求時，優先選擇 `rr` 指定的那一方；只有一方請求時，就選那一方。選定後，先固定 owner（目前的 master）與 target（要存取的 slave）。

- `F_READ`：保持目前連線，直到最後一筆 RVALID && RREADY && RLAST。
- `F_WRITE`：分別連接 AW、W、B 通道，直到 BVALID && BREADY。
- 完整交易結束後回 `F_IDLE`，並設定 `rr=!owner`，讓下一次同時請求時優先輪到另一個 master。

互連要先看到有效位址，才能決定 target，所以提早出現的 WVALID 可以先等位址出現。但 master 不能等到 WREADY 才提出 AWVALID，否則可能互相等待。連線選好後，AW/W 仍然各自握手；測試也有確認 W 比 AW 更早握手的情況。

記憶體範圍是 `0x00000000–0x00000FFF`，UART 暫存器範圍是 `0x40000000–0x400000FF`。互連會檢查整個傳輸的最後一個 byte，確認仍在同一個已對應的區域內，避免超出 UART 範圍後，低位址繞回另一個暫存器。位址未對應，或交易跨出 target window 時，會回 DECERR，也不會執行內部讀寫。

## 錯誤處理與限制

- 本機命令的筆數不是 1/4、沒有 4-byte 對齊，或跨越 4 KiB 邊界時，master 直接回 `rsp_error=1`，不會把非法 AXI 位址送出去。
- Slave 會檢查 AXI 長度、SIZE、BURST、對齊與 4 KiB 邊界。控制資訊（metadata）若不在這次支援的範圍內，就回 SLVERR。若寫入符合 AXI 協定、但長度超過四筆，Slave 在收到 AW 並確認不支援後，仍會接收並丟棄剩下的 W 資料，直到 WLAST 才回錯誤；讀取則仍送出 ARLEN+1 個 error beats。
- 位址找不到對應 slave 時回 `DECERR=11`；內部操作錯誤回 `SLVERR=10`；成功回 `OKAY=00`。讀取每筆都有自己的 RRESP；寫入整個 burst 只有一筆 BRESP。
- 讀取遇到錯誤時，仍會完成整個 burst。寫入遇到錯誤時，也要先收完 W burst 才回 B。如果內部某筆寫入失敗，前面已完成的寫入會保留，這個設計不會把它們還原。
- 這個設計假設另一端遵守 AXI，例如 WLAST 符合 AWLEN、R channel 按請求回傳。如果訊號本身違反協定，例如缺少 WLAST，就不保證能自動恢復。這和有效交易收到 SLVERR/DECERR 是不同情況。

## 實際測試結果

使用 Icarus Verilog 12.0 devel，`tb_axi` 已執行通過：

```text
AXI ALL TESTS PASSED: assertions=332 cycles=1134 Rbeats=128 Wbeats=22 AWfirst=9 Wfirst=4 contests=1 grants=115/2
AXI backpressure cycles: R=6 B=6 W=11 endpoint=156
```

`AWfirst` 記錄位址比資料先完成握手的交易數；`Wfirst` 記錄位址握手前，已經接收的資料 beat 數，因此不能解讀成四個不同交易。

測試包含：單筆與四筆讀寫、記憶體內部操作等待、AW/W 不同先後、R/B/W 暫停時 payload 保持不變、非法本機命令不送上匯流排、完整 burst 的 DECERR/SLVERR、跨出 target window、CPU 與 DMA 同時請求時依 rr 選擇，以及 UART TX 傳出 HW1!、UART RX 收到 RX4! 後由 DMA 寫回四個記憶體 word。UART 收發都有在模擬中檢查串列訊號。

測試也設了 `$fatal` timeout；如果卡住，會直接判定失敗，避免誤以為通過。模擬波形存放在 `results/tb_axi.vcd`。目前案例沒有測遍所有合法或不合法的 AXI metadata，因此這些錯誤處理測試還不算完整的 AXI 相容性驗證。

## 原始協定參考

[Arm AMBA AXI and ACE Protocol Specification，IHI 0022H](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)：主要參考 A3 的 VALID/READY、通道相依、burst 與 response 規則。這份作業的 state 編碼、資料緩衝方式、仲裁、位址配置與測試程式，則是為了方便學習而採用的設計；符合協定的做法也可以有其他架構。
