# Phase 02 — IMPLEMENT

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

由 Local LLM Worker 在隔離的 task worktree 內完成指定 implementation、必要測試與 commit。

## 2. Entry Conditions

- `DISPATCH` 已完成。
- Worker 有明確 Task。
- Allowed / Forbidden Files 已定義。
- Worktree 已建立。
- Dependency 已滿足。
- Validation command 已提供。

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Worker 1 / Worker 2** | 本 Phase 實作 Owner。修改 code、補 tests、跑 validation、commit。 |
| **Local Lead / Lane Controller** | 協調 Lane 內並行工作、避免寫入衝突、收 Worker 結果。 |
| **Pi Forge Orchestrator** | 追蹤 state、session、timeout、concurrency；不提前代替 Worker 寫 production code。 |
| **Pi Runtime** | 執行 Worker session。 |

## 4. Worker 必須做

- 一次只處理一個明確 Task。
- 僅修改 Allowed Files。
- 跑指定 validation。
- 必要時新增/修改 tests。
- 所有變更必須 commit。
- 回報：
  - changed files
  - validation/test result
  - unresolved issues
  - commit hash

建議 Worker Task 粒度：

- 10–15 分鐘為目標。
- 最多約 3 條主要 AC。
- 一個檔案或高度相關的一小組檔案。
- 太大就拆 task，不用壓縮排版硬塞進行數限制。

## 5. Worker 不得做

- 不得 merge main。
- 不得 push main。
- 不得修改其他 Lane 的檔案。
- 不得改 workflow state。
- 不得自行宣告 Final PASS。
- 不得修改 Lane metadata 的 authoritative state。
- 不得用 fake/mock-only evidence 取代可執行的 real-path validation。

## 6. Pi Forge 必須追蹤

```yaml
state: IMPLEMENT
worker_status: RUNNING | DONE | FAILED
worker_session_ref: <opaque reference>
worker_commit: <sha>
worker_validation: PASS | FAIL | BLOCKED
```

Pi Forge **只保存 session reference，不解析 Pi internal session content**。

## 7. Worker 完成後檢查

派 Local Reviewer 前至少確認：

- `git log <base>..HEAD` 非空。
- commit hash 存在。
- worktree 沒有意外 untracked delivery files。
- task output 沒超出 scope。

## 8. Transition

```text
IMPLEMENT
   ├─ Worker DONE + commit exists → LOCAL_REVIEW
   ├─ Worker needs correction     → REWORK
   └─ Runtime/Dependency blocked  → BLOCKED
```

## 9. Exit Criteria

- Implementation 已 commit。
- Worker validation 已執行並有 evidence。
- Worker 結果已回報。
- Pi Forge 已記錄 commit/session/status。
