# Phase 08 — FINAL_VERIFICATION

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

在進入 main 前做最後一次「合併條件驗證」，確保目前即將被 merge 的實際狀態是安全、完整、可重現的。

這個 Phase 是硬 Gate，不等同於 Final Review。

## 2. Entry Conditions

- Final Review Gate #1 = PASS
- Final Review Gate #2 = PASS
- 目標 branch / commit 已固定

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Pi Forge Verification Controller** | 本 Phase Owner。組織完整驗證並記錄 evidence。 |
| **Pi Reviewer Runtime** | 執行機械驗證：build/tests/autotest/status/scope。 |
| **Final Reviewer #2 / Merge Authority** | 讀 evidence，確認是否可進 MERGE_MAIN。 |

## 4. 必須驗證

至少包含：

1. 完整 build。
2. 全部 automated tests。
3. project-specific autotest。
4. integration tests。
5. git diff scope check。
6. forbidden-path check。
7. real model / real data validation（若適用）。
8. `git status` clean check。
9. dependency / lockfile check。
10. tmp / logs / models / secrets 未被 commit。
11. 當下 main 已重新 fetch / refresh。
12. 將最新 main 合入待 merge branch 後，再對「合併後狀態」跑關鍵驗證。

## 5. 重要順序

```text
1. fetch / refresh main
2. merge current main → lane/integration branch
3. 對合併後狀態跑完整驗證
4. PASS 才標 READY_TO_MERGE
5. 不可先 merge main 再驗
```

## 6. Metadata

```yaml
state: FINAL_VERIFICATION
verification:
  status: PASS | FAIL | BLOCKED
  tested_commit: <sha>
  main_sha_at_verify: <sha>
  report: final_reviews/verification/<run>.md
```

## 7. Transition

```text
FINAL_VERIFICATION
   ├─ PASS → MERGE_MAIN
   └─ FAIL → INTEGRATION_REWORK / REWORK
```

FAIL 回哪裡由 failure 類型決定：

- integration/merge interaction → `INTEGRATION_REWORK`
- production code defect → `REWORK`

## 8. Exit Criteria

`READY_TO_MERGE = true`
