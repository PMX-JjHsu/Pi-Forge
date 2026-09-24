# 00 — CONFIGURATION MODEL（Pi Forge Configuration Model）

> **System**: Pi Forge / Pi Multi-Agent Orchestration  
> **Scope**: 五層資料責任（System Settings / Project Settings / Lane Settings / Runtime State / Workflow Specs）的共用資料模型  
> **Rule**: Pi Forge owns workflow/state; Pi owns agent runtime/session; Git owns source/branch/commit.  
> **Related**: workflow state 定義與流轉見 `00_WORKFLOW_STATE.md`。

Pi Forge 的資料切五種責任，禁止互相複製 / 污染：

```text
System        → defaults
Project       → project defaults / repo rules
Lane          → lane-specific override
Runtime State = 執行結果，不是設定
Specs         = workflow policy，不是設定
```

---

## 1. System Settings

- **Owner**: Pi Forge installation / user environment
- **Storage**: `~/.piforge/`
  ```
  ~/.piforge/
  ├── config.yaml      # System Settings
  ├── registry.yaml    # Project index（只記「Project 在哪裡」）
  └── secrets/         # 憑證（不進 git；config 只存 reference）
  ```
- **Stores**:
  - providers（Copilot / Claude / GPT / Local vLLM 的連線與認證 reference）
  - Local vLLM endpoint（base_url / model）
  - 全域 role model chains（System default）
  - 全域 fallback policy
  - 全域 Pi concurrency（`ORCH_PI_CAP`）/ lane 組成上限（`ORCH_LANE_CAP`）
  - 預設 worker / reviewer / Final Reviewer 數量、預設 rework 上限
  - Monitor polling interval、全域 stall 門檻（`ORCH_STALL_MIN`）
  - 全域下班停派時間（stop-dispatch schedule）
- **Registry**（`~/.piforge/registry.yaml`）：

  ```yaml
  projects:
    - id: robot
      path: /Users/user/Projects/RobotProject
    - id: mactp
      path: /Users/user/Projects/MacTP
  ```

  Registry **不存** lane 的 runtime state；真正的 Project / Lane metadata 留在 Project 內。

## 2. Project Settings

- **Owner**: Project / Repository
- **Storage**: `<ProjectRoot>/.piforge/project.yaml`
- **Stores**:
  - `repo_root`（repository / workdir 根目錄）
  - `default_branch`
  - validation commands（build / tests / autotest）
  - runtime assets（models/、data/、.venv/ …）
  - protected paths（docs/、secrets/ …）
  - project defaults（max_lanes、workers、reviewers、rework_max；`null`＝inherit System）
  - `model_overrides`（project 層 model override；`null`＝inherit System；完整 editor 可後補）

  ```yaml
  project_id: robot
  name: RobotProject
  repo_root: /path/to/RobotProject
  default_branch: main
  validation:
    build: ""
    tests: ""
    autotest: ""
  runtime_assets: []
  protected_paths: []
  defaults:
    max_lanes: null
    workers: null
    reviewers: null
    rework_max: null
  model_overrides:
    orchestrator: null
    worker: null
    reviewer: null
    final_review: null
  ```

## 3. Lane Settings

- **Owner**: 一個 Project 下的一條 Lane
- **Storage**: `<ProjectRoot>/.piforge/lanes/<lane-id>/lane.yaml`
- **Stores**:
  - items（backlog）
  - scope（files）
  - worker / reviewer / Final Reviewer composition（override；`null`＝inherit）
  - rework override（`policy.rework_max`）
  - schedule override（`schedule.stop_dispatch_at`）
  - model overrides（`model_overrides.*`；`null`＝inherit）

  ```yaml
  lane_id: gesture
  items: [BL-GESTURE-006, BL-GESTURE-007]
  scope:
    files: [tools/gesture/collect.py, tools/gesture/landmark.py]
  composition: {workers: null, reviewers: null, final: null}
  policy: {rework_max: null}
  schedule: {stop_dispatch_at: null}
  model_overrides: {orchestrator: null, worker: null, reviewer: null, final_review: null}
  ```

- **Lane 不存**：
  - `repo_root` / workdir（Project 層；lane 透過 parent Project 取得）
  - `default_branch`
  - vLLM URL / API key
  - 全域 provider chain、全域 polling interval、全域 Pi cap
  - Project name
