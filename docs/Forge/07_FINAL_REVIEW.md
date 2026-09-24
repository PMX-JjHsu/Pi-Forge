# Phase 07 — FINAL_REVIEW

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

對已完成 Lane Integration 的結果進行獨立 Final Review。

目前架構保留兩層 Final Gate：

1. **Final Review Gate #1**：偏 functional correctness / AC / regression / test evidence。
2. **Final Review Gate #2**：偏 architecture / maintainability / cross-module / requirement interpretation / 最終判決。

兩道 Gate 都 **不直接修改 code**。

## 2. Entry Conditions

- `INTEGRATE = PASS`
- Final Reviewer 看到的是 integrated branch / integrated commit。
- Lane report、Local Review report、test evidence 已存在。
- 但 Final Reviewer **不得直接相信這些 summary**，需要獨立確認。

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Final Reviewer #1** | 獨立驗證 AC、functional correctness、regression、edge cases、test/security/scope。 |
| **Final Reviewer #2** | 獨立判斷 architecture、cross-module impact、maintainability、requirement interpretation、integration correctness。 |
| **Pi Forge Orchestrator** | 啟動 Gate、保存 verdict、控制 fail transition；不讓 Reviewer 自己改 code。 |
| **Pi Reviewer Runtime** | 可負責機械驗證與原始事實收集；最終判斷仍由 Final Reviewer 做。 |

## 4. Gate #1

聚焦：

- AC completeness
- functional correctness
- logic bug
- regression
- edge cases
- test coverage
- error handling
- concurrency/security
- forbidden file modification
- contract violation
- fake/mock-only pass
- build/test evidence

結果：

```text
PASS | FAIL | BLOCKED
```

## 5. Gate #2

聚焦：

- architecture
- maintainability
- cross-module impact
- hidden coupling
- unnecessary complexity
- API/schema consistency
- product behavior
- long-term technical debt
- implementation 是否真的解決原問題

結果：

```text
PASS | FAIL | BLOCKED
```

## 6. Fail Rule

### Gate #1 FAIL

```text
FINAL_REVIEW_1 FAIL
   ↓
REWORK
   ↓
LOCAL_REVIEW
   ↓
INTEGRATE
   ↓
FINAL_REVIEW_1
```

### Gate #2 FAIL

```text
FINAL_REVIEW_2 FAIL
   ↓
REWORK
   ↓
LOCAL_REVIEW
   ↓
INTEGRATE
   ↓
FINAL_REVIEW_1
   ↓
FINAL_REVIEW_2
```

**Gate #2 fail 後不能只重跑 Gate #2。**

## 7. Metadata

```yaml
# runtime state（state.json 的 state；canonical，見 00_WORKFLOW_STATE.md）
# Gate #1 runtime state = FINAL_REVIEW_1
# Gate #2 runtime state = FINAL_REVIEW_2
state: FINAL_REVIEW_1     # Gate #1 進行中
# state: FINAL_REVIEW_2   # Gate #2 進行中

final_review_1:
  verdict: PASS | FAIL | BLOCKED
  report: final_reviews/gate1/<run>.md

final_review_2:
  verdict: PASS | FAIL | BLOCKED
  report: final_reviews/gate2/<run>.md
```

## 8. Transition

```text
FINAL_REVIEW_1（Gate #1 runtime state）
    ├─ Gate1 PASS → FINAL_REVIEW_2
    ├─ Gate1 FAIL → REWORK
    └─ BLOCKED    → BLOCKED

FINAL_REVIEW_2（Gate #2 runtime state）
    ├─ Gate2 PASS → FINAL_VERIFICATION
    ├─ Gate2 FAIL → REWORK
    └─ BLOCKED    → BLOCKED
```

## 9. Exit Criteria

兩道 Final Gate 都 PASS。
