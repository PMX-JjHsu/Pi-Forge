# Phase 03 — LOCAL_REVIEW

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: Project-centric Lane workflow  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Metadata**: Lane metadata is Pi Forge-defined data. Do not parse Pi internal session content; only keep stable references such as session IDs/paths when needed.


## 1. Phase 目標

由獨立的 Local Reviewer 對 Worker 的 diff、AC、validation 與 scope 做第一層審查。

Reviewer 是 **read-only**；只找問題，不修問題。

## 2. Entry Conditions

- Worker 已完成 implementation。
- 存在新 commit。
- Diff 可被獨立檢視。
- Review prompt 已明確包含 AC / scope / validation。

## 3. Owner / Participants

| Role | R&R |
|---|---|
| **Local Reviewer** | 本 Phase Review Owner。獨立檢查 diff、AC、regression、validation、scope。 |
| **Local Lead** | 接收 findings，決定 rework 要回哪個 Worker。 |
| **Pi Forge Orchestrator** | 啟動 reviewer、記錄 verdict、依固定 transition rule 切 state。 |
| **Worker** | 此階段不主動修改 code；收到 FAIL 才進 REWORK。 |

## 4. Reviewer 必查

- diff 是否符合 Task scope。
- AC 是否完整。
- functional correctness。
- regression。
- error handling。
- tests 是否不足。
- forbidden file 修改。
- fake/mock path 與 production path 是否不一致。
- Worker 是否真的 commit。
- 指定 validation 是否真的執行。

## 5. Reviewer 工具權限

允許：

```text
read
grep
find
ls
bash
```

禁止：

```text
edit
write
```

## 6. Reviewer Output Contract

```markdown
# Review: <TASK_ID>

## Verdict
PASS | FAIL | BLOCKED

## Findings

### F1
- Severity:
- File:
- Evidence:
- Expected:
- Actual:
- Required rework:

## Validation Run
- Command:
- Result:

## Scope Check
- Unauthorized file change: YES/NO

## Recommendation
PASS / REWORK / BLOCK
```

## 7. Pi Forge Metadata

```yaml
state: LOCAL_REVIEW
local_review:
  verdict: PASS | FAIL | BLOCKED
  report: reviews/<TASK_ID>.local.md
  attempt: 1
```

## 8. Transition

```text
LOCAL_REVIEW
   ├─ PASS    → INTEGRATE
   ├─ FAIL    → REWORK
   └─ BLOCKED → BLOCKED
```

## 9. Exit Criteria

Reviewer report 已保存，而且 verdict 為明確的 `PASS / FAIL / BLOCKED`。
