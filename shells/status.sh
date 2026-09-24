#!/bin/zsh
# shells/orch/status.sh — 一眼看完所有（或指定）lane 的狀態。
#
#   orch status            # 所有 active lane
#   orch status <lane>     # 單一 lane，較詳細
#   orch status --all      # 含已結束的 lane
#
# 設計目標（§32）：所有計算在這裡做，呼叫者只讀輸出。每一項都截斷，不吐原始 log。
set -u
SELF=${0:A:h}
source "$SELF/lib.sh"

show_all=0; target=""
while (( $# )); do
  case "$1" in
    --all) show_all=1; shift ;;
    *) target="$1"; shift ;;
  esac
done

print -r -- "== $(date '+%F %T') =="

# ---- 全域 ----
main_sha=$(current_main)
ahead=$(git -C "$REPO" rev-list --count origin/main..main 2>/dev/null || echo '?')
behind=$(git -C "$REPO" rev-list --count main..origin/main 2>/dev/null || echo '?')
print -r -- "main=$main_sha  未推送=$ahead  落後遠端=$behind"

n_pi=$(pi_count)
print -r -- "pi=$n_pi/${ORCH_PI_CAP:-8}  codex=$(pgrep -f '[c]odex exec -s danger' | grep -c . || echo 0)"

runs=()
if [[ -n "$target" ]]; then
  r=$(find_run "$target") || die "找不到 lane: $target"
  runs=("$r")
else
  runs=(${(f)"$(all_runs)"})
fi
(( ${#runs} )) || { print -r -- "(沒有用 orch new 建立的 run)"; exit 0 }

for RUN in $runs; do
  unset LANE_LANE LANE_BRANCH LANE_BASE_SHA LANE_ITEMS LANE_FILES LANE_RUN_NAME
  load_conf "$RUN" 2>/dev/null || continue
  done_evt=$(grep -a "LANE_DONE" "$RUN/run.meta" 2>/dev/null | tail -1)
  (( show_all )) || [[ -z "$done_evt" ]] || { 
    print -r -- ""
    print -r -- "[$LANE_LANE] 已結束 — ${done_evt#*] }"
    continue
  }

  print -r -- ""
  hr
  # commits
  ncommit=$(git -C "$REPO" log --oneline "main..$LANE_BRANCH" 2>/dev/null | wc -l | tr -d ' ')
  o=EXIT; pgrep -f "[c]odex exec.*$LANE_RUN_NAME" >/dev/null && o=RUN
  print -r -- "[$LANE_LANE] $LANE_RUN_NAME  base=$LANE_BASE_SHA  orch=$o  commits=$ncommit"
  [[ -n "$LANE_ITEMS" ]] && print -r -- "  items: $LANE_ITEMS"

  # 進行中的 pi + 停滯偵測（§29.2 看 session mtime，不看 log）
  actives=(${(f)"$(pi_running)"})
  shown=0
  for a in $actives; do
    role="${a%% *}"; task="${a##* }"
    grep -q "^$task " "$RUN/lanes.txt" 2>/dev/null || continue
    age=$(session_age "$RUN" "$role" "$task")
    if (( age < 0 )); then
      note="（尚無 session）"
    elif (( age > STALL_MIN*60 )); then
      note="⚠ session 已 $((age/60)) 分未更新（>${STALL_MIN}分，可能卡住）"
    else
      note="session ${age}s 前更新"
    fi
    print -r -- "  跑著: $role $task — $note"
    shown=1
  done
  (( shown )) || print -r -- "  跑著: (無 pi)"

  # 最近事件（只取關鍵欄位，不吐完整路徑）
  print -r -- "  最近事件:"
  grep -aoE "^\[[0-9-]+ [0-9:]+\] (start|end|rework|NOTICE|REWORK_CAP|PAUSED|LANE_DONE)[^|]{0,55}" "$RUN/run.meta" 2>/dev/null \
    | sed 's/\[[0-9]*-[0-9]*-[0-9]* /    /;s/\]//' | tail -5

  # 異常事件（有才印）
  bad=$(grep -aE "rc=[1-9]|REWORK_CAP|PAUSED|NOTICE" "$RUN/run.meta" 2>/dev/null | tail -3 | cut -c1-120)
  [[ -n "$bad" ]] && { print -r -- "  ⚠ 需注意:"; print -r -- "$bad" | sed 's/^/    /' }

  # review / rework
  nrev=$(ls -1 "$RUN/reviews" 2>/dev/null | wc -l | tr -d ' ')
  rw=""
  for f in "$RUN"/rework_count/*(N); do rw+="${f:t}=$(cat $f) "; done
  print -r -- "  reviews=$nrev  rework=[${rw:-無}]  tokens(pi)=$(printf "%'d" $(run_tokens "$RUN"))"
done

hr
print -r -- "細節: orch status <lane> | 心跳: tail -2 tmp/<run>/heartbeat.log"
