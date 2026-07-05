# macOS Gatekeeper / syspolicyd Codex benchmark

This repo contains a small case study and benchmark scripts for investigating repeated macOS `syspolicyd` / Gatekeeper checks while running many Codex-style process launches.

The goal was deliberately narrow:

- reduce avoidable security-check overhead for trusted Codex binaries;
- avoid disabling Gatekeeper globally;
- compare safer alternatives like targeted quarantine cleanup, daemon restart, and temporary `renice` experiments;
- keep enough raw data to make the result inspectable.

## Short version

Targeted quarantine cleanup helped the real Codex binary path, but the bigger lesson was that macOS can spend a lot of time assessing many fresh executable paths. Launching quarantined or newly copied executables concurrently is much worse than repeatedly launching one already-assessed trusted binary.

The useful mitigation is not to disable Gatekeeper. It is to:

1. remove `com.apple.quarantine` only from trusted tools or project files;
2. avoid generating/copying many executable binaries into new paths and spawning them immediately at high concurrency;
3. warm new executable paths at low concurrency if a workflow really needs them;
4. restart `syspolicyd` only if it remains hot after the workload ends.

## Results

The full narrative is in [docs/benchmark-report.md](docs/benchmark-report.md).

Compact result files:

- [results/summary/timing-summary.csv](results/summary/timing-summary.csv)
- [results/summary/syspolicyd-peaks.csv](results/summary/syspolicyd-peaks.csv)
- [results/summary/output-validation.csv](results/summary/output-validation.csv)

Sanitized raw CSVs are under [results/raw](results/raw). Repeated stdout dumps and temporary benchmark binaries are intentionally not committed.

## Headline measurements

Main Codex-copy benchmark, average elapsed time per 20 launches:

| Condition | Baseline | `renice +10` | `renice +19` | After `syspolicyd` restart |
| --- | ---: | ---: | ---: | ---: |
| real cleaned Codex path | 0.265s | 0.317s | 0.266s | 0.191s |
| single clean copied Codex binary | 0.963s | 1.180s | 1.027s | 1.551s |
| 20 clean copied Codex binaries | 10.926s | 11.453s | 10.898s | 10.904s |
| 20 quarantined copied Codex binaries | 11.747s | 12.994s | 11.737s | 11.321s |

Focused tiny executable benchmark:

| Condition | Average elapsed | Output validation |
| --- | ---: | --- |
| tiny same-path clean | 0.224s | 100/100 outputs each rep |
| tiny same-path quarantined | 49.383s | 0/100 outputs; timeout-limited |
| tiny many-path clean | 1.262s | 100/100 outputs each rep |
| tiny many-path quarantined | 50.321s | 0/100 outputs; timeout-limited |

## Re-running

The scripts are macOS-oriented and assume:

- `zsh`
- `xattr`
- GNU `timeout` from Homebrew coreutils (`timeout` or `gtimeout`; override with `TIMEOUT_BIN`)
- `clang` for the tiny executable benchmark
- Codex CLI on `PATH`

Run the main benchmark:

```sh
RUN_ID=baseline TOTAL=20 CONCURRENCY=5 REPS=3 CMD_TIMEOUT=8 scripts/run-codex-gatekeeper-benchmark.zsh
```

Run the focused tiny-executable and temporary real-Codex A/B benchmark:

```sh
TOTAL=100 CONCURRENCY=10 REPS=5 CMD_TIMEOUT=5 MANY_COUNT=50 scripts/run-case-study-extras.zsh
```

Generated outputs go to `results/generated/` and temporary files go to `.work/`; both are ignored by Git.

## Safety notes

These benchmarks intentionally create synthetic quarantine attributes on disposable copied executables. The scripts should not disable Gatekeeper globally.

The original run also tested temporary `renice` and `killall syspolicyd` conditions with administrator approval. Those commands are documented in the report but are not required for normal reproduction.

## License

MIT
