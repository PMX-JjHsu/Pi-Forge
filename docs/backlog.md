# orch GUI Backlog

上游規格：[`gui_plan.md`](gui_plan.md)（獨立 GUI / 全 local 開發 lane 指揮層，取代 opencode）。
本 backlog 只涵蓋「orch 開發工具 + GUI + orchestrator/Planner/Intake」這條 workstream，
**與產品 backlog（`docs/backlog.md` 的 `BL-*`）分離**，不共用 ID、不走產品的 Gate 查核。

## ID / 狀態慣例
- ID 前綴 `OG-`（Orch GUI），三碼流水號。與產品 `BL-ORCH-*`（Interaction Orchestrator）無關，勿混。
- 狀態：`TODO`（未開工）/ `WIP`（進行中）/ `DONE`（完成）/ `BLOCKED`（卡）/ `DECIDE`（待拍板，非實作）。
- 對應 gui_plan 章節寫在「§」欄，方便回查規格。

## 範圍抉擇（先拍板，影響要不要做 Phase 3）
- **(A) backlog 驅動**：人維護 backlog，系統只把既有 backlog 做完，無對話框。＝先做 Phase 1（③④⑤）。
- **(B) 對話驅動**：自然語言講需求 → ① Intake 回你、變 backlog → ② Planner 拆 → ③ 執行。完整取代 opencode。
- 現行建議：**先落地 (A)，再沿 ②→① 往 (B) 加**。見 OG-031。

---

## Phase 0 — 靜態原型（gui_plan §6 Phase 0）

| ID | § | 項目 | 說明 / 完成條件 | 依賴 | 狀態 |
|----|---|------|----------------|------|------|
| OG-000 | §3.1 | `gui/index.html` 靜態原型 | 單一 HTML、無 build、sample 資料、endpoint 對齊 §5；`open` 版型正確、標「靜態預覽」 | — | DONE |

---

## Phase 1 — 執行核心 ③④⑤ 在 GUI 跑通（人按按鈕；①② 由人肉代勞）

目標：同一批 backlog，GUI 跑通 new → dispatch → review → Final Gate → merge，guard 行為與現行一致。

| ID | § | 項目 | 說明 / 完成條件 | 依賴 | 狀態 |
|----|---|------|----------------|------|------|
| OG-001 | §3.2/§5 | `orch status --json` | status.sh 增 `--json` 機器可讀輸出（lanes/occupancy/tokens/stall），不動人看版；backend 不再解析截斷文字 | — | TODO |
| OG-002 | §3.2 | FastAPI 薄層 `gui/app.py` 骨架 | uvicorn 綁 `127.0.0.1:8790`；每 route 參數檢查 + `subprocess zsh orch`；**不自建 guard** | OG-001 | TODO |
| OG-003 | §5 | `GET /api/status` 接上 index.html | index.html 由 sample 切真實 `/api/status`；斷線 fallback 靜態預覽 | OG-002 | TODO |
| OG-004 | §1/§3.4 | `dispatch.sh` provider/model/thinking 參數化 | 現寫死 `--provider local-vllm --thinking high`；改成參數（含 `github-copilot`），沿用既有防呆 | — | TODO |
| OG-005 | §4.3 | `new.sh` 收 lane 組成參數 | 加 `--workers/--reviewers/--final-reviewer` 寫進 `lane.conf`；受 `ORCH_LANE_CAP`/`ORCH_PI_CAP` 夾住 | — | TODO |
| OG-006 | §3.2/§5 | `GET /api/models` | 跑 `pi --list-models` + `pi auth check` → 廠商→模型樹（readiness、premium 標記），不寫死 | OG-002 | TODO |
| OG-007 | §3.4 | 模型選擇 UI（廠商→模型→Effort） | 三段級聯 + 可加多列 + 拖曳排序（＝fallback chain）；獨立性衝突紅字擋 | OG-006 | TODO |
| OG-008 | §5 | new/dispatch/verify/merge/pause endpoints | 對應 `orch new|dispatch|verify|merge` + PAUSE touch/rm；回結構化結果 | OG-002,OG-004,OG-005 | TODO |
| OG-009 | §3.1 | 人工 prompt 流程 | GUI 打 prompt → backend 寫 `prompts/<role>_<ID>.md` → dispatch（檔名/目錄定案） | OG-008 | TODO |
| OG-010 | §4.0 | Final Gate 由 opencode → `copilot/gpt` | 拆 opencode 後，Final Gate 換 `copilot/gpt-5.6`（機制/merge guard 不變，只換模型） | OG-004 | TODO |
| OG-011 | §4.2 | `orch_models.json` + fallback | per-role provider chain；額度/429/逾時自動退下一家；`run.meta` 記 `PROVIDER_FALLBACK` + GUI 亮「降級中」燈，絕不靜默 | OG-004,OG-006 | TODO |
| OG-012 | §4.1 | Final Gate runtime 獨立性檢查 | 讀本 lane 各 commit `Model:` trailer，Gate 從 chain 挑「沒出現過的家」；挑不到標 needs_human | OG-010 | TODO |

