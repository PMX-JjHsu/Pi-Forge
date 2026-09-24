# 獨立 GUI（全 local）開發計畫 — orch 開發 lane 工具

> 狀態：draft v0.1
> 範圍：取代 opencode 作為「開發 lane 的指揮層」，後端全走 local LLM。
> 不涵蓋：Companion Robot 產品端的 UI（那是另一套，走 local ONNX/vLLM）。
> 上游規格：`pi-multi-agent-orchestration-v2.md`（§29 實戰修訂、§31 控制方法、§32 監看與回報）

---

## 0. 目標

把現有的

```
你 → opencode(cloud model) → orch(shell) → codex orchestrator(cloud) → pi workers(reviewer)(local vLLM)
```

改造成

```
你 → 自建 GUI(thin client)
        ├→ 直接 subprocess 呼叫 orch            ← 取代 opencode 的「手」
        └→ local-LLM orchestrator loop(vLLM)    ← 取代 codex orchestrator + opencode 的「腦」
              └→ orch dispatch worker/reviewer → pi(local vLLM)
```

**丟掉 opencode / cloud 依賴**，做到自包含、離線、免費。

### 不在本次範圍
- 不在 GUI／backend **另建一份** guard（併發上限、worktree 隔離、PAUSE、rework 上限）；這些規則要**改就改在機器層**（見 §1）。
- 不整包重寫 `dispatch.sh` 的 harness（可加參數、可調整，但保留「防呆集中在一處」的形狀）。
- 不改 `templates/brief.md`、`templates/verify.md` 的**規則精神**（內容可增修，仍作為 orchestrator 的 system prompt 引用）。

---

## 1. 不可破壞的原則

> **shell 不是聖物。** `orch`／`dispatch.sh`／`new.sh` 隨時可以改：加參數、把寫死的值變成輸入、重構都行。
> 要守的**不是「檔案不准動」**，而是下面第 1、2 條的「單一真相來源」。前一版寫「機器層不動」是過度保守，作廢。

1. **guard 只有一份真相來源**：併發／worktree 隔離／PAUSE／rework 上限這些硬規則，**只能存在於機器層（shell）一處**。要調整就**改那一份**；**絕不在 GUI 或 backend 複製第二份**——複製才是製造會漂移的真相來源。改 orch 本體 = 可以；在 backend 重寫一遍 = 禁止。
2. **參數化優先於分叉**：上層要不同行為，first choice 是**把值當參數傳進機器層**（如 §4.3 的 `--workers/--reviewers/--final-reviewer`），而不是複製一份腳本改。寫死的值該變輸入就變輸入。
3. **角色分離**：LLM 在本系統只有兩種身份——(a) orchestrator brain（決策 + 審查判斷）、(b) worker/reviewer（勞動）。orchestrator 與 worker 是**不同 process**，不要混用同一 session。
4. **先人後自主**：MVP 階段每一次派工 / Gate 結論都由**人按確認**；orchestrator 只產「提案」。可信度上來後再逐步放自主（見 §6 分階段）。
5. **規則即 guard**：沿用現行哲學——不靠 prompt 約束行為，靠機器層的硬檢查擋住（brief.md §4 的防呆精神）。guard 的**位置**固定在機器層，但 guard 的**內容**可以改進。

---

## 2. 架構

```
┌──────────────────────────────────────────────────────────────┐
│  你（人類）                                                    │
└──────────────────────────────────────────────────────────────┘
        │ 瀏覽器 localhost
┌──────────────────────────────────────────────────────────────┐
│  GUI（index.html，單一檔、no build）                            │
│    lane 狀態牆 │ 派工 panel │ 審查/Gate panel │ 事件流 │ log    │
└──────────────────────────────────────────────────────────────┘
        │ fetch (JSON)
┌──────────────────────────────────────────────────────────────┐
│  Backend（Python 3.11 + FastAPI，uvicorn，僅綁 localhost）      │
│    ├─ /api/*  薄層：參數檢查後 subprocess → orch               │
│    ├─ orchestrator.py  local-LLM brain（決策 + 審查）          │
│    └─ pollers        讀 run.meta / sessions mtime / logs       │
└──────────────────────────────────────────────────────────────┘
        │ subprocess                         │ HTTP (vLLM chat API)
┌───────────────────────┐          ┌───────────────────────────┐
│  orch（shell，不變）    │          │ local vLLM                │
│   new/status/verify/  │          │  Qwen3.8-27B-nvfp4         │
│   merge/dispatch/watch │          │  key: secrets/local-vllm- │
│   └→ pi worker/reviewer│          │     api-key.json          │
└───────────────────────┘          └───────────────────────────┘
```

---

## 3. 組件

### 3.0 執行模型（client-server，先搞清楚誰在跑）

這套是標準 **client-server**，執行時**兩個 process 同時開著**，分工不同：

```
瀏覽器 (client / GUI)  ──HTTP(localhost)──►  Python (server / service)  ──subprocess──►  orch / pi
   你點按鈕、看畫面                            聽 127.0.0.1:8790、收請求、幹活              真正執行
```

- **Python = server / service**：背景服務，**沒有自己的視窗**（終端機只印 log）。唯一有權限碰 shell / 檔案的角色——真正去 `subprocess` 呼叫 `orch`、跑 `pi`、讀 `run.meta`。只綁 `127.0.0.1`，只有本機連得到、不對外。
- **瀏覽器 = GUI**：畫面與互動全在這。自己不幹活，所有「會做事」的動作都透過 `fetch` HTTP 丟給 Python server。瀏覽器基於安全碰不到 shell，所以中間**一定**要墊這層 Python。

啟動與關閉：
```bash
python shells/orch/gui/app.py        # 1. 起 server（一直跑，聽 :8790）
open http://127.0.0.1:8790           # 2. 瀏覽器開 GUI
```
兩個都要開著：關 Python → 網頁變死的（只剩靜態畫面）；關瀏覽器 → server 還在，重開網頁又活。

> 為什麼不純 Python 桌面 GUI（Tkinter/PyQt）？排版難改、要打包、跨平台麻煩。
> 為什麼不純瀏覽器？瀏覽器碰不到 shell / 檔案，無法呼叫 `orch`/`pi`，一定要本機 server 代勞。

