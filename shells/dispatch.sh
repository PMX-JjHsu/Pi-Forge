#!/bin/zsh
# shells/orch/dispatch.sh — 派一個 local LLM（pi）worker 或 reviewer。
#
#   dispatch.sh <run> worker   <TASK_ID> <prompt_file>
#   dispatch.sh <run> reviewer <TASK_ID> <prompt_file> [cwd]
#
# 這是原本每條 lane 各複製一份的 pi_task.sh 的共用版：lane 由參數決定，只維護這一份。
# 阻塞式執行，要並行就用 nohup ... &
#
# 所有防呆都在這裡，不要靠 prompt 約束（pi-worker-reviewer.md §4）。
set -u

SELF=${0:A:h}
source "$SELF/lib.sh"

(( $# >= 4 )) || die "usage: dispatch.sh <run> worker|reviewer <TASK_ID> <prompt_file> [cwd]" 2

run_key="$1"; role="$2"; task="$3"; prompt_file="$4"; cwd_override="${5:-}"

RUN=$(find_run "$run_key") || die "找不到 run: $run_key"
load_conf "$RUN"
WT_ROOT="$RUN/worktrees"
BASE_BRANCH="$LANE_BRANCH"

MODEL=${ORCH_PI_MODEL:-Qwen3.8-27B-nvfp4}
TIMEOUT_MIN=${PI_TIMEOUT_MIN:-75}
MAX_REWORK=${ORCH_MAX_REWORK:-5}
PI_CAP=${ORCH_PI_CAP:-8}         # 全機上限 = 本地 server 併發數
LANE_CAP=${ORCH_LANE_CAP:-3}     # 每條 lane：2 workers + 1 reviewer

[[ "$role" == (worker|reviewer) ]] || die "role 只能是 worker 或 reviewer" 2
[[ -f "$prompt_file" ]] || die "BLOCKED: prompt file 不存在: $prompt_file" 2
prompt_file=${prompt_file:A}     # 必須轉絕對路徑：稍後會 cd 進 worktree
[[ -s "$prompt_file" ]] || die "BLOCKED: prompt file 是空的: $prompt_file" 2

key=$(python3 -c "import json;print(json.load(open('$REPO/secrets/local-vllm-api-key.json'))['api_key'])") \
  || die "BLOCKED: 讀不到 local vLLM api key" 2

# ---- 併發上限 ----
running=$(pi_count)
(( running < PI_CAP )) || die "BLOCKED: 已有 $running 個 pi 在跑（上限 $PI_CAP）" 3

# 本 lane 的 pi 數：用 lanes.txt 對照 task→lane，逐一精確比對（不用模糊 pgrep，§29.9）
if [[ -f "$RUN/lanes.txt" ]]; then
  lane_tasks=(${(f)"$(awk -v l="$LANE_LANE" '$2==l{print $1}' "$RUN/lanes.txt")"})
  inlane=0
  for lt in $lane_tasks; do
    pi_running | grep -qx "worker $lt"   && (( inlane++ ))
    pi_running | grep -qx "reviewer $lt" && (( inlane++ ))
  done
  (( inlane < LANE_CAP )) || die "BLOCKED: lane $LANE_LANE 已有 $inlane 個 pi（上限 $LANE_CAP）" 3
fi

wt="$WT_ROOT/$task"

# ---- PAUSE：不派新 task，已分配的可繼續做完 ----
if [[ -f "$RUN/PAUSE" && "$role" == worker && ! -d "$wt" ]]; then
  meta "$RUN" "PAUSED refused new task=$task"
  die "PAUSED: 使用者已暫停派新工作（$RUN/PAUSE）。$task 維持 QUEUED。" 4
fi

# ---- rework 上限 ----
if [[ "$role" == worker && -d "$wt" && "${prompt_file:t}" != *.retry* ]]; then
  mkdir -p "$RUN/rework_count"; cf="$RUN/rework_count/$task"
  n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
  if (( n > MAX_REWORK )); then
    meta "$RUN" "REWORK_CAP task=$task 用完 $MAX_REWORK 次 → 交由 orchestrator 接手"
    die "REWORK_CAP: $task 已用完 rework 上限 $MAX_REWORK 次" 6
  fi
  print -r -- $n > "$cf"
  meta "$RUN" "rework $task #$n/$MAX_REWORK"
fi

# ---- 準備 worktree / 工具集 ----
if [[ "$role" == worker ]]; then
  if [[ ! -d "$wt" ]]; then
    add_worktree "$wt" "$BASE_BRANCH" "task/$task" || die "BLOCKED: worktree add 失敗" 2
  fi
  link_runtime_assets "$wt"
  tools="read,grep,find,ls,bash,edit,write"; cwd="$wt"
else
  tools="read,grep,find,ls,bash"            # reviewer 沒有 edit/write，這是刻意的
  cwd="${cwd_override:-$wt}"
  [[ -d "$cwd" ]] || die "BLOCKED: reviewer 的 cwd 不存在: $cwd" 2
fi

# ---- 同一個 (role, task) 只能有一個活著 ----
if pi_running | grep -qx "$role $task"; then
  die "BLOCKED: $role $task 已經在跑" 5
fi

cont=(); [[ "${PI_CONTINUE:-0}" == 1 ]] && cont=(--continue)

mkdir -p "$RUN/logs" "$RUN/sessions"
stamp=$(date +%Y%m%d-%H%M%S)
log="$RUN/logs/${role}-${task}-${stamp}.log"
meta "$RUN" "start role=$role task=$task cwd=$cwd model=$MODEL"
print -r -- "[$(date '+%F %T')] start role=$role task=$task → $log"

cd "$cwd" || die "cd 失敗: $cwd" 2
PI_CODING_AGENT_DIR="$RUN/pi_agent" PI_LOCAL_API_KEY="$key" timeout $((TIMEOUT_MIN*60)) \
  pi --provider local-vllm --model "$MODEL" --thinking high --approve --print \
     --name "CR $role $task" --tools "$tools" "${cont[@]}" \
     --session-dir "$RUN/sessions/${role}-${task}" "$(cat "$prompt_file")" > "$log" 2>&1
rc=$?
meta "$RUN" "end role=$role task=$task rc=$rc log=$log"
print -r -- "[$(date '+%F %T')] end role=$role task=$task rc=$rc"
exit $rc
