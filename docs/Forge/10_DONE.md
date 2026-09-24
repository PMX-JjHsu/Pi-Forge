# Phase 10 — DONE

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

正式結束 Lane / Request，凍結最終狀態並保留可稽核紀錄。

`DONE` 是終止狀態，不再做 coding/review/merge。

## 2. Entry Conditions

- `MERGE_MAIN` 成功，或
- 若 policy 設定 `auto_merge=false`，則已達到明確定義的 `READY_TO_MERGE` 終點。

目前若採自動 merge 流程，建議：

```text
DONE = merged to main + recorded
```

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Pi Forge Orchestrator** | 將 Lane 標記 DONE、保存 summary、停止派新 Task。 |
| **Git** | 提供最終 merge commit / history。 |
| **Pi Runtime** | 不再需要執行新的 Agent；既有 session 保留由 Pi 自己管理。 |

## 4. 必須保存

- final state
- completed_at
- final main SHA
- Lane branch / merge commit
- Worker commit references
- Local Review report
- Final Review Gate #1 report
- Final Review Gate #2 report
- Final Verification report
- rework counts
- relevant session references
- `run.meta` event history

## 5. Lane Metadata Example

```yaml
lane_id: lane-002
state: DONE

task_group:
  - BL-CFG-017
  - BL-CFG-018

local_review: PASS
integration: PASS
final_review_1: PASS
final_review_2: PASS
final_verification: PASS

merge:
  main_sha: <sha>
  merge_commit: <sha>

completed_at: 2026-09-24T14:30:00+08:00
```

## 6. Session / Temp Data Policy

Pi Forge 不需要解析 Pi internal session。

只需保留：

```text
role → Pi session reference
```

Pi 自己負責其 session/context/cache 格式。

Lane metadata、reports、run.meta 則由 Pi Forge 保留。

## 7. Cleanup Policy

第一版建議：

- **不要自動刪除 Lane metadata。**
- 可保留 logs/reviews/reports。
- Worktree 可另設 cleanup 指令人工清除。
- Cleanup 不應改變 DONE audit record。

## 8. Terminal Rule

```text
DONE
```

沒有下一個 workflow state。

若日後有新需求，建立新的 Task / Lane / Run，不把 DONE Lane 重新改回 WORKING。