### 3.1 GUI（`gui/index.html`）
- 單一 HTML 檔（inline CSS + JS，無 CDN、無 build step）→ 直接 `open` 可看，接上 backend 後變活。
- 三種顯示來源：① `GET /api/status`（主要）② `run.meta` 事件流 ③ `logs/` 或 `sessions/` tail。
- **無 backend / 純 file:// 開啟時**：fallback 到內嵌 sample 資料，並標「靜態預覽」，讓版型可獨立驗收。
- 面板（詳見 `gui/index.html`）：
  - **頂欄**：main SHA、pi/上限、codex 數、rework、token 用量、PAUSE 開關、backend 連線狀態燈。
  - **左**：專案 → lane 樹狀清單（**專案為一級、可收合**；每 lane 一張卡：branch / base SHA / ahead commits / in-flight pi（role+task+停滯⚠）/ reviews / rework）。每個專案對應一個 `RobotProject/` workdir（§3.8）。
  - **中**：派工 panel（選 task → **模型選擇器（§3.4）** → prompt 輸入框 → `AI 派工`（orchestrator 提案）→ `派 worker` / `派 reviewer`）＋ log viewer。
  - **右**：Review & Gate panel（Task Review 輸出、Lane 自審 / Final Reviewer 狀態、PASS/FAIL、merge）。（命名見 §4.0 正名表）
  - **底**：事件流（`run.meta` tail）＋ new-lane 表單（含 §4.3 的 workers/reviewers/final-reviewer 數量）。

### 3.2 Backend（`gui/app.py` + `gui/orchestrator.py`）
- **薄層 API**：每個 route 只做參數檢查 + `subprocess.run(["zsh", ORCH, <subcmd>, ...])`，回傳結構化結果。**不自建任何 guard**。
- **orchestrator.py**：local-LLM brain（見 §4 決策）。
- **pollers（零成本，硬性）**：狀態一律**純機械取得，絕不呼叫任何 LLM**——`run.meta` 純文字讀、`sessions/<role>-<task>/*.jsonl` 的 **mtime**（停滯，沿用 `ORCH_STALL_MIN`）、jsonl **tail 最後一行 raw action**（「在做什麼」，不叫 model 摘要）、`git log main..<branch>`（merge/ahead）、pi process 精確比對（角色數）。這是 §3.6.12。（注意：這些機械讀取的是 **Evidence / Runtime Detail**；current workflow state 的權威來源是 lane runtime metadata 的 `state`，見 `shells/orch/specs/00_WORKFLOW_STATE.md`，不得由上述 evidence 推導。）
- **模型目錄來源**：`GET /api/models` 直接跑 `pi --list-models`（＋ `pi auth check --provider <p>`）解析成「廠商 → 模型」樹，附各家 readiness；不寫死清單，pi 更新型錄就自動反映。

### 3.4 模型選擇 UI（廠商 → 模型 → Effort 強度）

每一個要用 LLM 的位置（orchestrator 判斷 / worker / reviewer 判斷審查 / Gate #2），選模型都走**三段級聯**，對齊 pi 的三個參數：

| UI 段 | 對應 pi 參數 | 選項來源 |
|-------|-------------|---------|
| **① 廠商 / gateway** | `--provider` | `copilot`（第一線，月費固定）、`metered`（anthropic / openai 直連）、`local`（vLLM） |
| **② 模型** | `--model` | 依廠商動態帶出（copilot：claude-opus-5 / gpt-5.6-* / gemini-3.x / grok-4.x / kimi…；local：Qwen3.8-27B）。灰掉 `ready≠yes` 的家 |
| **③ Effort 強度** | `--thinking` | `off / minimal / low / medium / high / xhigh / max`（dispatch 現值 `high`）。每個角色可有不同預設 |

- **每個角色一組級聯，且是「可加多列的優先序清單」**（不是單選）：一列 =（廠商, 模型, effort），往下即 §4.2 的 fallback chain。UI 支援 `＋ 加一列` 與拖曳排序。
  - 例：Gate #2 = `[(copilot, gpt-5.6-luna, xhigh), (metered, openai/gpt-5.6, high)]`。
- **Effort 與角色預設**：判斷／Gate 類預設 `high`↑（品質優先），worker 可用 `medium`（省時省配額），reviewer 機械檢查那段根本不吐 effort（純 Python）。
- **顯性標注**：每列即時顯示廠商 readiness、該 model 是否算 Copilot premium request；獨立性衝突（Gate 選到本 lane 已做事的家）當場紅字擋下（§4.1 約束 2）。
- **落地**：選完寫進 §4.2 的 `orch_models.json`（per-role chain），backend 傳給 `orch dispatch` 時展開成 `--provider/--model/--thinking`。UI 不自建任何 guard，只是把三個參數湊好交給機器層。

### 3.5 機器層可改（不是「不變」）
- 沿 §1：`orch` sub-scripts、`lib.sh`、`dispatch.sh`、`templates/*` **可以改**——加參數、把寫死值變輸入、重構都行（如 dispatch 的 provider/model/thinking 參數化）。
- 唯一不准的是**把 guard 複製進 GUI/backend**。guard 內容要調就調機器層那一份。

### 3.6 Phase-0 原型確認的 UX 決策（本輪定案）

以下是靜態原型（`gui/index.html`）驗收時定下、要一路帶進 Phase 1 的行為：

1. **PAUSE 是 per-lane，不是全域**：每張 lane 卡各有 PAUSE/RESUME。語義沿用機器層 `touch tmp/<run>/PAUSE`（[dispatch.sh](../dispatch.sh)）——**只擋派新 task，已派工的 in-flight 做完**。頂欄不再放全域 PAUSE。
2. **排程停止（下班時間）**：到某個時間就**不再分配新工作**，手上已派的 in-flight 做完（＝排程版 PAUSE）。典型場景：設 17:00 下班，到點所有 lane 停派工。
   - **兩層**：**全域「下班時間」**（一次設定，套用所有 lane，對應「人要下班了」）＋ **per-lane 覆寫**（某條 lane 想更早/更晚停）。與 rework 同模式（全域預設 + per-lane 覆寫）。
   - **落地**：backend 到點對該 lane（或全部）`touch tmp/<run>/PAUSE`；乾淨收尾精神同 `host_agent.py --duration`。全域下班時間存 runtime config、per-lane 存 `lane.conf`。到點只 PAUSE、**不殺 in-flight**。
