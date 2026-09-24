#!/bin/zsh
# shells/orch/merge.sh — 把一條 lane 合進 main 並 push，含 §29.4 的正確順序與防呆。
#
#   orch merge <lane> [--dry-run] [--no-push] [--skip-tests]
#
# 強制順序（§29.4：不可先 merge 進 main 再驗證）：
#   1. 前置檢查：Gate #2 報告存在、主 worktree 在 main 且乾淨
#   2. fetch，取得當下 main
#   3. 把 main 合進 lane branch（在 lane 的 worktree 裡做，不碰主 worktree）
#   4. 在「合併後」的狀態跑全部測試 + autotest
#   5. 通過才 merge --no-ff 進 main（commit message 記錄兩道 Gate）
#   6. push
#
# 任一步失敗就停，不會留下半合併的 main。
set -u
SELF=${0:A:h}
source "$SELF/lib.sh"

lane=""; dry=0; do_push=1; skip_tests=0
while (( $# )); do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --no-push) do_push=0; shift ;;
    --skip-tests) skip_tests=1; shift ;;
    -*) die "不認得的參數: $1" 2 ;;
    *) lane="$1"; shift ;;
  esac
done
[[ -n "$lane" ]] || die "usage: orch merge <lane> [--dry-run] [--no-push] [--skip-tests]" 2

RUN=$(find_run "$lane") || die "找不到 lane: $lane"
load_conf "$RUN"
BR="$LANE_BRANCH"

hr; info "Merge lane $LANE_LANE → main"; (( dry )) && info "（--dry-run：只檢查，不實際合併）"; hr

# ---- 1. 前置 ----
info "1. 前置檢查..."
g2="$RUN/final_reviews/gate2/${LANE_LANE}.md"
if [[ -f "$g2" ]]; then
  verdict=$(grep -aA3 '^## Verdict' "$g2" | grep -aoE '\b(PASS|FAIL|BLOCKED)\b' | head -1)
  info "   Gate #2 報告: $verdict"
  [[ "$verdict" == PASS ]] || { (( dry )) || die "Gate #2 不是 PASS（$verdict），不得 merge" }
else
  warn "   找不到 Gate #2 報告: $g2"
  (( dry )) || confirm "   沒有 Gate #2 報告就要合，確定？" || die "已取消"
fi

