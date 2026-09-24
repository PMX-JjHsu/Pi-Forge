#!/bin/zsh
# shells/orch/lib.sh — 共用函式庫。所有 orch 子命令 source 這支。
#
# 設計原則（來自 pi-multi-agent-orchestration-v2.md §29 的實戰事故）：
#   - 所有狀態計算放在腳本裡，不要放在 agent 的對話裡（§32 省 token）
#   - 危險操作一律先檢查、需要確認，不自動執行
#   - 事件一律寫 run.meta（append-only），統計從那裡算，不靠感覺
set -u

# ---------- 基本路徑 ----------

ORCH_DIR=${0:A:h}
REPO=$(git -C "$ORCH_DIR" rev-parse --show-toplevel 2>/dev/null) || {
  print -u2 "FATAL: 不在 git repo 內"; exit 2
}
TMP="$REPO/tmp"

# ---------- 輸出 ----------

die()  { print -u2 "ERROR: $*"; exit "${2:-1}" }
warn() { print -u2 "WARN:  $*" }
info() { print -r -- "$*" }
hr()   { print -r -- "────────────────────────────────────────────────────────" }

# ---------- run / lane 解析 ----------

# 找出某個 lane 的 run 目錄。接受完整 run 名（sed_20260922）或 lane 名（sed）。
# 同一 lane 有多個 run 時取最新的。
find_run() {
  local key="$1"
  [[ -d "$TMP/$key" ]] && { print -r -- "$TMP/$key"; return 0 }
  local -a hits
  hits=(${(f)"$(ls -dt $TMP/${key}_* 2>/dev/null)"})
  (( ${#hits} )) || return 1
  print -r -- "${hits[1]}"
}

# 列出所有「有 lane.conf」的 run 目錄，最新的在前
all_runs() {
  local d
  for d in ${(f)"$(ls -dt $TMP/*/ 2>/dev/null)"}; do
    [[ -f "${d%/}/lane.conf" ]] && print -r -- "${d%/}"
  done
}

# 讀 lane.conf 到環境變數（LANE / BRANCH / BASE_SHA / DATE / RUN_NAME / ITEMS）
load_conf() {
  local run="$1"
  [[ -f "$run/lane.conf" ]] || die "找不到 $run/lane.conf（這個 run 不是用 orch new 建的？）"
  local line key val
  while IFS= read -r line; do
    [[ "$line" == \#* || -z "$line" ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    typeset -g "LANE_${key}"="$val"
  done < "$run/lane.conf"
}

# ---------- run.meta ----------

meta() {  # meta <run> <訊息...>
  local run="$1"; shift
  print -r -- "[$(date '+%F %T')] $*" >> "$run/run.meta"
}

# ---------- git 防呆 ----------

# 主 worktree 必須在 main 且乾淨（只允許未追蹤檔）
assert_main_clean() {
  local br dirty
  br=$(git -C "$REPO" branch --show-current)
  [[ "$br" == main ]] || die "主 worktree 不在 main（現在是 $br）。絕對不要在主 worktree 切換分支。"
  dirty=$(git -C "$REPO" status --porcelain | grep -v '^??' | head -5)
  [[ -z "$dirty" ]] || { print -u2 "$dirty"; die "主 worktree 有未提交的變更，先處理再繼續" }
}

current_main() { git -C "$REPO" rev-parse --short main }

# branch 是否已被某個 worktree 檢出（檢出中的 branch 不能再 add 一次）
branch_checked_out() {
  git -C "$REPO" worktree list --porcelain | grep -q "^branch refs/heads/$1\$"
}

# 回傳檢出該 branch 的 worktree 路徑（沒有就回空）
worktree_of_branch() {
  git -C "$REPO" worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{w=$2} /^branch /{ if($2==b) {print w; exit} }'
}

# worktree 是否乾淨。忽略 gitignored 的執行期 symlink（models/data/venv）。
worktree_clean() {
  local out
  out=$(git -C "$1" status --porcelain 2>/dev/null \
        | grep -vE '^\?\? (\.venv|models|data|tools/agents/\.venv)')
  [[ -z "$out" ]]
}

# 開 worktree：已被檢出就自動改用 --detach（§29 事故：VERIFY 撞 INTEGRATION）
# 注意：不可用 `path` 當區域變數名 —— zsh 的 `path` 與 `PATH` 綁定，會把 PATH 清掉。
add_worktree() {  # add_worktree <dest> <ref> [new_branch]
  local dest="$1" ref="$2" newbr="${3:-}"
  [[ -d "$dest" ]] && return 0
  mkdir -p "${dest:h}"
  if [[ -n "$newbr" ]]; then
    git -C "$REPO" worktree add -q -b "$newbr" "$dest" "$ref" || return 1
  elif branch_checked_out "$ref"; then
    git -C "$REPO" worktree add -q --detach "$dest" "$ref" || return 1
  else
    git -C "$REPO" worktree add -q "$dest" "$ref" || return 1
  fi
  link_runtime_assets "$dest"
}

# gitignored 的執行期資產要 symlink 進 worktree，否則跑不了真實驗證
link_runtime_assets() {
  local wt="$1" d
  for d in models data .venv tools/agents/.venv tools/agents/.venv-kws; do
    [[ -e "$REPO/$d" ]] || continue
    [[ -e "$wt/$d" || -L "$wt/$d" ]] && continue
    mkdir -p "${wt}/${d:h}" 2>/dev/null
    ln -s "$REPO/$d" "$wt/$d"
  done
}

# ---------- pi 程序 ----------

# 精確列出跑著的 pi：每行 "<role> <task>"（§29.9 教訓：不要用模糊 pgrep pattern）
pi_running() {
  local p n
  for p in ${(f)"$(pgrep -f 'pi --provider local-vllm' 2>/dev/null)"}; do
    n=$(ps -o command= -p "$p" 2>/dev/null | grep -oE '\-\-name CR [a-z]+ [A-Za-z0-9_-]+')
    [[ -n "$n" ]] && print -r -- "${n#--name CR }"
  done
}

pi_count() { pi_running | grep -c . }

# orchestrator（codex）是否在跑；帶 run 名才能分辨多條 lane
orch_running() {  # orch_running [run_name]
  local key="${1:-}"
  if [[ -n "$key" ]]; then
    pgrep -f "[c]odex exec.*${key}" >/dev/null && return 0
    # brief 內容含 run 名時才比得到；退而求其次看有沒有任何 codex exec
    return 1
  fi
  pgrep -f "[c]odex exec -s danger" >/dev/null
}

# ---------- 停滯判定（§29.2：看 session mtime，不看 log）----------

STALL_MIN=${ORCH_STALL_MIN:-8}

# 回傳該 task 的 session jsonl 最後寫入距今幾秒；沒有 session 回 -1
session_age() {  # session_age <run> <role> <task>
  local f
  f=$(ls -t "$1/sessions/$2-$3"/*.jsonl 2>/dev/null | head -1)
  [[ -n "$f" ]] || { print -r -- -1; return }
  print -r -- $(( $(date +%s) - $(stat -f %m "$f") ))
}

# ---------- token 會計 ----------

run_tokens() {  # run_tokens <run>
  local t
  t=$(grep -aho '"totalTokens":[0-9]*' "$1"/sessions/*/*.jsonl 2>/dev/null \
      | cut -d: -f2 | paste -sd+ - | bc 2>/dev/null)
  print -r -- "${t:-0}"
}

# ---------- 確認提示 ----------

confirm() {  # confirm <訊息>；ORCH_YES=1 可跳過（給自動化用，慎用）
  [[ "${ORCH_YES:-0}" == 1 ]] && return 0
  print -n -- "$1 [y/N] "
  local a; read -r a
  [[ "$a" == (y|Y|yes|YES) ]]
}