3. **Merge 狀態是 lane 最關鍵資訊**：每張 lane 卡最顯眼處放 merge badge（`未合併 / 可合併(Gate PASS) / 合併中 / 已進 main`），未合併時附 `+N commits`。來源＝`git log main..<branch>` 與 `final_reviews/` 狀態。
4. **Lane 總覽列**：lane 牆上方一條摘要（lanes 數 / 未合併 / 已進 main / 可合併 / in-flight pi / 暫停數），一眼看全局。
5. **Cloud 供應商狀態 + on/off**：頂欄顯示每家 cloud 的**接通狀態**（connected，來源 `pi auth check` / metered 金鑰 / vLLM 可達）與**啟用開關**（on/off）。停用的家不進 §4.2 的 provider chain 選用。兩者分開：接通=能不能用，on/off=要不要用。
6. **Monitor 間隔可設定**：GUI 輪詢頻率使用者可選（2/4/8/15/30/60s）。**與這兩者不同**：後端停滯門檻 `ORCH_STALL_MIN`（判 worker 卡住，8min）、`orch watch --interval`（背景通知）。三者各管一層，別混。
7. **rework 上限 per-lane 可覆寫**：見 §4.3（全域 `ORCH_MAX_REWORK` 當預設，lane 可覆寫）；lane 卡與 in-flight worker 顯示 `rework n/max`。
8. **改組成數量不中斷 in-flight（硬性 invariant）**：在 live lane 上調 `workers`/`reviewers`/`final_reviewer` 數量，**只影響之後的派工，絕不中斷已派出去的 pi**。
   - **降數量**：已派的 worker/reviewer/Final Reviewer **跑到完**，只是不再派新的、超出的自然 drain 到新上限。
   - **升數量**：允許往上派到新上限（仍受 `ORCH_LANE_CAP`/`ORCH_PI_CAP` 夾住）。
   - **`final_reviewer` 從 1→0**：若該 lane 的 Final Reviewer 已在跑，**不殺它**；只代表不再派新的 Final Reviewer。
   - 與 PAUSE / 下班時間同一哲學：**永不 kill in-flight**。這是 guard，不靠 GUI 自律——機器層（dispatch）只認「還能不能派新的」，從不回頭中斷既有 pi。
9. **角色狀態可見**：每個 in-flight 角色（worker / reviewer / Final Reviewer）要能看到當下狀態，不只是「有在跑」：
   - **狀態**：`執行中 / 停滯 / rework 中 / 排隊 / 完成 / 失敗`。停滯判定沿用 `sessions/<role>-<task>/*.jsonl` mtime > `ORCH_STALL_MIN`（**不看 log**，log 到結束才 flush）。
   - **實際 model**：顯示該角色**真正跑的** provider/model，fallback 過的標記「↘ …（fallback）」——因為 §4.2 會讓實際模型偏離設定。
   - **在做什麼 + age**：`sessions` 最後活動摘要 + 已執行時間；rc 結束時顯示 `完成 rc=0 / 失敗 rc≠0`。
   - 資料來源：`run.meta`（start/end/rework/PROVIDER_FALLBACK）＋ `sessions/*.jsonl` mtime；**不靠 log 判進度**（曾誤殺正在寫入的 worker）。
10. **Lane 已工作時間**：每張 lane 卡顯示 `⏱ 已工作 Xh Ym`。來源＝lane 開工時間（`lane.conf` 建立時戳或首次 dispatch）到現在。方便判斷一條 lane 拖多久了。
11. **worker / reviewer 總數量統計**：lane 總覽列顯示各角色**當前在跑的數量**（`worker N · reviewer N · Final N`）＋排隊數，附全機 `pi N/ORCH_PI_CAP`。來源＝所有 lane 的 in-flight 依 role 彙總（沿用 `pi_running` 的精確比對，非模糊 pgrep）。
12. **監看零成本（硬性，最重要的成本紀律）**：**監看 worker/reviewer/Final Reviewer 的狀態，絕不能燒 token / 花錢**。所有狀態一律**純機械取得，不呼叫任何 LLM**：
    - 停滯 / age ← `sessions/*.jsonl` 的 **mtime**（檔案 stat）；「在做什麼」← jsonl **tail 最後一行 raw action**，**不是叫 model 摘要**。
    - 事件（start/end/rework/fallback）← `run.meta` 純文字；merge/ahead ← `git log`；角色數 ← pi process 比對。
    - 沿用 [README](../README.md) §32 哲學：「狀態計算放腳本、不放 agent 對話裡」。**Monitor 輪詢只讀檔案 / git / 行程，成本 = 0**。orchestrator 那顆會花錢的 cloud 判斷**只在派工 / Gate 決策時**才呼叫，**與監看分離**——監看再頻繁也不該觸發任何模型呼叫。
13. **Backlog 分配視圖**：一個面板顯示「哪些 backlog item 已分配、分到哪條 lane、誰在做、工作內容」。每列＝狀態（未分配 / 已分配·未派 / 排隊 / 進行中 / 審查中 / 完成·待合 / 已進 main）＋ BL-ID ＋ 標題 ＋ lane ＋ assignee，展開看**派工 prompt ＋ no_touch 禁改清單 ＋ 實際模型**。來源＝各 lane `lane.conf` 的 items ＋ `run.meta` 派工事件 ＋ `prompts/*.md`（純機械，§3.6.12）。用途：一眼確認「backlog 有沒有被派、派了在做什麼、有沒有漏 / 重複」。

### 3.7 每 phase 的 Pi log 與 Pi 自省（新增，本輪）

**每 phase 一個 Pi log（持久化）**
- Pi 的輸出**都要 log 起來**，而且**每個 phase 一個獨立 log**，讓「該 phase 做了什麼」可追溯、可回顧。
- **落地（機器層）**：`logs/<lane>/<stage>.log`，`stage ∈ dispatch / implement / local_review / final_review / integrate / merge_main / done`（§3.9）。pi 的原始輸出＋dispatch 的 start/end/rework/fallback 行寫入對應 stage log。`sessions/*.jsonl` 仍當**停滯偵測**來源（不變），stage log 是「可讀的完整版」。
- **GUI**：中欄的「Dispatch／Implement／Local Review／Final Review／Integrate／Merge Main／Done」各 stage 頁顯示**該 stage 的 Pi log**（每 stage 一個 log 入口）。「Dispatch」頁的「Pi 即時資訊」是**即時視圖**；per-stage log 是**持久化完整版**（切到該 stage 頁即可看）。

