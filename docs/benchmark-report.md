# syspolicyd / Gatekeeper Codex Benchmark

Date: 2026-07-05

## Scope

Goal: measure whether removing `com.apple.quarantine` from trusted Codex binaries/project files helps while running many Codex-like process spawns, and compare limited alternatives without disabling Gatekeeper globally.

No global Gatekeeper setting was changed. `spctl --master-disable` was not run.

## Tested Paths

- Codex shim: `/opt/homebrew/bin/codex`
- Real Codex binary on the test machine: Homebrew Caskroom Codex binary.
- Project: a local Codex scratch folder that was later cleaned into this public repo.
- Disposable fixtures: copied Codex binaries and tiny test executables created under a local work directory.

The disposable fixtures were deleted after the benchmark because they temporarily consumed about 9.9 GB.

## Workload

Each run used:

- `TOTAL=20`
- `CONCURRENCY=5`
- `REPS=3`
- command: `codex help`

Conditions per run:

- `real_clean`: real cleaned Codex binary.
- `copy_clean`: one copied Codex binary with quarantine removed.
- `copy_quarantined`: one copied Codex binary with synthetic quarantine xattr.
- `project_clean`: 20 copied Codex binaries in a disposable project tree, quarantine removed.
- `project_quarantined`: 20 copied Codex binaries in a disposable project tree, synthetic quarantine xattr.

## Runs

- `baseline`: normal `syspolicyd`, nice `0`.
- `renice_plus10`: `syspolicyd` temporarily set to nice `10`.
- `renice_plus19`: `syspolicyd` temporarily set to nice `19`.
- `after_syspolicyd_restart`: `syspolicyd` restarted, then benchmarked again at nice `0`.

Admin commands used:

```sh
renice +10 -p 512
renice 0 -p 512
renice +19 -p 512
renice 0 -p 512
killall syspolicyd
```

They were executed through macOS administrator prompts because noninteractive `sudo` could not read a password in this session. The PID was checked before each operation during the run; the fixed PID shown above is only the value from the original machine at that moment.

## Timing Summary

Average elapsed time per 20 spawns:

| Run | real_clean | copy_clean | copy_quarantined | project_clean | project_quarantined |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline | 0.265s | 0.963s | 0.770s | 10.926s | 11.747s |
| renice_plus10 | 0.317s | 1.180s | 0.824s | 11.453s | 12.994s |
| renice_plus19 | 0.266s | 1.027s | 0.986s | 10.898s | 11.737s |
| after_syspolicyd_restart | 0.191s | 1.551s | 1.151s | 10.904s | 11.321s |

All runs completed with `0` workload failures.

## syspolicyd Peaks

Peak sampled `syspolicyd` CPU:

| Run | real_clean | copy_clean | copy_quarantined | project_clean | project_quarantined |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline | 65.7% | 141.3% | 141.3% | 136.3% | 146.8% |
| renice_plus10 | 172.7% | 108.8% | 42.6% | 113.3% | 271.0% |
| renice_plus19 | 184.4% | 179.4% | 179.4% | 108.4% | 184.4% |
| after_syspolicyd_restart | 126.4% | 126.9% | 134.5% | 154.1% | 141.2% |

These are snapshot peaks, not continuous traces. They are still enough to show the pattern: many distinct copied executable paths provoke `syspolicyd`, even when quarantine is removed.

## Findings

1. The original cleanup helped the real Codex binary path.
   - The real cleaned binary averaged under 0.4s per 20 local `codex help` spawns in every run.
   - Final verification: real Codex binary has no `com.apple.quarantine`.

2. The main spike trigger is not only quarantine metadata.
   - Launching many distinct copied Codex binaries from a project tree caused the largest delays.
   - Clean copied binaries and quarantined copied binaries both produced slow first-pass behavior.
   - This points to Gatekeeper/code-signing assessment for new executable paths, not just quarantine.

3. `renice` is not a good mitigation.
   - Nice `10` and nice `19` did not make the workload faster.
   - Nice `10` made `project_quarantined` slower than baseline.
   - Nice `19` did not materially improve the copied-project case.
   - `syspolicyd` was restored to nice `0`.

4. Restarting `syspolicyd` is not a performance fix for this workload.
   - After restart, copied/project conditions still spiked and stayed slow.
   - Restarting may help only when the daemon is genuinely stuck after the workload ends.

