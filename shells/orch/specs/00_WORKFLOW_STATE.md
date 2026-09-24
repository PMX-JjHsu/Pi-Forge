# 00 — WORKFLOW STATE（共用 · Single Source of Truth）

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: 所有 Lane phase spec（`01_DISPATCH` … `10_DONE`）與 GUI / API 共用的 workflow state 契約  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.  
> **Related**: 設定分層（System / Project / Lane / Runtime / Specs）見 `00_CONFIGURATION_MODEL.md`。

本檔是 Lane workflow state 的**共用契約**。各 Phase MD 只定義該 phase 的進入 / 離開條件與產出；「目前處於哪個 state」的權威定義與流轉，以本檔為準。

---

## 1. SSoT 原則

1. **`state`（存於 `lanes/<lane>/state.json`）是 workflow current state 的 Single Source of Truth。**
   由 Pi Forge / Orchestrator 在每次 state transition 時更新並寫回 `state.json`。
   `state` 是 **runtime state，不是設定**：`lane.yaml`（config）裡不存 `state`（分層定義見 `00_CONFIGURATION_MODEL.md`）。
2. **GUI 不得根據 gates / merge / inflight / worker status / review verdict / Pi session 推測 current state。**
   GUI 是 authoritative state 的 renderer，不是 workflow decision maker。
3. **Pi Forge owns workflow state。Pi runtime owns its session/internal state。Git owns branch/commit/source state。**
   三者邊界固定，互不越界：

   | Owner | 擁有 | 不擁有 |
   |---|---|---|
   | Pi Forge（orchestrator） | workflow state（`state` / `resume_state` / transition 紀錄） | Pi 內部 session 內容、git 歷史 |
   | Pi runtime | session、process、jsonl、agent 內部狀態 | workflow 流轉決策 |
   | Git | branch / commit / merge 結果（`git log main..<branch>`） | workflow state |

4. **Evidence 與 State 分家。** 下列項目都是 evidence / runtime status，**只能用於顯示與稽核，不能反向推理 current state**：

   - worker / reviewer / finalgate status（RUNNING / STALL / queued / rework…）
   - review verdict（Task Review / Lane 自審 / Final Review #1 / #2 的 `PASS | FAIL | BLOCKED`）
   - gate result（`gate1/`、`gate2/`）
   - merge status（open / ready / merging / merged）
   - process alive、session file mtime、`pi_session_id` / `pi_session_path` / `last_activity_time`
   - rework count

## 2. Pi Session 邊界

- Pi Forge **不解析 Pi internal session content**（conversation / cache / jsonl 內容）來決定 workflow state。
- 可以保存的 Pi runtime 參照（僅 evidence / runtime）：
  `pi_session_id`、`pi_session_path`（reference）、`last_activity_time`、process alive、session file mtime。
- 不因為 Pi session 還存在，就假設 Task 可以 Resume；能否 Resume 以 lane metadata + Git state 判斷。

## 3. Canonical States

目前正式支援的 workflow state（14 個）：

```text
DISPATCH
IMPLEMENT
LOCAL_REVIEW
REWORK
INTEGRATE
INTEGRATION_REWORK
FINAL_REVIEW_1
FINAL_REVIEW_2
FINAL_VERIFICATION
MERGE_MAIN
DONE
BLOCKED
FAILED
PAUSED
```

- 前 10 個是 happy-path + rework 回環的流轉 state；後 4 個是控制 / 異常 state。
- 未知 / 缺少的 `state` 不是合法輸入：GUI 照實顯示原值並標為異常，**不得**回退成推測。

## 4. `resume_state`（PAUSED / BLOCKED / FAILED）

`PAUSED` / `BLOCKED` / `FAILED` 不攜帶「原本在哪個 phase」的資訊。需要保留回復位置時，**必須**用明確 metadata：

```yaml
state: PAUSED
resume_state: IMPLEMENT
```

```yaml
state: BLOCKED
resume_state: FINAL_REVIEW_1
```

規則：

- `resume_state` **MUST** reference a valid canonical workflow state（含 `REWORK` / `INTEGRATION_REWORK`）。
- `resume_state` **MUST NOT** be `PAUSED` / `BLOCKED` / `FAILED`（控制 / 異常 state 不能當回復目標；例如 `state: PAUSED` + `resume_state: PAUSED` 是 **invalid metadata**）。
- `resume_state` **MUST NOT** equal current `state`。
- 違反上述任一條的 metadata 是 **invalid**：GUI 不得猜測 previous phase，pipeline 維持 **unknown / unhighlighted**。
- GUI 用 `resume_state` 決定 pipeline highlight；**不得**從 gates / inflight / merge 猜原始 phase。
- 沒有**有效** `resume_state`（缺、或值 invalid）的 `PAUSED` / `BLOCKED` / `FAILED` 是合法但資訊不完整：GUI 顯示該 state、pipeline 不 highlight 任何段（不猜）。
- Resume / 解阻時：orchestrator 把 `state` 設回 `resume_state` 並清除該欄位。

## 5. State Transition（happy-path + 回環）

```text
DISPATCH → IMPLEMENT → LOCAL_REVIEW
LOCAL_REVIEW FAIL  → REWORK → IMPLEMENT → LOCAL_REVIEW
LOCAL_REVIEW PASS  → INTEGRATE
INTEGRATE FAIL     → INTEGRATION_REWORK → INTEGRATE
INTEGRATE PASS     → FINAL_REVIEW_1 → FINAL_REVIEW_2 → FINAL_VERIFICATION
FINAL_REVIEW_1 FAIL → REWORK → IMPLEMENT → LOCAL_REVIEW → INTEGRATE → FINAL_REVIEW_1
FINAL_REVIEW_2 FAIL → REWORK → IMPLEMENT → LOCAL_REVIEW → INTEGRATE → FINAL_REVIEW_1 → FINAL_REVIEW_2
FINAL_VERIFICATION PASS → MERGE_MAIN → DONE
任一 state 可進入 BLOCKED / FAILED / PAUSED（附 resume_state）
```

