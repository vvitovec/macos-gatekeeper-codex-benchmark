#!/bin/zsh
set -u

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
WORK="$ROOT/.work/syspolicyd-benchmark/case-study-extras"
OUT="$ROOT/results/generated/case_study_extras"
RAW="$OUT/raw"

mkdir -p "$WORK" "$RAW"

TOTAL=${TOTAL:-100}
CONCURRENCY=${CONCURRENCY:-10}
REPS=${REPS:-5}
CMD_TIMEOUT=${CMD_TIMEOUT:-5}
MANY_COUNT=${MANY_COUNT:-50}

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
    /syspolicyd|trustd|taskgated|kernel_task|codex|tiny-runner/ {
      name="other"
      if ($0 ~ /syspolicyd/) name="syspolicyd"
      else if ($0 ~ /trustd/) name="trustd"
      else if ($0 ~ /taskgated/) name="taskgated"
      else if ($0 ~ /kernel_task/) name="kernel_task"
      else if ($0 ~ /codex-aarch64-apple-darwin/) name="codex-real"
      else if ($0 ~ /codex/) name="codex"
      else if ($0 ~ /tiny-runner/) name="tiny-runner"
      printf "%s,%s,%s,%s,%s,%s,%s,%s\n", now, label, phase, $1, name, $2, $3, $4
    }
  ' >> "$file"
}

run_binary_burst() {
  local label="$1"
  local binary="$2"
  local arg="${3:-}"
  local stdout_file="$RAW/${label}.stdout"
  local fail_file="$RAW/${label}.failures"
  local started finished failures run_status
  local pids=()
  local running=0

  : > "$stdout_file"
  : > "$fail_file"
  started="$(date +%s.%N)"
  for i in $(seq 1 "$TOTAL"); do
    (
      if [ -n "$arg" ]; then
        timeout "$CMD_TIMEOUT" "$binary" "$arg" >> "$stdout_file" 2>> "$fail_file"
      else
        timeout "$CMD_TIMEOUT" "$binary" >> "$stdout_file" 2>> "$fail_file"
      fi
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
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$label" "$started" "$finished" "$TOTAL" "$CONCURRENCY" "$failures" "$run_status" "$binary" >> "$RAW/runs.csv"
}

run_many_burst() {
  local label="$1"
  local dir="$2"
  local stdout_file="$RAW/${label}.stdout"
  local fail_file="$RAW/${label}.failures"
  local started finished failures run_status n
  local pids=()
  local running=0

  : > "$stdout_file"
  : > "$fail_file"
  started="$(date +%s.%N)"
  for i in $(seq 1 "$TOTAL"); do
    n=$(( ((i - 1) % MANY_COUNT) + 1 ))
    (
      timeout "$CMD_TIMEOUT" "$dir/tiny-runner-$n" >> "$stdout_file" 2>> "$fail_file"
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
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$label" "$started" "$finished" "$TOTAL" "$CONCURRENCY" "$failures" "$run_status" "$dir" >> "$RAW/runs.csv"
}

run_condition() {
  local label="$1"
  local mode="$2"
  local target="$3"
  local arg="${4:-}"
  snapshot_processes "$label" "before"
  if [ "$mode" = "many" ]; then
    run_many_burst "$label" "$target"
  else
    run_binary_burst "$label" "$target" "$arg"
  fi
  snapshot_processes "$label" "after"
}

cat > "$WORK/tiny-runner.c" <<'C'
#include <stdio.h>
int main(void) {
  puts("ok");
  return 0;
}
C

clang -O2 "$WORK/tiny-runner.c" -o "$WORK/tiny-runner"
chmod +x "$WORK/tiny-runner"

TINY_CLEAN="$WORK/tiny-clean"
TINY_QUAR="$WORK/tiny-quarantined"
MANY_CLEAN="$WORK/many-clean"
MANY_QUAR="$WORK/many-quarantined"

rm -rf "$MANY_CLEAN" "$MANY_QUAR"
mkdir -p "$MANY_CLEAN" "$MANY_QUAR"
cp "$WORK/tiny-runner" "$TINY_CLEAN"
cp "$WORK/tiny-runner" "$TINY_QUAR"
chmod +x "$TINY_CLEAN" "$TINY_QUAR"
xattr -d com.apple.quarantine "$TINY_CLEAN" 2>/dev/null || true
xattr -w com.apple.quarantine "0381;00000000;TinyBenchmark;00000000-0000-0000-0000-000000000010" "$TINY_QUAR"

for i in $(seq 1 "$MANY_COUNT"); do
  cp "$WORK/tiny-runner" "$MANY_CLEAN/tiny-runner-$i"
  cp "$WORK/tiny-runner" "$MANY_QUAR/tiny-runner-$i"
  chmod +x "$MANY_CLEAN/tiny-runner-$i" "$MANY_QUAR/tiny-runner-$i"
done
find "$MANY_CLEAN" -type f -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
find "$MANY_QUAR" -type f -exec xattr -w com.apple.quarantine "0381;00000000;TinyManyBenchmark;00000000-0000-0000-0000-000000000011" {} +

REAL_CODEX="$(real_codex)"
cleanup_real_codex() {
  xattr -d com.apple.quarantine "$REAL_CODEX" 2>/dev/null || true
}
trap cleanup_real_codex EXIT INT TERM

{
  printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'total=%s\nconcurrency=%s\nreps=%s\ncmd_timeout=%s\nmany_count=%s\n' "$TOTAL" "$CONCURRENCY" "$REPS" "$CMD_TIMEOUT" "$MANY_COUNT"
  printf 'real_codex=%s\n' "$REAL_CODEX"
  printf 'real_codex_initial_quarantine='
  xattr -p com.apple.quarantine "$REAL_CODEX" 2>/dev/null || printf 'absent'
  printf '\n'
} > "$OUT/state-before.txt"

printf 'label,start_epoch,end_epoch,total,concurrency,failures,status,target\n' > "$RAW/runs.csv"
printf 'epoch,label,phase,pid,comm,cpu,mem,rss_kb\n' > "$RAW/process-snapshots.csv"

for rep in $(seq 1 "$REPS"); do
  run_condition "tiny_same_clean_rep${rep}" "single" "$TINY_CLEAN"
  run_condition "tiny_same_quarantined_rep${rep}" "single" "$TINY_QUAR"
  run_condition "tiny_many_clean_rep${rep}" "many" "$MANY_CLEAN"
  run_condition "tiny_many_quarantined_rep${rep}" "many" "$MANY_QUAR"
done

for rep in $(seq 1 3); do
  xattr -d com.apple.quarantine "$REAL_CODEX" 2>/dev/null || true
  run_condition "real_codex_clean_path_rep${rep}" "single" "$REAL_CODEX" "help"
  xattr -w com.apple.quarantine "0381;00000000;RealCodexTempBenchmark;00000000-0000-0000-0000-000000000012" "$REAL_CODEX"
  run_condition "real_codex_temp_quarantined_path_rep${rep}" "single" "$REAL_CODEX" "help"
  xattr -d com.apple.quarantine "$REAL_CODEX" 2>/dev/null || true
done

{
  printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'real_codex_final_quarantine='
  xattr -p com.apple.quarantine "$REAL_CODEX" 2>/dev/null || printf 'absent'
  printf '\n'
  printf 'fixture_quarantine_hits=\n'
  find "$WORK" -xattrname com.apple.quarantine -print 2>/dev/null | head -n 100
} > "$OUT/state-after.txt"

printf 'Case-study extras complete. Raw output: %s\n' "$RAW"