5. Cache effects are strong.
   - First runs of copied binaries were much slower.
   - Later repetitions often dropped below 1s.
   - This matches a first-assessment/cache-warmup pattern.

## Recommendation

Keep the targeted quarantine cleanup for trusted Codex/app/project paths. Do not disable Gatekeeper globally.

Avoid workflows that copy or generate lots of executable binaries into new paths and immediately spawn them concurrently. If a workflow must do that, expect the first run to be slow while macOS assesses those binaries; warm it once at low concurrency before running many agents.

Do not run Codex with `syspolicyd` permanently reniced. It did not improve the benchmark and could make security assessment scheduling less predictable.

Only restart `syspolicyd` if it remains hot after the workload ends. In this benchmark it recovered to idle on its own.

## Final State

- Real Codex binary quarantine: absent.
- Project quarantine hits outside saved output/work report folders: none found on the test machine.
- Generated benchmark binary fixtures: deleted.
- `syspolicyd`: running, nice `0`, idle at final check.

## Case Study Follow-Up

The first copied-Codex benchmark was useful, but noisy: copied Codex binaries are large, the original real binary had already been cleaned, and cache effects dominated later repetitions. A second focused benchmark was added with a tiny locally compiled Mach-O executable.

Additional test:

- tiny executable, same path, quarantine removed.
- tiny executable, same path, synthetic quarantine.
- 50 tiny executable copies, quarantine removed.
- 50 tiny executable copies, synthetic quarantine.
- real Codex path, clean.
- real Codex path, temporarily synthetic-quarantined, then restored.

Settings:

- tiny executable tests: 100 launches per rep, concurrency 10, 5 reps.
- real Codex path tests: 100 `codex help` launches per rep, concurrency 10, 3 reps.
- timeout: 5s per process.

### Additional Timing Summary

| Condition | Avg elapsed | Min | Max | Reps | Output validation |
| --- | ---: | ---: | ---: | ---: | --- |
| tiny same-path clean | 0.224s | 0.099s | 0.443s | 5 | 100/100 outputs each rep |
| tiny same-path quarantined | 49.383s | 45.602s | 50.343s | 5 | 0/100 outputs; timeout-limited |
| tiny many-path clean | 1.262s | 0.095s | 5.911s | 5 | 100/100 outputs each rep |
| tiny many-path quarantined | 50.321s | 50.308s | 50.331s | 5 | 0/100 outputs; timeout-limited |
| real Codex clean path | 1.632s | 0.538s | 2.199s | 3 | full `codex help` output each rep |
| real Codex temp-quarantined path | 1.806s | 0.542s | 2.696s | 3 | full `codex help` output each rep |

Important correction: the tiny quarantined conditions did not complete successfully. They reached the timeout budget and produced no `ok` output. The earlier failure counter only counted stderr lines, so the report uses stdout validation for this section.

### Case Study Interpretation

The cleanest case-study story is:

1. A trusted, cleaned Codex install is fast enough under repeated local launches.
2. Quarantine metadata can be catastrophic for small generated/unsigned executables: the tiny quarantined executable produced zero successful launches under the timeout.
3. Many distinct executable paths create first-run Gatekeeper assessment cost even without quarantine, shown by the first `tiny_many_clean` rep at 5.911s dropping to about 0.1s after cache warmup.
4. Re-adding quarantine temporarily to the real Codex path did not reproduce the catastrophic tiny-executable behavior, likely because Codex is a known/signed/notarized binary and the path was already assessed. This is useful nuance: the safe fix is still removing quarantine from trusted Codex, but the broader operational lesson is to avoid spawning lots of new quarantined or freshly generated executable paths.
5. `renice` and daemon restart are weaker mitigations than removing quarantine and reducing executable path churn.

### Better Case Study Angle

Title idea:

> Why my Mac was burning CPU on Codex: measuring Gatekeeper overhead instead of disabling it

Structure:

1. Symptom: multiple Codex tasks caused `syspolicyd` spikes.
2. Constraint: do not disable Gatekeeper globally.
3. Intervention: remove quarantine only from trusted Codex/project paths.
4. Benchmark: compare cleaned Codex, copied binaries, quarantined fixtures, daemon priority changes, and restart.
5. Finding: quarantine and new executable paths are the problem; `renice` and restart are not real fixes.
6. Practical rule: keep trusted tools quarantine-free, avoid generating/spawning lots of new executable paths, warm caches at low concurrency, restart `syspolicyd` only if it remains stuck after the workload.