**Pi 自省 / 流程改善建議（預留）**
- 整個 lane 做完（merge 或明確收尾）後，**Pi 自己回頭看各 phase 的 log**，提出「哪些要列入流程改善」的建議（例如：no_touch 漏了哪些檔、為什麼停滯、fallback 幾次、rework 原因、哪個 guard 該調）。
- 本質是 **retrospective、產生改善建議**，**不是 gate**（不擋合併）；輸出是「建議清單」，由人決定採不採。
- **GUI**：中欄預留一個「**自省**」頁（現為佔位、未接），顯示：觸發條件（lane 是否已完成）、建議清單（範例格式：rework 原因／停滯／fallback／no_touch 漏洞）、`生成自省` 按鈕。
- **待決**：觸發時機與用哪顆 model（local／cloud；需獨立於 Final Reviewer 的獨立性要求）、建議存 `retro/<lane>.md`。

### 3.8 專案與 workdir 目錄結構（RobotProject / .piforge）

**一個「專案（Project）＝一個 `RobotProject/` 工作目錄**；專案下掛多條 lane（對應 GUI 左欄「專案 → Lanes」樹狀清單，§3.1）。**workdir＝該 `RobotProject/` 的根目錄**——找 / 存檔案都限在這個目錄內，會儲存起來；同一專案的多條 lane **共用同一個 workdir**（各是同一棵樹的不同 integration branch）。

預設目錄與檔案結構：

```
RobotProject/                       ← Project 的 repo_root / workdir（找/存檔案都限這裡）
├── src/                            ← 專案原始碼
├── docs/                           ← 專案文件
├── ...                             ← 其他專案內容
└── .piforge/                       ← 編排（orch）metadata（hidden，不混進產品原始碼）
    ├── project.yaml                ← Project Settings（repo_root / default_branch / validation / defaults）
    └── lanes/
        └── lane-001/
            ├── lane.yaml           ← Lane Settings（config：items / scope / composition / overrides）
            ├── state.json          ← Runtime State（state / branch / base_sha / session refs；orchestrator 寫）
            └── events.jsonl        ← 事件歷史（append-only）
```

- **設定分層（System / Project / Lane / Runtime / Specs）見 `shells/orch/specs/00_CONFIGURATION_MODEL.md`**：`repo_root` / workdir 是 **Project 屬性**（`project.yaml`），**lane 不存 workdir**；lane 透過 parent Project 取得 repo root。
- **lane 設定從 flat `lane.conf` 遷到 `.piforge/lanes/<lane>/lane.yaml`**：`orch new` 建 lane 時，在該專案 workdir 下寫 `project.yaml`（首次建專案）＋ `lanes/lane-XXX/lane.yaml`（每 lane 一份）。`lane.yaml` 承載 config 欄位（ITEMS / FILES / scope ＋ §4.3 的 workers / reviewers / final_reviewer / rework / stop_at；null＝inherit）。BRANCH / BASE_SHA 等執行期欄位存 `state.json`（runtime），不進 `lane.yaml`。
- **`.piforge/` 與執行期暫存分開**：`project.yaml` / `lane.yaml` 是**可版控的設定**，放專案 workdir 內；`run.meta` / `sessions/` / `logs/` / `heartbeat.log` 是**每次 run 的執行期產物**，維持在 `tmp/<run>/`（§8）。兩者不混。
- **GUI**：左欄樹的每個專案對應一個 `RobotProject/` repo_root（⚙ Project Settings 可改）；**New Lane 表單不再問 workdir**（repo root 取自 Project；從專案列「＋」進來時 Project 為 read-only context）；lane 詳細頁的 repo root 顯示該 Project 的繼承值、標明「要改請用 ⚙ Project Settings」；lane 設定在 `.piforge/lanes/<lane>/lane.yaml`（config）＋ `state.json`（runtime）＋ `events.jsonl`（history）。
- **機器層遷移（後續）**：本節是目標預設結構；`new.sh`／`lib.sh` 目前仍寫 flat `tmp/<run>/lane.conf`，遷移到 `.piforge/lanes/<lane>/lane.yaml` 屬 Phase 1 的機器層改動（§1 原則 2：參數化、集中單一真相來源）。

### 3.9 lane 執行階段流（七階段 + rework 回環）

> ⚠️ **LEGACY / PENDING MIGRATION**
>
> 此圖的 phase ordering 尚未依新版 workflow 更新。
> Current workflow state 的權威定義請以 `shells/orch/specs/00_WORKFLOW_STATE.md` 為準。
> **不要從此舊圖推導 runtime state。**

一條 lane 的執行流是下面的狀態機：happy-path 直線、三處 FAIL 各有一條 REWORK 回環。GUI 中欄 pipeline / 分頁即依此呈現（§3.1）。

```
DISPATCH
   ↓
IMPLEMENT
   ↓
LOCAL_REVIEW
   ├─ FAIL ───────────────┐
   │                      │
   ▼                      │
REWORK                    │
   │                      │
   └────→ IMPLEMENT ──────┘
   ↓ PASS
FINAL_REVIEW
   ├─ FAIL ───────────────┐
   │                      │
   ▼                      │
REWORK                    │
   │                      │
   └────→ IMPLEMENT ──────┘
   ↓ PASS
INTEGRATE
   ├─ FAIL ───────────────┐
   │                      │
   ▼                      │
REWORK / FIX_INTEGRATION  │
   │                      │
   └────→ INTEGRATE ──────┘
   ↓ PASS
MERGE_MAIN
   ↓
DONE
```

| # | 階段 | 誰做 | 過 → 下一站 / 不過 → 回環 | 對應 code |
|---|------|------|---------------------------|-----------|
| 1 | **DISPATCH** | orchestrator（Python 迴圈） | 派 worker → IMPLEMENT | `run.meta` dispatch 事件 |
| 2 | **IMPLEMENT** | pi worker（local 優先） | 交件 → LOCAL_REVIEW；被 REWORK 打回則重做 | `logs/<lane>/implement.log`、in-flight worker |
| 3 | **LOCAL_REVIEW** | ① Task Review（pi）＋② Lane 自審 | PASS → FINAL_REVIEW；**FAIL → REWORK → IMPLEMENT** | `reviews/<ID>.pi.md`、`gate1/` |
| 4 | **FINAL_REVIEW** | ⑤ Final Reviewer（獨立關、另一顆 model） | PASS → INTEGRATE；**FAIL → REWORK → IMPLEMENT** | `gate2/`（§4.0 正名） |
| 5 | **INTEGRATE** | 整合檢查（main 乾淨 + 全測 + autotest） | PASS → MERGE_MAIN；**FAIL → REWORK / FIX_INTEGRATION → INTEGRATE** | `merge --dry-run`、autotest |
| 6 | **MERGE_MAIN** | 合併（`merge --no-ff` → push） | 進 main → DONE | `MERGED_TO_MAIN` |
| 7 | **DONE** | 結案 | —（可觸發 Pi 自省，§3.7） | lane 狀態 `merged` |