- `REWORK` 是修正階段，不是審查階段；rework 的修正工作在 IMPLEMENT 段進行，修完回 `LOCAL_REVIEW` 重新驗證（詳見 `04_REWORK`）。
- `INTEGRATION_REWORK` 只修整合問題、可不改實作，修完重跑 `INTEGRATE`（詳見 `06_INTEGRATION_REWORK`）。
- retry 上限由 policy 控制；達上限 → `FAILED`（附 `resume_state`），不得無限回環。

## 6. Lane Data（config 與 runtime 分離，每 lane 必含）

`lanes/<lane>/` 下 config 與 runtime 是**兩種不同資料**：

### 6.1 `lane.yaml`（Configuration：這條 lane 要做什麼）

```yaml
lane_id: gesture
items: [BL-GESTURE-007]
scope:
  files: [collect.py]
composition: {workers: null, reviewers: null, final: null}   # null = inherit（Project → System）
policy: {rework_max: null}
schedule: {stop_dispatch_at: null}
model_overrides: {orchestrator: null, worker: null, reviewer: null, final_review: null}
```

- 人 / UI 可編輯；**不存** `state`、`branch`、`base_sha`、session、review verdict、rework count。
- 不存 repo_root / workdir（那是 Project 層）；不存 provider / API key / 全域 chain（那是 System 層）。

### 6.2 `state.json`（Runtime State：現在發生什麼）

```json
{
  "state": "IMPLEMENT",
  "resume_state": null,
  "branch": "integration/gesture",
  "base_sha": "9c1e7b0",
  "merge": "open",
  "workers": {"worker_1": {"status": "RUNNING", "session_ref": "abc123"}},
  "rework_count": 0,
  "local_review": "PENDING",
  "final_review_1": "PENDING",
  "final_review_2": "PENDING"
}
```

- 由 orchestrator 維護；GUI 可讀，但正常設定畫面不得讓使用者直接修改。
- `resume_state` 僅 PAUSED / BLOCKED / FAILED 時必填（§4）。
- evidence 欄位（可併存，但不得反向決定 state）：`merge`、review verdicts、inflight / worker status、
  rework count、`session_ref`、process/mtime。
- Runtime 事件（例如 provider fallback 到某 model）**只記錄在 `state.json` / `events.jsonl`，
  不得寫回 `lane.yaml`**（config 與 runtime 不得互相污染）。

## 7. API Contract（`GET /api/status`）

每個 lane 至少回：

```json
{
  "name": "gesture",
  "project": "Gesture",
  "state": "IMPLEMENT"
}
```

暫停 / 解阻相關 state：

```json
{
  "name": "gesture",
  "project": "Gesture",
  "state": "PAUSED",
  "resume_state": "IMPLEMENT"
}
```

- `state` 由 orchestrator 維護並經 `/api/status` 輸出；backend 不得在回應時臨場從 evidence 推測 `state`。
- GUI 收到後直接 render。

## 8. GUI Rendering 契約

- Lane detail 必須明確顯示 `Current State: <state>`；`PAUSED / BLOCKED / FAILED` 附 `↳ Resume State: <resume_state>`。
- 左欄 lane list 的 phase / status 優先來自 `lane.state`。
- Pipeline highlight 只做 `canonical state → happy-path phase index` 的 mapping（GUI `statePhaseIndex()`）：

  | State | Pipeline Highlight | Notes |
  |---|---|---|
  | DISPATCH | Dispatch | |
  | IMPLEMENT | Implement | |
  | LOCAL_REVIEW | Local Review | |
  | REWORK | Implement | Current State 顯示 REWORK（修正在 Implement 進行） |
  | INTEGRATE | Integrate | |
  | INTEGRATION_REWORK | Integrate | Current State 顯示 INTEGRATION_REWORK |
  | FINAL_REVIEW_1 | Final Review | |
  | FINAL_REVIEW_2 | Final Review | |
  | FINAL_VERIFICATION | Final Review | 無獨立節點，highlight Final Review 段 |
  | MERGE_MAIN | Merge Main | |
  | DONE | Done | |
  | BLOCKED | 依 `resume_state` | 無 `resume_state` → 不 highlight |
  | FAILED | 依 `resume_state` | 無 `resume_state` → 不 highlight |
  | PAUSED | 依 `resume_state` | 無 `resume_state` → 不 highlight |

- REWORK / INTEGRATION_REWORK / BLOCKED / FAILED / PAUSED **不新增 pipeline 節點**；回環以 Current State 標示 + rework 計數呈現。

## 9. Transition 記錄（`events.jsonl`）

- `state.json` ＝「現在怎樣」；`events.jsonl` ＝「曾經發生什麼」（append-only）。
- 每次 state transition 以一行 JSON 追加到 `lanes/<lane>/events.jsonl`（`time` / `event` / 觸發原因，例如 `LOCAL_REVIEW_FAIL`、`PAUSED reason=stop_dispatch_at`、`retry_limit`）。
- **不得**把 history 塞回 `lane.yaml`（config）或不斷累積在 `state.json`。
- transition 記錄是稽核 evidence；**讀取端（GUI）永遠以最新的 `state.json.state` 為準**。
