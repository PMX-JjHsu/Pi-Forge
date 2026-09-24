#!/bin/zsh
# shells/orch/new.sh — 開一條新 lane。把 §29.10 的 12 項檢查表固化成腳本。
#
#   orch new <lane> [--items "<backlog IDs>"] [--files "<預定要動的檔案 glob，空白分隔>"]
#
# 做的事（依序，任一步失敗就停）：
#   1. 主 worktree 必須在 main 且乾淨
#   2. git fetch，取得當下 main 的 SHA
#   3. 檔案重疊檢查：跟所有 active lane 的 lane.conf FILES 比對
#   4. 開 integration branch（從當下 main）
#   5. 建 run 目錄結構 + 複製 pi_agent
#   6. 寫 lane.conf（含 BASE_SHA —— 不事後推測，§29.5）
#   7. 啟動背景 heartbeat
#   8. 產生 brief 骨架，提示下一步
set -u
SELF=${0:A:h}
source "$SELF/lib.sh"

lane="" ; items="" ; files=""
while (( $# )); do
  case "$1" in
    --items) items="$2"; shift 2 ;;
    --files) files="$2"; shift 2 ;;
    -*) die "不認得的參數: $1" 2 ;;
    *)  [[ -z "$lane" ]] && lane="$1" || die "只能指定一個 lane 名" 2; shift ;;
  esac
done
[[ -n "$lane" ]] || die "usage: orch new <lane> [--items \"BL-XXX-001 ...\"] [--files \"path1 path2\"]" 2
[[ "$lane" =~ "^[a-z0-9]+$" ]] || die "lane 名只能用小寫英數（例：sed、cfg、wk4）" 2

DATE=$(date +%Y%m%d)
RUN_NAME="${lane}_${DATE}"
RUN="$TMP/$RUN_NAME"
BRANCH="integration/${lane}-${DATE}"

[[ -d "$RUN" ]] && die "$RUN 已存在。要重開請先處理舊的 run。"

hr; info "開 lane: $lane"; hr

# ---- 1. 主 worktree 檢查 ----
info "1. 檢查主 worktree..."
assert_main_clean
info "   OK（main，無未提交變更）"

# ---- 2. fetch + base SHA ----
info "2. 取得當下 main..."
git -C "$REPO" fetch origin -q 2>/dev/null || warn "   fetch 失敗（離線？），改用本地 main"
BASE_SHA=$(current_main)
info "   base = $BASE_SHA  $(git -C "$REPO" log -1 --format=%s main | cut -c1-60)"

