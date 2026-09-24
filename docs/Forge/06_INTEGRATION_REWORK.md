# Phase 06 — INTEGRATION_REWORK

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

處理「單一 Task 自己是好的，但放進 Lane / Project 整合後出問題」的情況。

典型問題：

- merge conflict
- interface mismatch
- cross-module regression
- build failure
- integration test failure
- config/schema contract 不一致
- 多 Task 交互作用

## 2. Entry Conditions

`INTEGRATE = FAIL`

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Pi Forge / Integrator** | 找出 failure owner、決定是 integration-only fix 還是退回原 Lane/Task。 |
| **Affected Worker(s)** | 修改造成整合失敗的 code。 |
| **Local Lead** | 協調跨 Task / 跨 Lane 依賴。 |
| **Local Reviewer** | 修改後重新執行 Local Review。 |

## 4. Failure Classification

### A. 純整合操作問題

例如：

- conflict resolution
- integration branch 操作錯誤
- missing symlink/runtime asset

可在修正後重新：

```text
INTEGRATION_REWORK → INTEGRATE
```

### B. Code / Contract 問題

例如：

- API 不相容
- regression
- schema mismatch
- 兩個 Lane 的假設互相衝突

必須：

```text
INTEGRATION_REWORK
   ↓
REWORK
   ↓
LOCAL_REVIEW
   ↓
INTEGRATE
```

不得直接在 integration branch 偷改 production code 然後宣告 PASS。

## 5. Metadata

```yaml
state: INTEGRATION_REWORK
integration_rework:
  reason: <summary>
  affected_tasks:
    - BL-XXX-001
  owner: <worker/lane>
  count: 1
```

## 6. Transition

```text
INTEGRATION_REWORK
   ├─ operation-only fix → INTEGRATE
   └─ code fix required → REWORK
```

## 7. Exit Criteria

Failure owner 已明確、修正路徑已選定，而且沒有繞過 Local Review。