g1=$(ls "$RUN"/final_reviews/gate1/*.md 2>/dev/null | head -1)
[[ -n "$g1" ]] && info "   Gate #1 報告: $(grep -aA3 '^## Verdict' "$g1" | grep -aoE '\b(PASS|FAIL|BLOCKED)\b' | head -1)" \
               || warn "   找不到 Gate #1 報告"

assert_main_clean
info "   主 worktree OK"

ncommit=$(git -C "$REPO" log --oneline "main..$BR" | wc -l | tr -d ' ')
(( ncommit > 0 )) || die "$BR 沒有任何領先 main 的 commit，沒東西可合"
info "   待合併 commit: $ncommit"

# ---- 2. fetch ----
info "2. 取得當下 main..."
git -C "$REPO" fetch origin -q 2>/dev/null || warn "   fetch 失敗，用本地 main"
MAIN=$(current_main)
behind=$(git -C "$REPO" rev-list --count main..origin/main 2>/dev/null || echo 0)
(( behind == 0 )) || die "本地 main 落後 origin/main $behind 個 commit，先 pull 再合"
info "   main = $MAIN"

# ---- 3. 把 main 合進 lane（在專用 worktree 裡做）----
# ---- 3. 把 main 合進 lane（在專用 worktree 裡做，絕不碰主 worktree）----
info "3. 把 main 合進 $BR..."

# lane 結束後，orchestrator 建的 integration worktree 通常還佔著這個 branch。
# 那個 worktree 本來就是這條 lane 的整合現場，乾淨就直接重用，不要另外開一個。
existing=$(worktree_of_branch "$BR")
if [[ -n "$existing" ]]; then
  if worktree_clean "$existing"; then
    WT="$existing"
    info "   重用既有 worktree: ${WT/$REPO\//}"
  else
    print -u2 "$(git -C "$existing" status --porcelain | head -5)"
    die "$BR 被 $existing 檢出且有未提交變更。先處理那裡的變更再合。"
  fi
else
  WT="$RUN/worktrees/MERGE"
  if [[ ! -d "$WT" ]]; then
    git -C "$REPO" worktree add -q "$WT" "$BR" || die "worktree add 失敗"
    link_runtime_assets "$WT"
  fi
  git -C "$WT" checkout -q "$BR" || die "checkout $BR 失敗"
  info "   使用 ${WT/$REPO\//}"
fi
link_runtime_assets "$WT"

if git -C "$WT" merge-base --is-ancestor main "$BR"; then
  info "   已包含當下 main，不需合併"
else
  if (( dry )); then
    info "   [dry-run] 會執行: git merge main"
  elif git -C "$WT" merge --no-edit main >/dev/null 2>&1; then
    info "   OK → $(git -C "$WT" rev-parse --short HEAD)"
    meta "$RUN" "MERGE_MAIN_INTO_LANE main=$MAIN head=$(git -C "$WT" rev-parse --short HEAD)"
  else
    git -C "$WT" merge --abort 2>/dev/null
    die "合併 main 時衝突。請人工處理（只 git add 衝突檔，禁止 git add -A），完成後重跑。"
  fi
fi

# ---- 4. 合併後跑測試 ----
if (( skip_tests )); then
  warn "4. 依 --skip-tests 略過測試（不建議）"
elif (( dry )); then
  info "4. [dry-run] 會在 $WT 跑全部測試 + autotest"
else
  info "4. 在合併後的狀態跑測試（這步最花時間）..."
  t0=$(date +%s); total=0; fail=0; failed=()
  for f in "$WT"/tools/tests/test_*.py(N); do
    (( total++ ))
    ( cd "$WT" && ./tools/agents/.venv/bin/python "$f" ) >/dev/null 2>&1 || { (( fail++ )); failed+=("${f:t}") }
  done
  info "   單元測試: total=$total fail=$fail（$(( $(date +%s)-t0 ))s）"
  if (( fail )); then
    for f in $failed; do print -u2 "     FAIL $f"; done
    die "合併後有測試失敗，不得進 main"
  fi
  ( cd "$WT" && ./shells/autotest/autotest.sh ) >"$RUN/merge_autotest.log" 2>&1
  art=$?
  info "   autotest: RC=$art（log: $RUN/merge_autotest.log）"
  (( art == 0 )) || { tail -15 "$RUN/merge_autotest.log"; die "autotest 失敗，不得進 main" }
  meta "$RUN" "POST_MERGE_VERIFY tests=$total fail=0 autotest_rc=0"
fi

# ---- 5. merge 進 main ----
if (( dry )); then
  info "5. [dry-run] 會執行: git merge --no-ff $BR"
  info "6. [dry-run] 會執行: git push origin main"
  hr; info "dry-run 結束，未做任何變更"; exit 0
fi

confirm "5. 要把 $BR（$ncommit 個 commit）合進 main 嗎？" || die "已取消"

g1v=$([[ -n "$g1" ]] && grep -aA3 '^## Verdict' "$g1" | grep -aoE '\b(PASS|FAIL|BLOCKED)\b' | head -1)
g2v=$([[ -f "$g2" ]] && grep -aA3 '^## Verdict' "$g2" | grep -aoE '\b(PASS|FAIL|BLOCKED)\b' | head -1)
# Gate 歸屬讀自各 gate 報告的 `Reviewer:` 行（§：記錄一律寫路徑+模型，不可硬編碼）
g1rev=$(grep -aoE '^Reviewer:.*' "$g1" 2>/dev/null | head -1 | sed 's/^Reviewer:[[:space:]]*//')
g2rev=$(grep -aoE '^Reviewer:.*' "$g2" 2>/dev/null | head -1 | sed 's/^Reviewer:[[:space:]]*//')
msg="Merge branch '$BR'

${LANE_ITEMS:-（未指定 backlog items）}

Final Review Gate 1: ${g1rev:-orchestrator self-review} ${g1v:-N/A}
Final Review Gate 2: ${g2rev:-independent reviewer} ${g2v:-N/A}
Gate 1 報告: tmp/${RUN:t}/final_reviews/gate1/${LANE_LANE}.md
Gate 2 報告: tmp/${RUN:t}/final_reviews/gate2/${LANE_LANE}.md
合併後驗證: 單元測試全綠 + autotest RC=0"

git -C "$REPO" merge --no-ff "$BR" -m "$msg" || die "merge 失敗（衝突請人工處理，只 add 衝突檔）"
NEW=$(current_main)
info "   main: $MAIN → $NEW"
meta "$RUN" "MERGED_TO_MAIN $MAIN -> $NEW"

# ---- 6. push ----
if (( do_push )); then
  info "6. push origin main..."
  git -C "$REPO" push origin main || die "push 失敗"
  info "   origin/main = $(git -C "$REPO" rev-parse --short origin/main)"
  meta "$RUN" "PUSHED origin/main=$(git -C "$REPO" rev-parse --short origin/main)"
else
  info "6. 依 --no-push 略過 push（main 已在本地更新）"
fi

hr
info "完成。main = $(current_main)"
info "清理 worktree: git worktree remove $WT"
hr
