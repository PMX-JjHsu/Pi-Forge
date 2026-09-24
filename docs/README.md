# shells/orch — 多 agent 開發 lane 操作工具

把「開 lane → 派工 → 監看 → 驗證 → 合併」的流程腳本化，
讓規則變成 **guard**，而不是依賴 agent 記得。

規格與事故紀錄：`pi-multi-agent-orchestration-v2.md`（本機檔，不進版控）
§29 實戰修訂 / §31 控制方法 / §32 監看與回報。

## 架構

```
使用者 → OpenCode(Opus 5) → orch → codex orchestrator → pi workers/reviewers
                             │                              （本地 vLLM，免費）
                             └→ pi（單發，做機械驗證）
```

- **Cloud model 做決策與審查，local LLM 做大量勞動。** 實測 token 比例約 local:cloud = 68:1。
- 兩道 Final Gate：Gate #1 = orchestrator 自審，Gate #2 = Opus 5 獨立重跑（不採信 Gate #1）。

## 指令

```bash
shells/orch/orch new <lane> --items "BL-XXX-001 ..." --files "path1 path2"
shells/orch/orch status [lane] [--all]
shells/orch/orch verify <lane> [--with-main] [--ref <ref>]
shells/orch/orch merge  <lane> [--dry-run] [--no-push] [--skip-tests]
shells/orch/orch dispatch <run> worker|reviewer <TASK_ID> <prompt_file> [cwd]
```

### new — 開一條 lane

依序做 8 件事，任一步失敗就停：主 worktree 檢查 → fetch 取 base SHA →
**檔案重疊檢查**（比對所有進行中 lane 的 `lane.conf FILES`）→ 開 integration branch →
建目錄 + 複製 `pi_agent` → 寫 `lane.conf`（含 `BASE_SHA`，不事後推測）→
啟動背景 heartbeat → 產生 brief 骨架。

**`--files` 強烈建議帶**，否則無法自動擋跨 lane 衝突。

### status — 看狀態

所有計算在腳本裡做，輸出全部截斷（省 token）。會顯示：
main / 未推送數、pi 與 codex 佔用、每條 lane 的 base / commits / 進行中的 pi、
**停滯偵測**（session jsonl mtime 超過 8 分鐘會標 ⚠）、異常事件、review 數、pi token 用量。

### verify — Gate #2 獨立驗證

開 detached 驗證 worktree（branch 被佔用會自動 `--detach`），
`--with-main` 會先把當下 main 合進去再驗（**正確順序**），
然後用 `templates/verify.md` 產生 prompt 派 pi 跑。

pi **只回報事實、不下判斷**；判斷是 Gate #2 自己的事。

### merge — 合進 main

強制順序：Gate #2 報告必須 PASS → 主 worktree 乾淨 → fetch →
**先把 main 合進 lane branch** → **在合併後的狀態跑全部測試 + autotest** →
通過才 `merge --no-ff` 進 main（commit message 記錄兩道 Gate）→ push。

先用 `--dry-run` 看它要做什麼。

### dispatch — 派一個 pi

原本每條 lane 各複製一份 `pi_task.sh`，現在共用這一支（lane 由參數決定）。
防呆：全機 8 個 pi 上限、每 lane 3 個（2 worker + 1 reviewer）、
同一 (role, task) 不得重複、PAUSE 擋新 task、rework 上限 5 次、
reviewer 工具集**沒有 edit/write**。

## 目錄結構

```
tmp/<lane>_<date>/
  lane.conf          ← orch 的單一事實來源（LANE/BRANCH/BASE_SHA/ITEMS/FILES）
  run.meta           ← append-only 事件流，統計一律從這裡算
  heartbeat.log      ← 每 10 分鐘一行
  prompts/ logs/ sessions/ reviews/ reports/ rework_count/ artifacts/
  worktrees/<TASK_ID>/   ← 所有 worktree 在 repo 內（tmp/ 已 gitignore）
  final_reviews/gate1/  gate2/
  pi_agent/          ← pi 的 provider 設定（maxTokens 要夠大）
```

## 三條資訊通道（看狀態別找錯地方）

| 通道 | 即時性 |
|---|---|
| `run.meta` | 即時（`tee` 寫入） |
| `sessions/<role>-<ID>/*.jsonl` | 即時 —— **判斷是否卡住看它的 mtime** |
| `logs/<role>-<ID>-*.log` | **到程序結束才 flush**，執行中恆為 0 bytes |

用 `logs/` 判斷進度是錯的 —— 曾因此誤殺一個正在工作的 worker。

## 控制

```bash
touch tmp/<run>/PAUSE      # 暫停派新 task（已開始的做完）
rm    tmp/<run>/PAUSE      # 恢復
pkill -f "[c]odex exec.*<run_name>"   # 停 orchestrator
pkill -f "CR worker <ID>"             # 停單一 pi
```

lane 是一次性 exec，brief 送出後改不了。要修正方向：
在 `run.meta` 寫 `NOTICE`（orchestrator 下一輪會讀到）、放 `ADDENDUM` 檔、或殺掉重開。

## 環境變數

| 變數 | 預設 | 用途 |
|---|---|---|
| `ORCH_PI_CAP` | 8 | 全機 pi 上限（= 本地 server 併發數） |
| `ORCH_LANE_CAP` | 3 | 每 lane 上限（2 worker + 1 reviewer） |
| `ORCH_MAX_REWORK` | 5 | 每 task rework 上限 |
| `ORCH_STALL_MIN` | 8 | 停滯判定門檻（分鐘） |
| `ORCH_PI_MODEL` | `Qwen3.8-27B-nvfp4` | local LLM 模型 |
| `PI_TIMEOUT_MIN` | 75 | 單次 pi 執行 timeout |
| `ORCH_YES` | 0 | 設 1 跳過確認提示（慎用） |

## 前置需求

- `secrets/local-vllm-api-key.json`（不進版控）
- `pi` CLI 在 PATH
- orchestrator：`/Applications/ChatGPT.app/Contents/Resources/codex`（ChatGPT 訂閱路徑）
