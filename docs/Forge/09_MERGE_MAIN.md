# Phase 09 — MERGE_MAIN

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

把已通過所有 Review 與 Verification 的 Lane integration branch 安全地合入 `main`，並留下可追蹤的 merge evidence。

## 2. Entry Conditions

全部必須成立：

- 所有 required Tasks 完成。
- 所有 Local Reviews PASS。
- Lane Integration PASS。
- Final Review Gate #1 PASS。
- Final Review Gate #2 PASS。
- Final Verification PASS。
- 當下 main SHA 已確認。
- main 沒有未處理的 remote advancement。
- merge candidate branch clean。

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Pi Forge Merge Controller** | Workflow 上的 Merge Owner；只有它能把 state 切到 MERGE_MAIN。 |
| **Current Merge Executor** | 目前部署可由 Final Reviewer #2 / Opus 5 執行實際 `merge + push`。 |
| **Worker / Local Reviewer / Gate #1** | 無 main merge 權限。 |

## 4. Merge Hard Rules

- Worker 不得 merge main。
- Local Reviewer 不得 merge main。
- Gate #1 不得 merge main。
- 不得在 verification 之前 merge。
- 不得用 main 當試驗場。
- conflict 只 stage 明確解決的檔案。
- merge commit 必須可追蹤兩道 Gate 結論與 report path。
- 多 Lane 同時完成時，一條一條 merge，不並行判決。

## 5. 建議流程

```text
READY_TO_MERGE
   ↓
refresh main
   ↓
confirm verified commit still matches
   ↓
merge --no-ff
   ↓
push
   ↓
record main merge SHA
   ↓
DONE
```

## 6. Metadata

```yaml
state: MERGE_MAIN
merge:
  source_branch: integration/<lane>-<run>
  verified_commit: <sha>
  main_before: <sha>
  merge_commit: <sha>
  pushed: true
```

## 7. Failure Handling

若 merge 前發現 main 已改變：

```text
MERGE_MAIN
   ↓
FINAL_VERIFICATION
```

若發生 conflict / integration behavior 變化：

```text
MERGE_MAIN
   ↓
INTEGRATION_REWORK
```

不得硬合。

## 8. Exit Criteria

- merge commit 成功。
- push 成功（若 policy 要求）。
- main SHA 已記錄。
- merge evidence 已寫入 metadata / run.meta。
