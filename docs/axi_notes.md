# AXI4 設計、狀態機與驗證

本文件對應 `rtl/axi_master.sv`、`axi_slave.sv`、`axi_interconnect.sv`、`axi_memory.sv` 與 `sim/tb_axi.sv` 的實際實作。

## 本作業採用的範圍

- 32-bit 資料、4-byte 對齊；每次命令為 1 或 4 個 word。
- 使用 AXI4 INCR：`AxBURST=01`、`AxSIZE=2`、`AxLEN=0/3`。AXI 的單筆傳輸用 LEN=0 表示，沒有名為 SINGLE 的 AXI BURST 編碼。
- 每個 master wrapper 同時僅有一個讀或寫命令；共享互連一次只放行一個完整交易。ID 固定為 0，省略 ID ports，因而不需要回覆重排序。
- 2 masters：CPU 測試模型、UART 模組旁的 DMA。2 slaves：4 KiB 記憶體、UART/DMA 控制暫存器。UART 收發核心、DMA、wrapper 分開實作；不宣稱第三方 UART 本身含 DMA。
- UART 控制操作採單筆，DMA 記憶體操作可單筆或四筆 burst。
- 不涵蓋 multiple outstanding、out-of-order、WRAP、FIXED、exclusive、cache/coherency、非對齊或 narrow transfers，也不是完整 AXI compliance certification。
- clock 為共同時脈；低有效 reset 為同步 reset。RAM 內容不由硬體 reset 清除，由 testbench 初始化。

## 握手共同規則

`xVALID && xREADY` 在上升緣成立才接受該通道的一筆傳送。VALID 已經拉高而 READY 尚未拉高時，保持 VALID 與 payload。讀取與寫入資料計數只在相應握手遞增。送端 VALID 不等待接收端 READY。

AW 和 W 可以各自前進：本 master 先保存整個最多四筆的 payload，AW 送位址、W 送資料各有獨立進度旗標；WVALID 不等待 AWREADY。Slave 使用一份 AW 暫存器與最多四筆 W 緩衝資料，兩者任意先握手。所有 W 握手完成且 AW 已接受後，才逐筆執行內部操作，最後送 B。

## Master wrapper 的實際 FSM

| 狀態 | 動作 | 轉移條件 |
|---|---|---|
| `M_IDLE` | `cmd_ready=1`；接受位址、方向、筆數、資料 | 命令不合法→`M_RESPONSE` 並回 error；讀→`M_READ_ADDR`；寫→`M_WRITE_SEND` |
| `M_READ_ADDR` | 維持 ARVALID 與 AR payload | ARVALID && ARREADY→`M_READ_DATA` |
| `M_READ_DATA` | RREADY 由接收允許訊號控制；握手才保存一筆 RDATA | 非最後一筆→留在本狀態；接受 RLAST→`M_RESPONSE` |
| `M_WRITE_SEND` | AWVALID 與 WVALID 各自維持；`aw_done`、`w_done` 各自記錄進度；最後一筆 W 設 WLAST | AW 已握手且最後一筆 W 已握手→`M_WRITE_RESP` |
| `M_WRITE_RESP` | BREADY 由接收允許訊號控制 | BVALID && BREADY→記錄 BRESP，進入 `M_RESPONSE` |
| `M_RESPONSE` | 保持 rsp_valid/rsp_rdata/rsp_error | rsp_valid && rsp_ready→`M_IDLE` |

讀取每一筆的 `RRESP[1]` 或 RLAST 與預期筆數不一致都會設 sticky `rsp_error`。遇 SLVERR/DECERR 仍繼續接收後續合法 burst 資料，直到 RLAST。寫入要等一筆 B 回覆才完成。

`AW_DELAY`、`W_DELAY` 是可設為 0 的合成期延遲參數，testbench 用來安排地址和資料不同先後。`allow_r`、`allow_b` 是接收節流輸入，用於真實 R/B backpressure 測試；一般使用可接 1。

## Slave wrapper 的實際 FSM

| 狀態 | 動作 | 轉移條件 |
|---|---|---|
| `S_IDLE` | ARREADY=1，讀優先；清除前次命令收集狀態 | AR 握手→`S_READ_EXEC`；否則看到 AWVALID 或 WVALID→`S_WRITE_COLLECT` |
| `S_READ_EXEC` | 合法存取拉 reg_valid；等待內部 reg_ready；已知錯誤則產生 error beat | 內部握手，或已知錯誤→`S_READ_RESP` |
| `S_READ_RESP` | 保持 RVALID/RDATA/RRESP；index=total−1 時 RLAST=1 | R 握手且最後一筆→`S_IDLE`；否則 index+1→`S_READ_EXEC` |
| `S_WRITE_COLLECT` | AW 與 W 各自握手保存，記錄 WLAST | 已保存 AW、已收到 WLAST→`S_WRITE_EXEC` |
| `S_WRITE_EXEC` | 依序以 reg_valid/reg_ready 執行每筆；WSTRB 保存在緩衝區並傳到 endpoint | 完成最後一筆或已知錯誤→`S_WRITE_RESP`；否則 index+1 留在此狀態 |
| `S_WRITE_RESP` | 保持 BVALID/BRESP，不等待 BREADY 才拉 BVALID | BVALID && BREADY→`S_IDLE` |

