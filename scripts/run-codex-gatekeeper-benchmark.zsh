#!/bin/zsh
set -u

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
WORK="$ROOT/.work/syspolicyd-benchmark"
RUN_ID="${RUN_ID:-baseline}"
OUT="$ROOT/results/generated/$RUN_ID"
RAW="$OUT/raw"
FIXTURES="$WORK/fixtures"
TMP="$WORK/tmp"

mkdir -p "$RAW" "$FIXTURES" "$TMP"

TOTAL=${TOTAL:-60}
CONCURRENCY=${CONCURRENCY:-10}
REPS=${REPS:-3}
CMD_TIMEOUT=${CMD_TIMEOUT:-8}

real_codex() {
  local real dir target
  real="$(command -v codex)"
  while [ -L "$real" ]; do
    dir="$(dirname "$real")"
    target="$(readlink "$real")"
    case "$target" in
      /*) real="$target" ;;
      *) real="$dir/$target" ;;
    esac
  done
  (cd "$(dirname "$real")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$real")")
}

snapshot_processes() {
  local label="$1"
  local phase="$2"
  local file="$RAW/process-snapshots.csv"
  local now
  now="$(date +%s.%N)"
  ps -A -o pid= -o %cpu= -o %mem= -o rss= -o args= | awk -v now="$now" -v label="$label" -v phase="$phase" '
    /syspolicyd|trustd|taskgated|kernel_task|codex|codex-clean|codex-quarantined/ {
      name="other"
      if ($0 ~ /syspolicyd/) name="syspolicyd"
      else if ($0 ~ /trustd/) name="trustd"
      else if ($0 ~ /taskgated/) name="taskgated"
      else if ($0 ~ /kernel_task/) name="kernel_task"
      else if ($0 ~ /codex-quarantined/) name="codex-quarantined"
      else if ($0 ~ /codex-clean/) name="codex-clean"
      else if ($0 ~ /codex-aarch64-apple-darwin/) name="codex-real"
      else if ($0 ~ /codex/) name="codex"
      printf "%s,%s,%s,%s,%s,%s,%s,%s\n", now, label, phase, $1, name, $2, $3, $4
    }
  ' >> "$file"
}

run_binary_burst() {
  local label="$1"
  local binary="$2"
  local stdout_file="$RAW/${label}.stdout"
  local fail_file="$RAW/${label}.failures"
  local started finished run_status failures
  local pids=()
  local running=0

  : > "$stdout_file"
  : > "$fail_file"
  started="$(date +%s.%N)"

  for i in $(seq 1 "$TOTAL"); do
    (
      timeout "$CMD_TIMEOUT" "$binary" help >> "$stdout_file" 2>> "$fail_file"
    ) &
    pids+=($!)
    running=$((running + 1))
    if [ "$running" -ge "$CONCURRENCY" ]; then
      for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done
      pids=()
      running=0
    fi
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  finished="$(date +%s.%N)"
  failures="$(grep -cv '^$' "$fail_file" 2>/dev/null || true)"
  run_status="ok"
  [ "$failures" != "0" ] && run_status="failures"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$label" "$started" "$finished" "$TOTAL" "$CONCURRENCY" "$failures" "$run_status" "$binary" "codex-help" >> "$RAW/runs.csv"
}

run_project_burst() {
  local label="$1"
  local project="$2"
  local stdout_file="$RAW/${label}.stdout"
  local fail_file="$RAW/${label}.failures"
  local started finished run_status failures n
  local pids=()
  local running=0

  : > "$stdout_file"
  : > "$fail_file"
  started="$(date +%s.%N)"

  for i in $(seq 1 "$TOTAL"); do
    n=$(( (i % 20) + 1 ))
    (
      timeout "$CMD_TIMEOUT" "$project/bin/codex-$n" help >> "$stdout_file" 2>> "$fail_file"
    ) &
    pids+=($!)
    running=$((running + 1))
    if [ "$running" -ge "$CONCURRENCY" ]; then
      for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done
      pids=()
      running=0
    fi
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  finished="$(date +%s.%N)"
  failures="$(grep -cv '^$' "$fail_file" 2>/dev/null || true)"
  run_status="ok"
  [ "$failures" != "0" ] && run_status="failures"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$label" "$started" "$finished" "$TOTAL" "$CONCURRENCY" "$failures" "$run_status" "$project" "project-codex-help" >> "$RAW/runs.csv"
}

run_condition() {
  local label="$1"
  local kind="$2"
  local target="$3"
  snapshot_processes "$label" "before"
  if [ "$kind" = "binary" ]; then
    run_binary_burst "$label" "$target"
  else
    run_project_burst "$label" "$target"
  fi
  snapshot_processes "$label" "after"
}

REAL_CODEX="$(real_codex)"
CLEAN_CODEX="$FIXTURES/codex-clean"
QUAR_CODEX="$FIXTURES/codex-quarantined"
PROJECT_CLEAN="$TMP/project-clean"
PROJECT_QUAR="$TMP/project-quarantined"

cp "$REAL_CODEX" "$CLEAN_CODEX"
cp "$REAL_CODEX" "$QUAR_CODEX"
chmod +x "$CLEAN_CODEX" "$QUAR_CODEX"
xattr -d com.apple.quarantine "$CLEAN_CODEX" 2>/dev/null || true
xattr -w com.apple.quarantine "0381;00000000;CodexBenchmark;00000000-0000-0000-0000-000000000000" "$QUAR_CODEX"

rm -rf "$PROJECT_CLEAN" "$PROJECT_QUAR"
mkdir -p "$PROJECT_CLEAN/bin" "$PROJECT_QUAR/bin"
for i in {1..20}; do
  cp "$REAL_CODEX" "$PROJECT_CLEAN/bin/codex-$i"
  cp "$REAL_CODEX" "$PROJECT_QUAR/bin/codex-$i"
  chmod +x "$PROJECT_CLEAN/bin/codex-$i" "$PROJECT_QUAR/bin/codex-$i"
done
find "$PROJECT_CLEAN" -type f -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
find "$PROJECT_QUAR" -type f -exec xattr -w com.apple.quarantine "0381;00000000;CodexBenchmarkProject;00000000-0000-0000-0000-000000000001" {} +

{
  printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'total=%s\nconcurrency=%s\nreps=%s\ncmd_timeout=%s\n' "$TOTAL" "$CONCURRENCY" "$REPS" "$CMD_TIMEOUT"
  printf 'command_v_codex=%s\n' "$(command -v codex)"
  printf 'real_codex=%s\n' "$REAL_CODEX"
  printf 'real_codex_quarantine='
  xattr -p com.apple.quarantine "$REAL_CODEX" 2>/dev/null || printf 'absent'
  printf '\n'
  printf 'clean_copy_quarantine='
  xattr -p com.apple.quarantine "$CLEAN_CODEX" 2>/dev/null || printf 'absent'
  printf '\n'
  printf 'quarantined_copy_quarantine='
  xattr -p com.apple.quarantine "$QUAR_CODEX" 2>/dev/null || printf 'absent'
  printf '\n'
} > "$OUT/state-before.txt"

printf 'label,start_epoch,end_epoch,total,concurrency,failures,status,target,workload\n' > "$RAW/runs.csv"
printf 'epoch,label,phase,pid,comm,cpu,mem,rss_kb\n' > "$RAW/process-snapshots.csv"

for rep in $(seq 1 "$REPS"); do
  run_condition "real_clean_rep${rep}" "binary" "$REAL_CODEX"
  run_condition "copy_clean_rep${rep}" "binary" "$CLEAN_CODEX"
  run_condition "copy_quarantined_rep${rep}" "binary" "$QUAR_CODEX"
  run_condition "project_clean_rep${rep}" "project" "$PROJECT_CLEAN"
  run_condition "project_quarantined_rep${rep}" "project" "$PROJECT_QUAR"
done

{
  printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'real_codex_quarantine='
  xattr -p com.apple.quarantine "$REAL_CODEX" 2>/dev/null || printf 'absent'
  printf '\n'
  printf 'repo_root_quarantine_hits=\n'
  find "$ROOT" -path "$WORK" -prune -o -path "$ROOT/results" -prune -o -xattrname com.apple.quarantine -print 2>/dev/null | head -n 50
  printf 'fixture_quarantine_hits=\n'
  find "$WORK" -xattrname com.apple.quarantine -print 2>/dev/null | head -n 100
} > "$OUT/state-after.txt"

printf 'Benchmark complete. Raw output: %s\n' "$RAW"
