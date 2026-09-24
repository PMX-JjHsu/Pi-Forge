# Phase 04 — REWORK

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

處理 Local Review、Final Review 或 Integration 發現的問題，讓原 Task 回到可再次驗證的狀態。

REWORK 是 **修正階段**，不是新的審查階段。

## 2. Entry Conditions

可能由以下任一來源進入：

- `LOCAL_REVIEW = FAIL`
- `FINAL_REVIEW = FAIL`
- Integration finding 明確指向某個 Lane / Task
- Validation 失敗且需要修改 production code / tests

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Original Worker / Assigned Rework Worker** | 實際修正 code、tests、validation。 |
| **Local Lead** | 將 structured findings 轉成明確 rework task。 |
| **Pi Forge Orchestrator** | 記錄 failure source、retry count、重新派工、控制 retry limit。 |
| **Reviewer** | 不在 REWORK 階段直接修改 code。 |

## 4. 必須保存 Failure Source

```yaml
state: REWORK
rework:
  source: LOCAL_REVIEW | FINAL_REVIEW_1 | FINAL_REVIEW_2 | INTEGRATION
  count: 1
  findings:
    - F1
    - F2
  owner: worker-1
```

## 5. Rework 規則

- 必須逐條處理 structured findings。
- 修改後必須重新跑相關 validation。
- 必須 commit 新修正。
- 不得只改 report 讓 verdict 看起來變綠。
- 不得跳過 Local Review。

## 6. Retry / Escalation

不得無限 rework。

超過 policy 上限時，Pi Forge 應：

- STOP local loop。
- 標記 `BLOCKED` 或 `FAILED`。
- 要求重新拆 Task / 改 validation / 重新定義 dependency。
- 必要時才做 Cloud diagnosis。

## 7. 最重要的 Transition Rule

無論 failure 來自 Local Review 或 Final Review，code 被修改後：

```text
REWORK
   ↓
LOCAL_REVIEW
```

**不得：**

```text
FINAL_REVIEW FAIL
   ↓
REWORK
   ↓
FINAL_REVIEW   # 禁止直接跳回
```

原因：修改後 functional correctness 必須重新由 Local Reviewer 檢查。

## 8. Exit Criteria

- 修正已 commit。
- Rework validation 已有 evidence。
- retry count 已更新。
- 下一狀態固定回 `LOCAL_REVIEW`。
