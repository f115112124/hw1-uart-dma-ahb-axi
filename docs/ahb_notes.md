# AHB 實作筆記與畫圖依據

本範例採 AMBA 2 AHB 的教學子集。CPU 是 testbench BFM，DMA 來自共同的 UART 核心；兩個 master wrapper 透過輪流仲裁存取 memory 與 UART/DMA register 兩個 mapped slaves。另有 unmapped-address default ERROR responder。

## 已固定的範圍

- 32-bit data、word aligned，僅 SINGLE（1 beat）與 INCR4（4 beats）；資料位址每次加 4。
- Master 開始前檢查本機命令：筆數只能 1/4、位址必須對齊、burst 不可越過 1 KiB；不合法命令直接本機 error，不上 bus。
- 支援 OKAY 與兩拍 ERROR，收到 ERROR 時中止該 burst 剩餘 beats。排除 LOCK、SPLIT、RETRY、WRAP、其他大小及中途搶占。
- 同一個 wrapper 一次只接受一筆本機 command；rsp_valid 等到 rsp_ready 才釋放。
- 為容易畫 FSM，每個 beat 的實際 address/data 不重疊；以合法 BUSY 保持 INCR4 的連續性，因此吞吐量較保守。
- 仲裁保留 ownership 到該 command 完成；HBUSREQ 在 response 狀態撤銷。這也保證 data phase 未結束時 owner 不會切換。

## Master FSM：rtl/ahb_master.sv

| 狀態 | 輸出／動作 | 下一步條件 |
|---|---|---|
| M_IDLE | cmd_ready=1；HTRANS=IDLE | cmd_valid 且合法 → M_REQ；不合法 → M_RSP，rsp_error=1 |
| M_REQ | HBUSREQ=1；HTRANS=IDLE | HGRANT && HREADY → M_ADDR |
| M_ADDR | HBUSREQ=1；HADDR=base+4×beat；第一筆 NONSEQ，後續 SEQ | HREADY → M_DATA；否則保持 |
| M_DATA | 有下一筆時 HTRANS=BUSY 且 HADDR=下一筆位址；最後一筆 HTRANS=IDLE。寫資料屬於當前 beat | HREADY=0/OKAY → 保持；HREADY=1/OKAY 且未末筆 → beat++、M_ADDR；末筆 → M_RSP；ERROR/HREADY=0 → M_ERR2 |
| M_ERR2 | HTRANS=IDLE；rsp_error=1；等待錯誤第二拍 | HREADY=1 → M_RSP |
| M_RSP | rsp_valid=1，HBUSREQ=0；保持讀回資料與error | rsp_ready → M_IDLE |

M_DATA 正常完成的時脈邊緣才收 HRDATA 或結束 HWDATA 該筆；不會把「地址被接收」誤算成「資料完成」。M_ERR2 可以改成 IDLE，是 AHB ERROR 流程的取消規則。圖上可另註 M_DATA 若收到單拍非零 response 的防禦分支會直接回 error，但本系統 slave 一律使用合法兩拍 ERROR。

### 四筆 burst 的無 wait 示意

| 週期 | address HTRANS | address | data phase |
|---|---|---|---|
| 1 | NONSEQ | A | 尚無 |
| 2 | BUSY | A+4 | beat 0 |
| 3 | SEQ | A+4 | BUSY bubble |
| 4 | BUSY | A+8 | beat 1 |
| 5 | SEQ | A+8 | BUSY bubble |
| 6 | BUSY | A+12 | beat 2 |
| 7 | SEQ | A+12 | BUSY bubble |
| 8 | IDLE | 不使用 | beat 3 |

本實作 slave 有執行等待，實際每筆 data phase 會拉長；被拉長期間 address/control/HWDATA 保持。BUSY 不計入四筆資料，最後一筆後不送 BUSY。

## Slave FSM：rtl/ahb_slave.sv

定義 `accept = HREADY && HSEL && HTRANS[1]`。只有 accept 才擷取新位址、方向、大小；HSEL 是 address-phase 訊號。