- **REWORK 回環**：Local Review / Final Review 的 FAIL 都回到 **IMPLEMENT** 重做（`ORCH_MAX_REWORK` 上限，達頂沿 provider chain 換一家重打，§4.2/§4.3）；Integrate 的 FAIL 走 **REWORK / FIX_INTEGRATION**（修整合衝突、可只動整合不改實作）後重跑 INTEGRATE。
- **pipeline 是 happy-path 直線**（§3.1 中欄）：REWORK **不新增直線節點**，以 rework 計數（`rework n/max`）與 worker 狀態「↻ rework 中」呈現回環（§3.6.9）。
- **階段 ↔ per-stage log**（§3.7）：每階段一份 `logs/<lane>/<stage>.log`，`stage ∈ dispatch / implement / local_review / final_review / integrate / merge_main / done`。
- **機器層（state 權威來源）**：本節是流程定義。Lane current workflow state 的唯一權威來源是 Lane runtime metadata 的 `state`（存於 `state.json`；canonical 定義見 `shells/orch/specs/00_WORKFLOW_STATE.md`）。`run.meta` / events、gate result（`gate1/`、`gate2/`）、`git log main..<branch>`、in-flight agent、session activity 只能作為 **Evidence / Runtime Detail**，**不得用來推導或重建 current workflow state**。Backend `/api/status` 必須直接回傳 authoritative `state`；GUI 只 render，不推理。crash recovery / state reconstruction 屬 **future recovery mechanism**，目前不定義。

---

## 4. orchestrator brain（取代 codex 那顆）——關鍵決策

### 4.0 角色全景與兩個缺口（Intake / Planner）

先把整個系統的角色攤開。**目前的設計只有五個角色，沒有 Intake、也沒有 Planner**
（`grep -ri planner shells/orch/` 為空；[brief.md](../templates/brief.md) 明寫 orchestrator 只擔任「Manager + Gate #1」兩職）。

```
你（自然語言）
  │
  ▼
① Intake / 對話 agent   ← 缺！唯一面對「人 + 自然語言」、負責「回你訊息」的角色
  │   聽需求 → 問澄清 → 寫/改 backlog → 交棒
  ▼
② Planner              ← 缺！backlog → lane/task 切分 + 檔案互斥 + no_touch + 填 brief
  │
  ▼
③ Orchestrator loop    ← 有（本計畫 §4 規劃 Python + cloud 判斷取代 codex）
  │
  ▼
④ Worker / Reviewer    ← 有（pi，local）
  │
  ▼
⑤ Final Reviewer（獨立最終關）← 有（現為 opencode/Opus，拆 opencode 後改走 copilot/gpt；code: gate2）
```

| # | 角色 | 現在有嗎 | 現在誰代勞 | 面對自然語言？ |
|---|------|---------|-----------|--------------|
| ① | **Intake / 對話** | ❌ 無 | 你 ＋ opencode | ✅ 是（唯一） |
| ② | **Planner** | ❌ 無 | 人填 brief TODO ＋ orchestrator 兼 | 否 |
| ③ | **Orchestrator** | ✅ 有 | GPT-5.6 Luna（codex） | 否 |
| ④ | **Worker / Reviewer** | ✅ 有 | pi（local） | 否 |
| ⑤ | **Final Reviewer（獨立最終關）** | ✅ 有 | opencode（Opus 5） | 否 |

#### 審查三層的正名（誠實命名，只有一個真「Gate」）

系統有**三個審查點**，過去叫「reviewer / Gate #1 / Gate #2」容易誤會成同級。正名如下——
一個「Gate」的價值在**獨立性**，所以只有最後那道換一顆 model 獨立重跑的關卡配叫 Gate；前兩層是「審查」：

| 本文用語 | 誰做 | 本質 | 獨立性 | **對應 code（不動）** |
|---------|------|------|--------|----------------------|
| **Task Review** | pi reviewer | 逐個 worker task 審 | 半獨立（不同 pi） | `reviews/<ID>.pi.md`、§4.3 的 `reviewers` |
| **Lane 自審** | orchestrator 自己 | 審自己整條 lane 的產出 | ❌ 自審，非 gate | `final_reviews/gate1/`、`brief.md` 第 2 職、`action:gate1_review` |
| **Final Reviewer** | 獨立的另一顆 model | 決定是否進 main | ✅ 唯一真 gate | `final_reviews/gate2/`、§4.3 的 `final_reviewer`、`merge.sh` |

> 命名只改本文。**code 的 `gate1/`、`gate2/`、`final_reviewer`、`gate1_review` 一律不動**（避免 doc/code drift）。
> 本文其餘處若寫「Gate #2」＝ **Final Reviewer**、「Gate #1」＝ **Lane 自審**，皆對應上表 code 名。
> 關 `final_reviewer=0`＝關掉 **Final Reviewer**（Task Review 與 Lane 自審不受影響）。
> **GUI 顯示名＝Final Reviewer**：本文顯示名已對齊 GUI 用詞；**本質仍是獨立 Gate**（code 仍為 `gate2/`、`final_reviewer`，獨立性論述不變）。

**兩個缺口的本質**：拆掉 opencode 等於拆掉它的三個身分——嘴（①對話）、腦（③orchestrator）、獨立審查（⑤Final Reviewer）。
本計畫原本只規劃取代腦與手，**①這張「回你訊息的嘴」一直沒指派替代者**。②Planner 則是「規劃」這件事今天被人與 orchestrator 分著兼、沒有專職。
brief §0 事故清單裡最貴的錯（task 過肥、`no_touch` 漏檔重造 2000+ 行）全發生在**規劃階段**，正說明②值得獨立。