# ---- 3. 重疊檢查 ----
info "3. 檔案重疊檢查..."
if [[ -n "$files" ]]; then
  typeset -a conflicts
  for other in $(all_runs); do
    [[ "$other" == "$RUN" ]] && continue
    # 只跟「還沒 LANE_DONE」的 lane 比
    grep -aq "LANE_DONE" "$other/run.meta" 2>/dev/null && continue
    ofiles=$(awk -F= '/^FILES=/{sub(/^FILES=/,"");print}' "$other/lane.conf" 2>/dev/null)
    [[ -n "$ofiles" ]] || continue
    for f in ${=files}; do
      for o in ${=ofiles}; do
        [[ "$f" == "$o" ]] && conflicts+=("$f  ←→  ${other:t}")
      done
    done
  done
  if (( ${#conflicts} )); then
    print -u2 "   ✗ 與進行中的 lane 有檔案衝突："
    for c in $conflicts; do print -u2 "      $c"; done
    die "換一組檔案再開（§29.5）"
  fi
  info "   OK（與 $(all_runs | wc -l | tr -d ' ') 個既有 run 比對，無交集）"
else
  warn "   略過（沒給 --files）。強烈建議帶 --files，否則無法自動擋跨 lane 衝突。"
fi

# ---- 4. branch ----
info "4. 開 integration branch..."
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" \
  && die "branch $BRANCH 已存在"
git -C "$REPO" branch "$BRANCH" main || die "branch 建立失敗"
info "   $BRANCH ← main($BASE_SHA)"

# ---- 5. 目錄結構 ----
info "5. 建立 run 目錄..."
mkdir -p "$RUN"/{prompts,logs,sessions,reviews,reports,rework_count,artifacts,worktrees} \
         "$RUN"/final_reviews/{gate1,gate2}
: > "$RUN/lanes.txt"

# pi_agent：從最近一個既有 run 複製（內含 provider 設定與 maxTokens）
src_agent=""
for r in $(all_runs); do [[ -d "$r/pi_agent" ]] && { src_agent="$r/pi_agent"; break } done
[[ -z "$src_agent" ]] && for r in ${(f)"$(ls -dt $TMP/*/pi_agent 2>/dev/null)"}; do src_agent="$r"; break; done
if [[ -n "$src_agent" ]]; then
  cp -R "$src_agent" "$RUN/pi_agent"
  info "   pi_agent ← $src_agent"
else
  warn "   找不到可複製的 pi_agent，pi 會用預設設定（maxTokens 可能不足，實測 16384 會截斷）"
fi

# ---- 6. lane.conf ----
cat > "$RUN/lane.conf" <<EOF
# 由 orch new 產生，不要手改 BASE_SHA
RUN_NAME=$RUN_NAME
LANE=$lane
BRANCH=$BRANCH
DATE=$DATE
BASE_SHA=$BASE_SHA
ITEMS=$items
FILES=$files
EOF
meta "$RUN" "RUN_START run=$RUN_NAME lane=$lane base=$BASE_SHA branch=$BRANCH items=${items:-未指定}"
info "6. lane.conf 已寫入（BASE_SHA=$BASE_SHA）"

# ---- 7. heartbeat ----
cat > "$RUN/hb.sh" <<EOF
#!/bin/zsh
# 背景心跳：每 10 分鐘一行。Gate #2 只讀 tail -2（§32.1）
R="$RUN"
while true; do
  o=EXIT; pgrep -f "[c]odex exec.*$RUN_NAME" >/dev/null && o=RUN
  p=\$(for x in \$(pgrep -f 'pi --provider local-vllm'); do
        ps -o command= -p \$x | grep -oE '\-\-name CR [a-z]+ [A-Za-z0-9_-]+' | sed 's/--name CR //;s/ /:/'
      done | tr '\n' ' ')
  c=\$(git -C "$REPO" log --oneline main..$BRANCH 2>/dev/null | wc -l | tr -d ' ')
  e=\$(tail -1 \$R/run.meta | cut -c22-95)
  print -r -- "\$(date +%H:%M) orch=\$o pi=[\${p:-none}] commits=\$c | \$e" >> \$R/heartbeat.log
  sleep 600
done
EOF
chmod +x "$RUN/hb.sh"
( cd "$RUN" && nohup ./hb.sh >/dev/null 2>&1 & )
info "7. heartbeat 已啟動（$RUN/heartbeat.log）"

# ---- 8. brief 骨架 ----
brief="$RUN/BRIEF.md"
if [[ -f "$SELF/templates/brief.md" ]]; then
  sed -e "s|{{RUN_NAME}}|$RUN_NAME|g" -e "s|{{LANE}}|$lane|g" \
      -e "s|{{BRANCH}}|$BRANCH|g"     -e "s|{{BASE_SHA}}|$BASE_SHA|g" \
      -e "s|{{ITEMS}}|${items:-（待填）}|g" -e "s|{{REPO}}|$REPO|g" \
      "$SELF/templates/brief.md" > "$brief"
  info "8. brief 骨架 → $brief"
fi

hr
info "lane $lane 就緒。下一步："
info "  1) 編輯 $brief（範圍、allowed/forbidden files、驗收、前面 lane 的教訓）"
info "  2) 啟動 orchestrator："
info "     nohup perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV or die' \\"
info "       /Applications/ChatGPT.app/Contents/Resources/codex exec -s danger-full-access \\"
info "       -c model_reasoning_effort=xhigh -m gpt-5.6-luna \"\$(cat $brief)\" \\"
info "       > $RUN/codex.log 2>&1 < /dev/null &"
info "  3) 看狀態：shells/orch/orch status"
hr
