#!/bin/zsh
# shells/orch/verify.sh — Gate #2 的標準獨立驗證：開乾淨 worktree，派 pi 跑機械驗證。
#
#   orch verify <lane> [--ref <git ref>] [--with-main] [--extra <額外指令檔>]
#
#   --with-main   先把當下 main 合進驗證 worktree 再驗（§29.4 的正確順序）
#   --ref         指定要驗的 ref（預設 = 該 lane 的 integration branch）
#
# 做的事：
#   1. fetch，確認當下 main
#   2. 開 detached 驗證 worktree（branch 被佔用時自動 --detach）
#   3. （選）把 main 合進去，衝突就停
#   4. 用 templates/verify.md 產生 prompt，派 pi reviewer（背景）
#   5. 印出結果位置與後續指令
#
# pi 只回報事實、不下判斷；判斷是 Gate #2 自己的事（§29.3）。
set -u
SELF=${0:A:h}
source "$SELF/lib.sh"

lane=""; ref=""; with_main=0; extra=""
while (( $# )); do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --with-main) with_main=1; shift ;;
    --extra) extra="$2"; shift 2 ;;
    -*) die "不認得的參數: $1" 2 ;;
    *) lane="$1"; shift ;;
  esac
done
[[ -n "$lane" ]] || die "usage: orch verify <lane> [--with-main] [--ref <ref>] [--extra <file>]" 2

RUN=$(find_run "$lane") || die "找不到 lane: $lane"
load_conf "$RUN"
[[ -n "$ref" ]] || ref="$LANE_BRANCH"

hr; info "Gate #2 獨立驗證: $LANE_LANE"; hr

info "1. 取得當下 main..."
git -C "$REPO" fetch origin -q 2>/dev/null || warn "   fetch 失敗，用本地 main"
MAIN=$(current_main)
info "   main = $MAIN"

base_in_main=$(git -C "$REPO" merge-base "$LANE_BRANCH" main)
info "   lane 與 main 的分歧點 = $(git -C "$REPO" rev-parse --short $base_in_main)"
n_behind=$(git -C "$REPO" rev-list --count "$LANE_BRANCH..main")
info "   lane 落後 main $n_behind 個 commit"

WT="$RUN/worktrees/VERIFY"
if [[ -d "$WT" ]]; then
  info "2. 驗證 worktree 已存在，重用: $WT"
  git -C "$WT" fetch -q origin 2>/dev/null
  git -C "$WT" checkout -q --detach "$ref" || die "checkout $ref 失敗"
else
  info "2. 開驗證 worktree（detached @ $ref）..."
  add_worktree "$WT" "$ref" || die "worktree add 失敗"
fi
link_runtime_assets "$WT"
info "   $WT"

merged_note="未合併 main（只驗 lane 自身）"
if (( with_main )); then
  info "3. 把 main 合進驗證 worktree（§29.4：先合再驗）..."
  if git -C "$WT" merge --no-edit main >/dev/null 2>&1; then
    merged_note="已合併 main($MAIN)，驗的是合併後的狀態"
    info "   OK — $(git -C "$WT" rev-parse --short HEAD)"
  else
    git -C "$WT" merge --abort 2>/dev/null
    die "合併 main 時發生衝突，需人工處理後再驗（衝突檔請用 git add <檔> 逐一解，禁止 git add -A）"
  fi
else
  info "3. 略過 main 合併（要驗合併後狀態請加 --with-main）"
fi

# ---- prompt ----
tpl="$SELF/templates/verify.md"
[[ -f "$tpl" ]] || die "找不到 prompt 樣板: $tpl"
prompt_path="$RUN/prompts/verify_gate2_$(date +%H%M%S).md"
mkdir -p "$RUN/prompts"
sed -e "s|{{WT}}|$WT|g" -e "s|{{REPO}}|$REPO|g" -e "s|{{LANE}}|$LANE_LANE|g" \
    -e "s|{{BRANCH}}|$LANE_BRANCH|g" -e "s|{{MAIN}}|$MAIN|g" \
    -e "s|{{MERGED}}|$merged_note|g" "$tpl" > "$prompt_path"
if [[ -n "$extra" && -f "$extra" ]]; then
  print -r -- "" >> "$prompt_path"
  print -r -- "## 本 lane 專屬的額外檢查" >> "$prompt_path"
  cat "$extra" >> "$prompt_path"
  info "   已附加專屬檢查: $extra"
fi

# ---- 派工 ----
task="VERIFY"
grep -q "^$task " "$RUN/lanes.txt" 2>/dev/null || print -r -- "$task $LANE_LANE" >> "$RUN/lanes.txt"
info "4. 派 pi reviewer（背景）..."
nohup "$SELF/dispatch.sh" "${RUN:t}" reviewer "$task" "$prompt_path" "$WT" \
  > "$RUN/launcher-VERIFY.log" 2>&1 &
sleep 4
if pi_running | grep -qx "reviewer $task"; then
  info "   RUNNING"
else
  warn "   沒起來，看 $RUN/launcher-VERIFY.log"
  tail -3 "$RUN/launcher-VERIFY.log" 2>/dev/null
fi

hr
info "驗證中（$merged_note）"
info "看結果:  grep -aE '^## |total=|RC=|=YES|=NO' $RUN/logs/reviewer-VERIFY-*.log"
info "看進度:  orch status $LANE_LANE"
info "判決後寫: $RUN/final_reviews/gate2/${LANE_LANE}.md"
hr