**實施順序（可先做 ③④⑤、①②留後）**：
①② 缺席時由**人肉代勞**——你自己維護 backlog、自己填 brief 的 TODO，系統從「backlog 已存在」起跑，③④⑤ 就能動。因此：

1. **先讓 ③④⑤ 在 GUI 裡跑通**（＝ §6 Phase 1，人按按鈕；①② = 你本人）。唯一要換的是 ⑤ 從 opencode → `copilot/gpt`（機制不變、只換模型）。
2. **再補 ② Planner**：local/cloud 產「填好的 brief 提案」，人確認（§6 Phase 2.5）。
3. **最後補 ① Intake**：GUI 加對話框，cloud frontier 接自然語言 → 澄清 → 寫 backlog（§6 Phase 3.5）。範圍決定見下。

**範圍抉擇（要先拍板）**：
- **(A) backlog 驅動**：你維護 backlog，系統只把既有 backlog 做完。無對話框。最小最快＝先做 ③④⑤。
- **(B) 對話驅動**：你用自然語言講需求，①回你、幫你變 backlog → ②拆 → ③執行。這才是完整取代 opencode，但多 ①② 兩層。
- 建議：**先落地 (A) 的 ③④⑤，再沿 ②→① 往 (B) 加**，不必一次到位。

### 4.1 orchestrator brain（取代 codex 那顆）

orchestrator 是「比 worker 更長壽」的 agent（跨多 task 循環），所以**不重用** `pi --print`（那是一發一 flush、75min timeout 的 worker 模型）。

| 選項 | 說明 | 評估 |
|------|------|------|
| **A（建議）**：Python loop 直連 vLLM chat API + `orch` subprocess 當 tool | 手寫一個薄 agent loop：讀 backlog+brief → 呼叫 vLLM 拿**結構化決策（JSON）**→ 執行 `orch` → 輪詢 → 再判斷。tools 集很小（`read_status`、`dispatch`、`read_diff`、`propose_review`）。 | 控制力最強、最貼「規則即 guard」、無新框架依賴。**採用** |
| B：長壽 local agent harness（pi/codex 式）當 orchestrator | 重用 pi，但需 pi 支援長壽互動 tool loop；且會造成「orchestrator 與 worker 同 model」的獨立性問題。 | 備選，不建議第一期 |

**決策輸出契約（vLLM 回 JSON，backend 硬解析，解析失敗=重試）**：
```json
{
  "task": "BL-GESTURE-007",
  "action": "dispatch_worker|dispatch_reviewer|gate1_review|rework|stop",
  "prompt": "…（worker/reviewer 用，含禁改清單）…",
  "no_touch": ["既有實作檔1", "…"],
  "needs_human": false
}
```
> `no_touch` 必須把既有實作檔**逐一列進**（brief.md §6：只寫「若已實作 STOP」不夠，worker 看不到檔名就不會停）。

### system prompt 來源
直接引用 `templates/brief.md` 的規則（lane 併發、派工規則、驗收、事故清單）＋ 任務上下文。不另寫一套規則。

### 4.1 角色 × 模型分工（本輪定案）

先破一個框架：**orchestrator 不是「一顆 LLM」，是「Python 迴圈（driver）＋ 在判斷點呼叫 LLM」。**
orchestrator 的工作有兩種，只有一種需要模型：

| 工作 | 需要 LLM？ | 誰做 |
|------|-----------|------|
| 讀 status、停滯偵測（`sessions/*.jsonl` mtime）、`orch dispatch`、輪詢、rework 計數 | 否 | 純 Python（規則） |
| 決定派哪個 task、寫 prompt、列 `no_touch`、Gate 判斷 | 是 | 強模型（見下表） |

> 因此「要不要升級到 cloud」由 **Python 規則**決定（rework 到頂、Gate 一律升級…），
> **不讓 local LLM 當「決定何時呼叫 Claude」的路由器** —— 那是把最弱的模型放在槓桿最大的位置。
> 這修正了 §4 選項 A 原本「orchestrator 判斷直接用 local vLLM」的假設：**迴圈留 Python、判斷上 cloud**。

角色 × 模型（每格是**優先序清單**，非單選 —— 見 §4.2 fallback）：

cloud 一律優先走 **Copilot gateway**（月費固定，pi 內建、已 `ready`；見 §4.2）；`copilot/<model>` 用完配額再退 metered API。

| 角色 | provider chain（由高到低） | 理由 |
|------|------|------|
| **Orchestrator 迴圈** | 純 Python，無 LLM | 機械層不需要模型；guard 在 `dispatch.sh` |
| **Orchestrator 判斷**（派工決策 / prompt / `no_touch`） | `[copilot/claude-opus-5, metered-claude, local]` | token 少（68:1 下絕對量便宜）、槓桿高；一個爛決策浪費整個 worker run。Copilot 配額用完才退 metered，再不行才退 local 並標「降級中」 |
| **Worker** | `[local, copilot/<cheap>, metered]` | 成本重心，唯一大量吐 token 的角色；68:1 全靠它在 local。**預設 local**，escalation 先往 Copilot 便宜 model（不燒 metered 額度） |
| **Reviewer** | 機械檢查：純 Python／local；判斷審查：`[copilot/<frontier>, metered, local]` | 機械層（tests 綠、diff 非空、單行 >120、既有實作 grep）local 就夠；判斷型審查（語義偷換、fake 綠）優先 Copilot frontier |
| **Final Reviewer / Gate #2** | `[copilot/gpt-5.6, metered-gpt]`，runtime 必須排除「本 lane 實際做事的家」 | §7 最致命：Gate 價值＝另一顆夠強的 model 獨立重跑，同顆審自己盲點相同。可為 0（見 §4.3） |

**兩條不可破壞的約束（fallback 後仍要成立）：**
1. **成本**：worker chain 必須 **local 排第一**，不是平等三選一。worker 預設走 cloud＝拆掉這套系統省錢的存在理由（68:1）。
2. **獨立性**：Gate #2 排除的不是「設定上的家」而是「**runtime 實際用的家**」。fallback 會讓實際模型跟設定不同，所以獨立性要在**執行時**判：讀該 lane 各 commit 的 `Model:` trailer，Gate 從 chain 裡挑第一個「沒出現過」的家。挑不到就標 needs_human。
   `AGENTS.md` 的 commit `Model:` trailer 與 author 規則正好讓「誰真的做了事」可追溯，是這條 runtime 判斷的資料來源。