---

## Phase 2 — Orchestrator loop + Planner（gui_plan §6 Phase 2 / 2.5；② 補上）

| ID | § | 項目 | 說明 / 完成條件 | 依賴 | 狀態 |
|----|---|------|----------------|------|------|
| OG-020 | §4.1 | orchestrator loop（Python + cloud 判斷） | 選項 A：Python 迴圈讀 status → cloud 回 JSON 決策 → subprocess orch → 輪詢；解析失敗重試 | Phase 1 | TODO |
| OG-021 | §4.1/§5 | `POST /api/orchestrator/propose` | 產「派工提案」（含正確 `no_touch`），**不直接執行**，人確認後才 dispatch | OG-020 | TODO |
| OG-022 | §4.0 | **② Planner 角色** | backlog → lane/task 切分 + 檔案互斥 + `no_touch` + 填 brief 提案；人確認（brief §6.0 既有實作查核入迴圈） | OG-020 | TODO |
| OG-023 | §6 | 半自主 review / rework 判斷 | orchestrator 自跑 Task Review / rework，仍保留人按 Final Gate；rework 上限、PAUSE 不被繞過 | OG-021 | TODO |

---

## Phase 3 — Intake 對話層（gui_plan §6 Phase 3.5；① 補上，僅 (B) 需要）

| ID | § | 項目 | 說明 / 完成條件 | 依賴 | 狀態 |
|----|---|------|----------------|------|------|
| OG-030 | §4.0 | **① Intake / 對話 agent** | GUI 加對話框；cloud frontier 接自然語言 → 澄清 → 寫/改 backlog → 交棒 Planner | OG-022 | TODO |
| OG-031 | §4.0 | 範圍 (A)/(B) 拍板 | 決定要不要走對話驅動；(A) 則 Phase 3 不做 | — | DECIDE |

---

## 待拍板決策（gui_plan §10）

| ID | § | 決策 | 狀態 |
|----|---|------|------|
| OG-D01 | §10.3 | GUI 授權：localhost 先免 auth 可接受？ | DECIDE |
| OG-D02 | §10.4 | backend port（建議 `127.0.0.1:8790`）與 orch 執行環境（PATH、REPO root）注入方式 | DECIDE |
| OG-D03 | §10.5 | cloud 兩家怎麼分：哪家當 orchestrator 判斷、哪家當 Final Gate（只定「不同家」） | DECIDE |
| OG-D04 | §10.6/§10.9 | metered（Anthropic/OpenAI 直連）要不要現在備 key，還是全押 Copilot 撞頂再說 | DECIDE |
| OG-D05 | §10.7 | Copilot premium-request 配額實測：每月額度、一天吃幾個、metered 第二線要不要預設開 | DECIDE |
| OG-D06 | §10.8 | `orch_models.json` 與既有 `fallback.json` 的關係：合併還是各管一層 | DECIDE |

---

## 建議執行順序
1. **OG-001**（`orch status --json`）—— backend 資料地基,最先。
2. OG-002 → OG-003 —— 讓 GUI 顯示真實狀態。
3. OG-004 / OG-005 —— 機器層參數化,解鎖模型選擇與 lane 組成。
4. OG-006 → OG-007 —— 模型選擇 UI。
5. OG-008 → OG-009 → OG-010 → OG-011 → OG-012 —— 派工 + Final Gate + fallback 打通,Phase 1 收尾。
6. 再進 Phase 2（Planner）,最後視 (A)/(B) 決定要不要 Phase 3（Intake）。
