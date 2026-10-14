# AHB：設計說明與畫圖重點

這次使用 AMBA 2 AHB，先做出適合練習的功能範圍。CPU 由 testbench 裡的 BFM 模擬讀寫行為，DMA 則使用 AHB、AXI 版本共用的 UART 核心。兩個 master wrapper 輪流使用匯流排，存取記憶體和 UART/DMA 暫存器這兩個 slave。若位址不屬於任何一個 slave，就由 default ERROR responder 回覆錯誤。

## 這次做的功能

- 資料寬度為 32-bit，位址需對齊 word；支援 SINGLE（1 beat）與 INCR4（4 beats），資料位址每次加 4。
- Master 開始傳輸前會先檢查命令：筆數只能 1/4、位址必須對齊、burst 不可越過 1 KiB。不合法的命令直接回報 error，不送上匯流排。
- 支援 OKAY 與兩拍 ERROR；收到 ERROR 後，停止這個 burst 剩下的 beats。這次沒有做 LOCK、SPLIT、RETRY、WRAP、其他大小及中途搶占。
- 同一個 wrapper 一次只接受一筆本機 command；rsp_valid 等到 rsp_ready 才釋放。
- 為了讓 FSM 比較容易理解，每個 beat 的實際 address/data 階段安排成不重疊。筆與筆之間使用協定允許的 BUSY 維持 INCR4，因此傳輸速度較慢。
- 目前使用匯流排的 master 會保有使用權，直到該 command 完成；HBUSREQ 在 response 狀態撤銷。這樣 data phase 還沒結束時，owner 就不會換成另一個 master。

## Master FSM：rtl/ahb_master.sv

| 狀態 | 輸出／動作 | 下一步條件 |
|---|---|---|
| M_IDLE | cmd_ready=1；HTRANS=IDLE | cmd_valid 且合法 → M_REQ；不合法 → M_RSP，rsp_error=1 |
| M_REQ | HBUSREQ=1；HTRANS=IDLE | HGRANT && HREADY → M_ADDR |
| M_ADDR | HBUSREQ=1；HADDR=base+4×beat；第一筆 NONSEQ，後續 SEQ | HREADY → M_DATA；否則保持 |
| M_DATA | 有下一筆時 HTRANS=BUSY 且 HADDR=下一筆位址；最後一筆 HTRANS=IDLE。HWDATA 傳送的是目前這個 beat 的資料 | HREADY=0/OKAY → 保持；HREADY=1/OKAY 且未末筆 → beat++、M_ADDR；末筆 → M_RSP；ERROR/HREADY=0 → M_ERR2 |
| M_ERR2 | HTRANS=IDLE；rsp_error=1；等待錯誤第二拍 | HREADY=1 → M_RSP |
| M_RSP | rsp_valid=1，HBUSREQ=0；保持讀回資料與 error | rsp_ready → M_IDLE |

只有在 M_DATA 正常完成的時脈邊緣，才收下 HRDATA，或認定這筆 HWDATA 已傳完；接收位址和完成資料傳輸是不同的事。到了 M_ERR2，HTRANS 可以改成 IDLE，依 AHB ERROR 規則取消原本接續的傳輸。程式也保留一個額外的錯誤處理分支：M_DATA 若收到單拍非零 response，會直接回報 error。不過這個系統的 slave 都使用合法的兩拍 ERROR。

### 四筆 burst：先看沒有等待的情況

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

實際執行時，slave 需要等待內部操作完成，所以每筆 data phase 會更長。等待期間，address/control/HWDATA 都保持不變。BUSY 不算在四筆資料裡，最後一筆之後也不再送 BUSY。

## Slave FSM：rtl/ahb_slave.sv

這裡用 `accept = HREADY && HSEL && HTRANS[1]` 表示接收到一筆有效要求。只有 accept 成立時，才保存新位址、讀寫方向和資料大小；HSEL 屬於 address phase 的訊號。