**escalation 規則（Python 硬判，不靠模型自覺）：**
- worker：同一 task `rework_count` 達 `ORCH_MAX_REWORK` → 下一次沿 chain 往下換一家（local→cloud）重打（沿用既有 rework 上限 guard）。
- reviewer：local 機械檢查先過一遍 → 過的才送判斷審查那條 chain（抓 sycophancy）。
- gate：一律走 cloud chain，且 runtime 排除已用過的家（見約束 2）。

### 4.2 provider 池、fallback 與額度耗盡（因應「額度隨時可能不足」）

**每個角色的模型是「可多選的優先序清單」，不是單選。** backend 依序嘗試，某一家額度用完 / rate-limit / 401 就**自動退下一家**，全程記錄實際落到哪家。

**核心發現：Copilot 是月費固定的 cloud gateway，pi 已內建、已登入。**
`pi --list-models` 的 `github-copilot/*` 涵蓋 claude-opus-5 / claude-sonnet-5 / gpt-5.6-* / gemini-3.x / grok-4.x / kimi-k3…；`pi auth check --provider github-copilot` = `ready`。
所以 cloud 呼叫**優先走 `copilot/<model>`**：一個訂閱 front 住所有 frontier model、**固定月費**，正面解「額度隨時不足」。
dispatch.sh 目前寫死 `--provider local-vllm`，只要照 §1 原則 2 把 **provider+model 參數化**（不是分叉腳本）即可切換，無需自寫任何 adapter —— pi 已經講這條協定。

- **provider 池（修正版，優先序）**：
  1. `copilot/<model>` —— **固定月費 gateway，cloud 第一線**（Claude / GPT / Gemini / Grok 都在裡面）。
  2. `metered`（Anthropic / OpenAI 直連 API）—— Copilot premium-request 配額撞頂時的第二線。
  3. `local`（vLLM Qwen3.8-27B）—— worker 預設 / cloud 全滿時的保底。
  - 註：Copilot 仍有 per-plan premium-request 配額與 rate limit（某些 model 每次算一個 premium request），重度 orchestration 可能撞到 → 所以仍需 fallback，只是把 Copilot 排在 metered 前面。
- **fallback 觸發條件（Python 判，不靠模型自覺）**：額度／premium-request 耗盡 / 429 / 5xx / 逾時 / 金鑰或 OAuth 失效。可重試的先重試 N 次，再退下一家。
- **降級要顯性**：退到較弱一家時，在 `run.meta` 寫 `PROVIDER_FALLBACK role=<> want=<> got=<>`，GUI 頂欄亮「降級中」燈。**絕不靜默降級**（品質天花板變了，人要看得到）。
- **provider 設定放 config，不寫死**：per-role chain 存成一份 `orch_models.json`（沿用專案「fallback 要明確標示」的既有精神）。GUI 可勾選啟用哪幾家、拖動優先序。
- **獨立性仍優先於 fallback**：Gate #2 的 chain 再怎麼退，都不能退到「本 lane 已做事的那家」；寧可 needs_human 停下，也不破獨立性。同一個 Copilot 訂閱底下 `claude-opus-5` 與 `gpt-5.6` 算**不同家**，獨立性用「model 家族」判、不是用「provider/訂閱」判。

### 4.3 lane 組成可調（worker / reviewer / final reviewer 數量）

lane 不再固定「2 worker + 1 reviewer」，改成**每條 lane 開工時可設**，GUI new-lane 表單提供欄位：

| 欄位 | 預設 | 範圍 | 對應 guard |
|------|------|------|-----------|
| `workers` | 2 | 1–N | 受 `ORCH_LANE_CAP`、全機 `ORCH_PI_CAP` 夾住 |
| `reviewers` | 1 | 0–N | 0＝不派 lane 內 pi reviewer（只靠 Gate） |
| `final_reviewer`（＝ Final Reviewer，code: gate2） | 1 | **0 或 1** | 0＝**跳過 Final Reviewer** |
| `rework`（每 task 上限） | 全域 `ORCH_MAX_REWORK`（5） | 0–N | per-lane 覆寫全域預設；沿用 [dispatch.sh](../dispatch.sh) 的 rework guard |
| `stop_at`（排程停止 / 下班時間） | 全域下班時間 | HH:MM 或空 | 到點 `touch PAUSE`：只停派工、in-flight 做完（§3.6.2） |

- **數量仍受既有 guard 夾住**：`workers + reviewers` 不得超過 `ORCH_LANE_CAP`（預設 3），全機不超過 `ORCH_PI_CAP`（預設 8）。GUI 只是把這兩個上限**開放成 per-lane 可調參數**傳給 `orch`，**不自建第二套上限**（原則 §1）。
- **final_reviewer = 0 的語義**：跳過 Gate #2。merge 時 `merge.sh` 走既有的「找不到 Gate #2 報告」分支（[merge.sh](../merge.sh) warn + 人工 confirm），**不是硬擋**。即：關掉 Gate #2＝把最後把關責任交回人手動 confirm。
- **顯性警告**：final_reviewer = 0 時 GUI 要紅字標「已關閉獨立 Final Reviewer，合併僅靠人工確認」。這是 §7「審查獨立性最致命」的手動 opt-out，**預設不關**。
- **rework 覆寫**：全域 `ORCH_MAX_REWORK` 當預設，lane 可覆寫（難的 lane 給多幾次）。lane 卡與 in-flight worker 顯示 `rework n/max`（§3.6.7）。
- **stop_at / 下班時間**：per-lane 覆寫全域下班時間；到點只 PAUSE、不殺 in-flight（§3.6.2）。
- **落地方式**：這些值寫進 `lane.conf`（orch 的單一事實來源），`orch new` 收 `--workers/--reviewers/--final-reviewer/--rework/--stop-at`，dispatch/merge 讀 `lane.conf`。GUI 只是表單 → 參數。

---

## 5. API 草圖（GUI 與 backend 的契約）