`reg_valid && reg_ready` 是 endpoint 的唯一提交點，每筆寫入或讀取副作用只發生一次。已收集整個 W burst 才開始執行內部寫入，使 AW/W 交錯、等待和 B 回覆容易檢查。

## 互連仲裁及地址解碼

`F_IDLE` 觀察兩個 master 的 ARVALID/AWVALID。兩者都請求時採 `rr` 指定的優先者；只有一方請求則選該方。接受選擇後固定 owner 與 target。

- `F_READ`：維持路由直到最後一筆 RVALID && RREADY && RLAST。
- `F_WRITE`：AW、W、B 分別路由，直到 BVALID && BREADY。
- 完整交易結束後回 `F_IDLE`，並設定 `rr=!owner`，下一次同時請求時優先另一個 master。

互連必須先看到有效地址才能決定 target；早到的 WVALID 可以等待地址出現，但 master 的 AWVALID 不可依賴 WREADY。選定路由後 AW/W 握手順序仍獨立；測試實際包含 W 比 AW 更早握手。

記憶體範圍 `0x00000000–0x00000FFF`；UART 暫存器範圍 `0x40000000–0x400000FF`。互連檢查整個傳輸的最後一個 byte 仍位於同一個已對應區域，避免 UART 的低位地址環回到另一個暫存器。未對應或跨 target window 的交易走 DECERR 路徑，不提交 endpoint 操作。

## 錯誤處理與限制

- 本機命令筆數不是 1/4、非 4-byte 對齊、跨 4 KiB 邊界：master 直接回 `rsp_error=1`，不發出非法 AXI 地址。
- Slave 檢查 AXI 長度、SIZE、BURST、對齊與 4 KiB 邊界；其教學子集不支援的 metadata 用 SLVERR 回應。對協定本身合法但長度超過四筆的寫入，在 AW 已知為不支援後繼續接收並丟棄剩餘 W 資料，直到 WLAST，然後回錯誤；讀取仍送出 ARLEN+1 個 error beats。
- 未解碼地址回 `DECERR=11`；endpoint 錯誤回 `SLVERR=10`；成功回 `OKAY=00`。讀取每筆各自有 RRESP；寫入整個 burst 只有一筆 BRESP。
- 錯誤讀取不提前終止 burst。錯誤寫入先完成整個 W burst 的接收才回 B。內部某筆失敗可能留下先前已完成的寫入；此設計沒有交易回滾。
- 以符合 AXI 的對端為前提，例如 WLAST 符合 AWLEN、R channel 按請求回傳。任意破壞協定的訊號（例如缺少 WLAST）不保證自動恢復；這不等同地址或合法操作的 SLVERR/DECERR。

## 實際測試結果

使用 Icarus Verilog 12.0 devel，`tb_axi` 已執行通過：

```text
AXI ALL TESTS PASSED: assertions=332 cycles=1134 Rbeats=128 Wbeats=22 AWfirst=9 Wfirst=4 contests=1 grants=115/2
AXI backpressure cycles: R=6 B=6 W=11 endpoint=156
```

`AWfirst` 計數地址先於資料的交易；`Wfirst` 計數地址握手前已接受的資料 beat，不是四個不同交易。

測試涵蓋：單筆與四筆讀寫、memory endpoint 等待、AW/W 不同先後、R/B/W 停頓下 payload 不變、非法本機命令未出現在匯流排、完整 burst DECERR/SLVERR、target window 跨界、CPU 與 DMA 同時請求時按 rr 選取、UART TX 實際傳出 HW1!、UART RX 實際接收 RX4! 並由 DMA 寫回四個記憶體 word。

測試另以 `$fatal` timeout 防止死鎖被誤判為通過，並產生 `results/tb_axi.vcd` 真實模擬波形。這組案例沒有窮舉所有合法或不合法 AXI metadata；文件說明的錯誤防護也不應解讀成完整 compliance 驗證。

## 原始協定參考

[Arm AMBA AXI and ACE Protocol Specification，IHI 0022H](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)：A3 的 VALID/READY、通道相依、burst 與 response 規則。本作業的 state 編碼、緩衝策略、仲裁、地址配置與測試程式均是自行實作的教學選擇，不是規格指定的唯一架構。
