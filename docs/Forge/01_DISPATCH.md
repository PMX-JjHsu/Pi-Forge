# Phase 01 — DISPATCH

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

把一個已經明確定義的 Task / Backlog item 指派到正確的 Lane、角色、branch/worktree 與 Pi session，並建立可追蹤的執行狀態。

本 Phase **不做需求分析與大型規劃**。目前版本假設 Task / AC / scope 已經存在，Pi Forge 從 DISPATCH 開始執行。

## 2. Entry Conditions

進入 DISPATCH 前必須滿足：

- Project 已被 Pi Forge 辨識。
- Lane 已建立或可建立。
- Task ID 已存在。
- Scope / Allowed Files / Forbidden Files 已明確。
- Acceptance Criteria 與 Validation 已明確。
- Dependency 已滿足。
- 不與其他 active Lane 發生未協調 file overlap。
- Git main / base SHA 已確認。
- 對應 provider / model / local runtime 可用。

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Pi Forge Orchestrator** | 本 Phase Owner。建立/更新 Lane metadata、分配 Worker/Reviewer、決定 worktree/branch、啟動 Pi runtime。 |
| **Scheduler** | 檢查 dependency、lane capacity、file ownership、concurrency、blocked state。 |
| **Pi Runtime** | 接收明確 prompt 並啟動指定 agent session；不自行決定 workflow。 |
| **Worker / Reviewer** | 此階段尚未開始實作，只接受被指派的工作。 |

## 4. Pi Forge 必須做

1. 取得 Project + Lane。
2. 建立或確認 Lane metadata。
3. 建立 Task branch / isolated worktree。
4. 記錄 base SHA。
5. 記錄 assigned role。
6. 記錄 Pi session reference（如果 runtime 提供）。
7. 寫入 task prompt。
8. 確認同一 worktree 不會被多個 Worker 同時寫入。
9. 更新 Lane state：

```yaml
state: DISPATCH
task_id: BL-XXX-001
branch: task/BL-XXX-001
worktree: tmp/<run>/worktrees/BL-XXX-001
assigned_worker: worker-1
local_review: PENDING
final_review_1: PENDING
final_review_2: PENDING
```

10. 啟動 Worker 後轉入 `IMPLEMENT`。

## 5. 不應做

- 不讓 Worker 自己選 Task 範圍。
- 不讓 Worker 自己決定是否需要 Reviewer。
- 不直接改 main。
- 不把多個會寫同一檔案的 Worker 同時派出。
- 不因為 Pi session 還存在，就假設 Task 一定可以 Resume；必須以 Lane metadata + Git state 判斷。
- 不解析 Pi 內部 conversation/cache 來推測 state。

## 6. Outputs

至少產生：

- Lane metadata
- Task prompt
- branch / worktree
- base SHA
- role assignment
- Pi session reference（如有）
- `run.meta` / event record

## 7. Transition

```text
DISPATCH
   ├─ READY  → IMPLEMENT
   └─ BLOCKED → BLOCKED / 等待外部條件
```

## 8. Exit Criteria

只有以下條件都成立才可離開：

- Worker 已明確指派。
- worktree/branch 已建立。
- Prompt 可讀且非空。
- scope / validation 已傳入 Worker。
- Lane metadata 已持久化。