| Method | Path | 對應 |
|--------|------|------|
| GET | `/api/status` | 包 `orch status` → lanes/occupancy/tokens/stall；每 lane 必含 `state`（canonical workflow state，SSoT；PAUSED/BLOCKED/FAILED 附 `resume_state`），見 `shells/orch/specs/00_WORKFLOW_STATE.md` |
| GET | `/api/models` | 跑 `pi --list-models` ＋ `pi auth check` → 廠商→模型樹（readiness、premium 標記），餵 §3.4 選擇器 |
| GET | `/api/lanes/:name/meta` | `run.meta` tail |
| GET | `/api/lanes/:name/logs?role=&task=` | `logs/` 或 `sessions/` tail |
| POST | `/api/lanes` | `orch new <name> --items --files [--workers --reviewers --final-reviewer]`（§4.3） |
| POST | `/api/lanes/:name/dispatch` | `orch dispatch <run> worker\|reviewer <task> <promptfile>`（展開 §3.4 選的 `--provider/--model/--thinking`） |
| POST | `/api/lanes/:name/verify` | `orch verify <name> [--with-main] [--ref]` |
| POST | `/api/lanes/:name/merge` | `orch merge <name> [--dry-run] [--no-push]` |
| POST | `/api/lanes/:name/pause` | `touch/rm $RUN/PAUSE` |
| POST | `/api/orchestrator/propose` | 呼叫 orchestrator brain → 回「派工提案」（**不直接執行**，MVP 由人確認） |

---

## 6. 分階段實施

| Phase | 交付 | 驗收 |
|-------|------|------|
| **0**（本輪） | `gui/index.html` 靜態 prototype（可看可點、sample 資料、endpoint 已對齊 §5） | `open gui/index.html` 版型正確、無 backend 時顯示「靜態預覽」 |
| **1** | `gui/app.py` 薄層：真實 `orch status` + 手動 new/dispatch/verify/merge（**人按按鈕**） | 同一批 backlog，GUI 跑通 new→dispatch→review→gate2→merge；guard 行為與現行一致 |
| **2** | `orchestrator.py`：`/api/orchestrator/propose` 用 local LLM 產「派工提案」（人確認後才 `orch dispatch`） | 提案含正確 `no_touch` 清單；人可改可丟 |
| **3** | orchestrator 自主跑 review / rework 判斷（仍保留人按 Gate 結論） | rework 上限、PAUSE 不被繞過 |
| **4** | Gate #2 獨立性強化（見 §7） | 全過程無任何 cloud 呼叫 |

---

## 7. 風險與緩解

| 風險 | 說明 | 緩解 |
|------|------|------|
| **判斷品質天花板** | 現行靠 cloud 做判斷；全 local 後派工 prompt 品質、驗收誠實度掉到 local 等級 → rework 暴增 | 前段人確認（§6 Ph2）；`brief.md` 事故清單當 system prompt 硬提醒 |
| **sycophancy 驗收** | local model 易「採信 worker 自述已完成」，不看 diff / 不跑驗證 | backend 強制：`dispatch reviewer` 前檢查 `git log base..HEAD` 非空（brief §4 事故：rc=0 卻沒 commit）；PASS/FAIL 前必須附 diff + 關鍵驗證輸出 |
| **審查獨立性（最致命）** | Gate #2 價值＝「另一顆足夠強的 model 獨立重跑」；全 local 同 model 審自己，blind spot 相同 | ① Gate #2 保持**機械化 checklist**（`verify.md`：pi 只回報事實、不下判斷，PASS/FAIL 照事實打勾）；② 若環境允許，Gate #2 換**不同的 local model**；③ 初期 Gate 結論保留人按 |
| **停滯 / 誤殺** | 曾誤殺正在寫入的 worker（log 空白≠沒在動） | 沿用 `sessions/ *.jsonl` mtime（`ORCH_STALL_MIN`=8min）判斷，**不看 log**；GUI 只顯示、不主動殺 |
| **第二真相來源** | backend 若自建 guard，會與 `orch` 漂移 | 原則 §1：backend 一律 subprocess `orch` |

---

## 8. 目錄結構

```
shells/orch/
  gui_plan.md          # 本檔
  gui/
    index.html         # 前端（單一檔，no build）—— Phase 0
    app.py             # FastAPI 薄層（包 orch）—— Phase 1
    orchestrator.py    # local-LLM brain —— Phase 2
    (static/ 視需要拆分)
```

> 每個**專案 workdir（`RobotProject/`）** 的目錄與檔案結構（含 `.piforge/` metadata、`project.yaml`、`lanes/lane-XXX/lane.yaml`）見 **§3.8**；執行期暫存（`run.meta` / `sessions/` / `logs/`）維持在 `tmp/<run>/`。

## 9. Tech stack
- **Backend**：Python 3.11（`.venv`）+ `fastapi` + `uvicorn`；`subprocess` 呼叫 `zsh orch`；vLLM 走 `httpx`。僅綁 `127.0.0.1`。
- **Frontend**：單一 `index.html`（vanilla HTML/CSS/JS，無 build）。
- **本地推理**：既有 local vLLM（`Qwen3.8-27B-nvfp4`），key 讀 `secrets/local-vllm-api-key.json`（不進版控）。
- 新增依賴：`fastapi`、`uvicorn`、`httpx`（其餘 numpy/opencv 既有）。

## 10. 開放問題（Phase 0→1 前要定）
1. ~~Gate #2 用「同顆 local model」還是「另一顆」？~~ **已定案（§4.1）**：Gate #2 用 cloud，且與 orchestrator 判斷「不同家」。
2. ~~orchestrator 用選項 A（Python loop 直連 vLLM）確認？~~ **已定案（§4.1）**：採選項 A 的迴圈骨架，但**判斷點上 cloud**，local vLLM 只留給 worker。
3. GUI 授權：localhost 先免 auth 可接受？（後續若開放網路需加）
4. backend port（建議固定如 `127.0.0.1:8790`）與 `orch` 執行環境（PATH、`REPO` root）如何注入？
5. cloud 判斷用哪家當 orchestrator、哪家當 Gate #2？（§4.1 只定「不同家」；§4.2 已改成優先序清單＋fallback，仍需定各角色的**預設排序**）
6. cloud 呼叫的憑證與計費來源？（orchestrator 判斷／reviewer／Gate 都會打 cloud，需定 API key 管理與成本上限）
7. Copilot premium-request 配額實測：這台的方案每月額度多少？orchestrator + reviewer + gate 一天大概吃幾個 premium request？撞頂前 metered 第二線要不要預設開？
8. `orch_models.json`（§4.2 per-role provider chain）與既有 `fallback.json` 的關係：合併還是各管一層？
9. metered 第二線（Anthropic / OpenAI 直連）要不要現在就備 key，還是先全押 Copilot、撞頂再說？