- **Model override 是 optional**：lane 沒 override 時存 `null`，**不保存解析後的 System / Project 值**；上層變更後 inherit 的 lane 自然取得新預設。

## 4. Runtime State

- **Owner**: Pi Forge runtime（orchestrator）
- **Storage**: `<ProjectRoot>/.piforge/lanes/<lane-id>/state.json`
- **Stores**:
  - current workflow state（`state` / `resume_state`；canonical 定義見 `00_WORKFLOW_STATE.md`）
  - branch、base SHA
  - session references（`session_ref`；不解析 Pi session 內容）
  - worker / reviewer status、rework counters
  - review results（Task / 自審 / Final #1 / #2 verdicts）
  - merge status、resolved model（含 fallback 結果）
- **Runtime state 不是使用者設定**：GUI 可讀，正常設定畫面不得讓使用者任意修改。
- **Runtime 事件（例如 fallback 到某 model）只寫 runtime / events，不得改 `lane.yaml`。**

## 5. Event History

- **Storage**: `<ProjectRoot>/.piforge/lanes/<lane-id>/events.jsonl`
- Append-only history of state transitions and important runtime events：

  ```json
  {"time":"2026-09-24T14:01:00+08:00","event":"IMPLEMENT_START"}
  {"time":"2026-09-24T14:15:00+08:00","event":"LOCAL_REVIEW_START"}
  {"time":"2026-09-24T14:19:00+08:00","event":"LOCAL_REVIEW_FAIL"}
  {"time":"2026-09-24T14:20:00+08:00","event":"REWORK_START","count":1}
  ```

- `state.json`＝「現在怎樣」；`events.jsonl`＝「曾經發生什麼」。
- **不得**把 history 塞回 `lane.yaml`（config）。

## 6. Workflow Specs

- **Storage**: `shells/orch/specs/`（`00_WORKFLOW_STATE.md`、`01_DISPATCH.md` … `10_DONE.md`）
- Specs 定義每個 Phase 做什麼、R&R、fail 去哪裡、權限與規則（workflow policy）。
- **Specs 不是設定**：repo 在哪、用幾個 worker、跑什麼 build command、用哪個 model 屬於 Settings。兩者禁止混在一起。

## 7. Inheritance

```text
Lane Override
    ↓ if null
Project Override
    ↓ if null
System Default
```

- **只有 configuration 支持 inheritance**（`null`＝inherit）。
- **Runtime state does not inherit**：`state` / branch / session / counters 都是該 lane 自己的執行事實。
- UI / code 必須用**單一 resolution helper**（GUI：`resolveChain()` / `resolveComp()` / `resolveRework()` / `resolveRepoRoot()`），
  禁止在不同地方散落 `lane.foo || project.foo || system.foo`。
- 解析結果**只用於顯示與執行**；不寫回下層 config（inherit 的欄位保持 `null`）。

## 8. Ownership Summary

| Data | Owner | Storage |
|---|---|---|
| Providers / 認證 reference / local vLLM endpoint | System | `~/.piforge/config.yaml`（secrets/） |
| 全域 model chain / fallback policy | System | `~/.piforge/config.yaml` |
| Pi concurrency / 預設組成 / rework 預設 / monitor / 停派 / stall | System | `~/.piforge/config.yaml` |
| Project index（Project 在哪裡） | System | `~/.piforge/registry.yaml` |
| `repo_root` / workdir | Project | `.piforge/project.yaml` |
| `default_branch` | Project | `.piforge/project.yaml` |
| build / test / autotest commands | Project | `.piforge/project.yaml` |
| runtime assets / protected paths | Project | `.piforge/project.yaml` |
| project defaults / project model overrides | Project | `.piforge/project.yaml` |
| items / scope / composition / policy / schedule / model overrides | Lane | `.piforge/lanes/<lane>/lane.yaml` |
| current state / branch / base SHA | Runtime | `.piforge/lanes/<lane>/state.json` |
| session reference / worker status / review results / rework count | Runtime | `.piforge/lanes/<lane>/state.json` |
| 事件歷史 | Runtime（append-only） | `.piforge/lanes/<lane>/events.jsonl` |
| Phase R&R / transition policy | Specs | `shells/orch/specs/` |
| source / branch / commit | Git | repository |
| agent internal session / runtime | Pi | Pi 自管（只存 `session_ref`） |