| 狀態 | 輸出／動作 | 下一步條件 |
|---|---|---|
| S_IDLE | HREADYOUT=1，HRESP=OKAY | accept 且格式正確 → S_EXEC；格式錯誤 → S_ERR1 |
| S_EXEC | HREADYOUT=0，HRESP=OKAY；reg_valid=1 | endpoint 尚未 ready → 保持；握手成功且無錯 → 暫存讀回資料、S_OK；錯誤 → S_ERR1 |
| S_OK | HREADYOUT=1，HRESP=OKAY；HRDATA=暫存結果 | accept → 擷取下一筆並進 S_EXEC/ S_ERR1；否則 S_IDLE |
| S_ERR1 | HREADYOUT=0，HRESP=ERROR | 下一個 clock → S_ERR2 |
| S_ERR2 | HREADYOUT=1，HRESP=ERROR | accept → 擷取下一筆；否則 S_IDLE |

Endpoint 只在 S_EXEC 的 `reg_valid && reg_ready` 邊緣執行一次；S_OK/ERROR 不重複觸發 register side effect。HWDATA 在 data phase 使用，與先前鎖住的 address/HWRITE 配對。

## 兩個 Master 的仲裁與解碼

Arbiter 狀態 A_IDLE、A_M0、A_M1。A_IDLE 若兩者同時請求，優先給上次未服務者；只有一方請求即給該方。A_M0/A_M1 保留目前 grant；當目前 master 撤銷 HBUSREQ 且 HREADY=1，更新 last_owner，另一方若已請求立即換手，否則進 A_IDLE。本例不允許仲裁器在 burst 中途收回 grant。

Interconnect 在 HREADY=1 的邊緣鎖住被接受地址的 slave selection；回覆 mux 使用這份 data-phase selection，不直接看目前 HADDR。BUSY/IDLE 的 data phase 回 zero-wait OKAY。Default responder 對未映射的 NONSEQ/SEQ 給兩拍 ERROR。

Memory 是 0x00000000–0x00000FFF。AHB 為 UART 分配 1 KiB slot（0x40000000–0x400003FF），真正的 CSR window 是前 256 bytes；保留區 0x40000100–0x400003FF 回 ERROR，不能把低 8 bits 相同的位址誤認成有效 UART 暫存器。

## testbench 真實驗證項目

- CPU SINGLE、INCR4 write/read；memory 每筆額外插入兩個 endpoint wait。
- UART DMA 讀 memory 四字後，serial TX 實際解碼出 `HW1!`；RX 注入 `RX4!` 後 DMA 四字寫 memory。
- CPU 與 DMA 同時提出 request，兩者均完成；不會在一個 command 中途更換 owner。
- 每個 CPU response 刻意停 3 cycles，不允許 rsp_valid/data/error 改變。
- 每拍監測 normal wait 的地址、控制與 write data 穩定。
- 監測 burst 的 NONSEQ/SEQ、INCR4 encoding、位址遞增、四筆數目、1 KiB 邊界與不能以 BUSY 結尾。
- 未映射地址、未實作 CSR、寫唯讀 STATUS、UART slot 保留區均回兩拍 ERROR。
- burst 第二筆遭遇 ERROR 時不再發第三、第四筆。
- 未對齊、錯誤筆數、跨 1 KiB 的本機 command 被攔下；剛好結束於邊界前的 burst 正常。
- 比對實際 accepted address 數與 endpoint handshake 次數，避免重複寫入／pop。

VCD：results/tb_ahb.vcd。請以重新執行 sim/run_all.py 的最新 log 為實測數據；這不是形式驗證，也未涵蓋本範例刻意排除的 AHB 功能。

## 規格來源

[Arm AMBA Specification Rev 2.0, ARM IHI 0011A](https://documentation-service.arm.com/static/5f916403f86e16515cdc3d71)，第 3 章。使用的協定依據是：地址與資料分階段、HREADY 限定取樣與推進、固定 burst 內可有 BUSY、增量 burst 不跨 1 KiB、grant 以 HREADY 限定，以及 ERROR 的低 ready／高 ready 兩拍回應。上列狀態名稱、仲裁政策與 endpoint 等待策略是本作業的具體設計選擇。
