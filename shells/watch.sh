#!/bin/zsh
# shells/orch/watch.sh — 背景監看所有 lane，有事就發 macOS 通知 + 寫集中事件檔。
#
#   orch watch [--interval 60] [--no-notify] [--once]
#
# 存在理由（§32.6）：Opus 5（Gate #2）是回合制的，**無法被檔案變更或程序結束喚醒**。
# 所以由這支 daemon 通知「人」，人再來叫 Gate #2。這是目前唯一可靠的推播路徑。
#
# 監看的事件：
#   LANE_DONE       lane 完成，等 Gate #2
#   REWORK_CAP      local LLM 用完 rework 上限，需要 orchestrator 接手
#   rc=<非0>        worker/reviewer 異常結束
#   NOTICE          有人（通常是 Gate #2）留了指示
#   ORCH_EXIT       orchestrator 不在了但 lane 沒寫 LANE_DONE（可能額度用完或崩了）
#   STALL           pi 還在跑但 session 超過門檻沒更新
set -u
SELF=${0:A:h}
source "$SELF/lib.sh"

interval=60; notify=1; once=0
while (( $# )); do
  case "$1" in
    --interval) interval="$2"; shift 2 ;;
    --no-notify) notify=0; shift ;;
    --once) once=1; shift ;;
    -*) die "不認得的參數: $1" 2 ;;
    *) shift ;;
  esac
done

EVENTS="$TMP/orch_events.log"
STATE="$TMP/.orch_watch_state"
mkdir -p "$STATE"

say() {  # say <title> <message>
  local title="$1" msg="$2"
  print -r -- "[$(date '+%F %T')] $title — $msg" >> "$EVENTS"
  print -r -- "$title — $msg"
  (( notify )) && osascript -e "display notification \"${msg//\"/\\\"}\" with title \"orch: ${title//\"/\\\"}\" sound name \"Glass\"" 2>/dev/null
}

# 從 run.meta 抽出「事件內容」，容忍有沒有時戳前綴（§ heartbeat 曾因寫死欄位而截斷）
strip_ts() { sed -E 's/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+\] ?//' }

scan_once() {
  # 所有 local 一次宣告完：zsh 對同一 scope 重複 typeset 同名變數會把值印出來
  local run name meta seen now_lines new_lines line body
  local age q a role task
  local -a inflight

  for run in $(all_runs); do
    name="${run:t}"
    meta="$run/run.meta"
    [[ -f "$meta" ]] || continue

    seen=$(cat "$STATE/$name.lines" 2>/dev/null || echo 0)
    now_lines=$(wc -l < "$meta" | tr -d ' ')
    if (( now_lines > seen )); then
      new_lines=$(tail -n +$((seen+1)) "$meta")
      print -r -- "$now_lines" > "$STATE/$name.lines"

      print -r -- "$new_lines" | while IFS= read -r line; do
        body=$(print -r -- "$line" | strip_ts | cut -c1-110)
        case "$line" in
          *LANE_DONE*)   say "$name 完成" "$body　→ 該做 Gate #2 了" ;;
          *REWORK_CAP*)  say "$name rework 用盡" "$body" ;;
          *NOTICE*)      say "$name NOTICE" "$body" ;;
          *rc=[1-9]*)    say "$name 異常結束" "$body" ;;
          # Gate #2 的驗證跑完是最該被通知的事件之一，rc=0 也要通知。
          # （實測踩過：VERIFY 16:56 就跑完，Gate #2 到 17:28 才知道。）
          *"end role=reviewer task=VERIFY"*) say "$name 驗證完成" "Gate #2 機械驗證結束 → 可以判決了" ;;
          *MERGED_TO_MAIN*) say "$name 已進 main" "$body" ;;
        esac
      done
    fi

    # orchestrator 不在了、但沒寫 LANE_DONE → 可能額度用完 / 崩掉
    if ! grep -aq "LANE_DONE" "$meta" 2>/dev/null; then
      if ! pgrep -f "[c]odex exec.*$name" >/dev/null 2>&1; then
        if [[ ! -f "$STATE/$name.orchexit" ]]; then
          age=$(( $(date +%s) - $(stat -f %m "$meta") ))
          if (( age > 60 )); then      # 緩衝，避免剛啟動時誤報
            : > "$STATE/$name.orchexit"
            q=$(grep -ahiE "quota|rate limit|usage limit" "$run"/codex*.log 2>/dev/null | tail -1 | cut -c1-80)
            say "$name orchestrator 不在了" "${q:-沒有 LANE_DONE 就退出，需要人工確認}"
          fi
        fi
      else
        rm -f "$STATE/$name.orchexit"
      fi
    fi

    # 停滯偵測。
    # 注意：task ID 會跨 lane 撞名（例如多條 lane 都有 VERIFY），
    # 所以不能只用 lanes.txt 判斷「這個 pi 屬於本 run」——必須用 run.meta 的
    # start/end 配對，取出「本 run 目前 started 但尚未 ended」的 task。
    inflight=(${(f)"$(awk '
      match($0, /role=[a-z]+ task=[A-Za-z0-9_-]+/) {
        s = substr($0, RSTART, RLENGTH)
        split(s, p, " "); sub(/role=/, "", p[1]); sub(/task=/, "", p[2])
        k = p[1] " " p[2]
        if ($0 ~ /\] start role=/) open[k] = 1
        else if ($0 ~ /\] end role=/) delete open[k]
      }
      END { for (k in open) print k }' "$meta")"})

    for a in $inflight; do
      role="${a%% *}"; task="${a##* }"
      pi_running | grep -qx "$a" || continue      # run.meta 說在跑，但實際程序已不在 → 不算停滯
      age=$(session_age "$run" "$role" "$task")
      if (( age > STALL_MIN*60 )); then
        if [[ ! -f "$STATE/$name.stall.$task" ]]; then
          : > "$STATE/$name.stall.$task"
          say "$name 可能卡住" "$role $task 的 session 已 $((age/60)) 分未更新"
        fi
      else
        rm -f "$STATE/$name.stall.$task"
      fi
    done
  done
}

if (( once )); then scan_once; exit 0; fi

print -r -- "watch 啟動（每 ${interval}s 掃一次，事件記到 $EVENTS）"
print -r -- "停止：pkill -f 'orch/watch.sh'"
while true; do
  scan_once
  sleep "$interval"
done