| 狀態 | 輸出／動作 | 下一步條件 |
|---|---|---|
| S_IDLE | HREADYOUT=1，HRESP=OKAY | accept 且格式正確 → S_EXEC；格式錯誤 → S_ERR1 |
| S_EXEC | HREADYOUT=0，HRESP=OKAY；reg_valid=1 | 內部記憶體或暫存器尚未 ready → 保持；握手成功且無錯 → 暫存讀回資料、S_OK；錯誤 → S_ERR1 |
| S_OK | HREADYOUT=1，HRESP=OKAY；HRDATA=暫存結果 | accept → 擷取下一筆並進 S_EXEC/ S_ERR1；否則 S_IDLE |
| S_ERR1 | HREADYOUT=0，HRESP=ERROR | 下一個 clock → S_ERR2 |
| S_ERR2 | HREADYOUT=1，HRESP=ERROR | accept → 擷取下一筆；否則 S_IDLE |

內部記憶體或暫存器只在 S_EXEC 的 `reg_valid && reg_ready` 時脈邊緣執行這筆操作。到了 S_OK/ERROR 就不再重做，避免同一筆寫入或 FIFO 取出動作發生兩次。HWDATA 在 data phase 使用，搭配的是先前保存的 address/HWRITE。

## 兩個 Master 的仲裁與解碼

Arbiter 有 A_IDLE、A_M0、A_M1 三個狀態。在 A_IDLE，若兩個 master 同時請求，就優先讓上次沒用到匯流排的那一方使用；只有一方請求時，就給那一方。A_M0/A_M1 會保持目前 grant。當目前 master 撤銷 HBUSREQ 且 HREADY=1，便更新 last_owner；另一方若已提出請求就直接換手，否則回到 A_IDLE。這個設計不會在 burst 中途收回 grant。

Interconnect 在 HREADY=1 的時脈邊緣，記下這筆位址選到哪一個 slave。之後選擇回覆來源時，使用這份 data-phase selection，因為目前 HADDR 可能已經是下一筆位址。BUSY/IDLE 的 data phase 直接回 zero-wait OKAY。未對應到 slave 的 NONSEQ/SEQ 則交給 default responder，回覆兩拍 ERROR。

記憶體位址是 0x00000000–0x00000FFF。AHB 為 UART 分配 1 KiB 區域（0x40000000–0x400003FF），其中只有前 256 bytes 是控制暫存器區域。保留區 0x40000100–0x400003FF 會回 ERROR，避免只因低 8 bits 相同，就誤讀或誤寫有效的 UART 暫存器。

## testbench 檢查了什麼

- CPU 的 SINGLE、INCR4 讀寫；記憶體每筆操作額外等待兩拍。
- UART DMA 讀 memory 四字後，serial TX 實際解碼出 `HW1!`；RX 注入 `RX4!` 後 DMA 四字寫 memory。
- CPU 與 DMA 同時提出 request 時，兩者都能完成；同一個 command 進行到一半時，owner 不會換人。
- 每個 CPU response 刻意停 3 cycles，確認 rsp_valid/data/error 保持不變。
- 每拍檢查正常等待時，位址、控制訊號與 write data 是否穩定。
- 檢查 burst 的 NONSEQ/SEQ、INCR4 編碼、位址遞增、四筆數目、1 KiB 邊界，以及最後不能停在 BUSY。
- 未對應的位址、未實作的 CSR、寫入唯讀 STATUS，以及 UART 保留區，都回兩拍 ERROR。
- burst 第二筆遇到 ERROR 後，不再發出第三、第四筆。
- 未對齊、筆數錯誤、跨 1 KiB 的本機 command 會被攔下；剛好結束在邊界前的 burst 則能正常完成。
- 比對實際接收的位址數與內部記憶體或暫存器的握手次數，確認沒有重複寫入或重複 pop。

波形檔是 results/tb_ahb.vcd，測試數據請以重新執行 sim/run_all.py 後的最新 log 為準。這些是模擬測試，沒有做形式驗證，也沒有測試前面列出的未支援 AHB 功能。

## 規格來源

[Arm AMBA Specification Rev 2.0, ARM IHI 0011A](https://documentation-service.arm.com/static/5f916403f86e16515cdc3d71)，第 3 章。這次依照的規則包括：位址與資料分成不同階段、依 HREADY 決定何時取樣和前進、固定 burst 中可以插入 BUSY、增量 burst 不跨 1 KiB、grant 配合 HREADY 生效，以及 ERROR 使用低 ready／高 ready 的兩拍回應。狀態名稱、輪流仲裁方式，以及內部操作的等待安排，則是這份作業採用的設計。
