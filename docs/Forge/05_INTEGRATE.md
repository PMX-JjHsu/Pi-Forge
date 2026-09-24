# Phase 05 — INTEGRATE

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

把已通過 Local Review 的 Task commit 整合進該 Lane 的 integration branch，並在整合後狀態執行 build / test / integration validation。

**Final Review 必須看 integrated state，而不是只看孤立的 Worker branch。**

## 2. Entry Conditions

- 所有要整合的 Task 已 `LOCAL_REVIEW = PASS`。
- 每個 Task 有明確 commit。
- Lane integration branch 存在。
- 未發現未協調 file overlap。
- integration order 已決定。

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Pi Forge / Lane Integrator** | 本 Phase Owner。控制 integration order、squash/merge policy、build/test。 |
| **Local Lead** | 提供 Lane summary、Task dependency、已知風險。 |
| **Worker** | 不自行 merge integration branch；若整合失敗才被重新派 rework。 |
| **Local Reviewer** | 必要時可針對整合後差異做補充 review，但不寫 code。 |

## 4. 必須做

- 將 Task commits 整合至 Lane integration branch。
- 解 conflict 時只 stage 明確處理的檔案。
- 跑 lane-level build。
- 跑 automated tests。
- 跑 integration tests。
- 跑 project-specific validation。
- 若 real path 可用，至少跑一次真實模型/真實資料。
- 檢查 forbidden path。
- 檢查 unexpected uncommitted files。

## 5. 禁止

- 不得用 `git add -A` 當 conflict 解法。
- 不得在 shared main worktree `git reset --hard`。
- 不得把 integration failure 當作 Final Reviewer 的問題。
- 不得在 Integration 尚未 PASS 時送 Final Review。

## 6. Metadata

```yaml
state: INTEGRATE
integration:
  branch: integration/<lane>-<run>
  status: RUNNING | PASS | FAIL
  tested_commit: <sha>
  report: reports/<lane>.integration.md
```

## 7. Transition

```text
INTEGRATE
   ├─ PASS → FINAL_REVIEW
   └─ FAIL → INTEGRATION_REWORK
```

## 8. Exit Criteria

整合後的 branch 有可重現的 validation evidence，且 `integration.status = PASS`。
