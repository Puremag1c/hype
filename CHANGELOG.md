# Changelog

## [2.0.14] - 2026-02-08

### Fixed

- **CRITICAL: flock serialization for all bd commands** - All `bd` calls across HYPE now use centralized `bd_safe()` wrapper with flock serialization. Prevents beads daemon explosion (270+ daemon processes) when parallel agents overwhelm the socket.

- **Centralized bd_safe in common.sh** - Single source of truth for bd wrapper with:
  - `flock /tmp/hype-bd.lock` - serializes all bd calls
  - `timeout_cmd 10s` - prevents hangs on unresponsive daemon
  - Error logging on timeout (exit code 124)

- **Updated scripts to use bd_safe:**
  - `common.sh` - centralized wrapper with flock
  - `hype.sh` - all bd calls serialized
  - `run-executors.sh` - all bd calls serialized
  - `run-senior-executor.sh` - all bd calls serialized
  - `run-analysts.sh` - removed duplicate bd_safe, uses common.sh
  - `run-testers.sh` - removed duplicate bd_safe, uses common.sh
  - `detect-phase.sh` - now sources common.sh, uses bd_safe
  - `doctor.sh` - uses bd_safe
  - `close-completed-parents.sh` - sources common.sh, uses bd_safe

- **Root cause of daemon explosion** - Multiple parallel bd calls would simultaneously:
  1. Try to connect to daemon socket
  2. Get timeout/error (socket overloaded)
  3. Assume daemon is dead
  4. Each spawn a NEW daemon
  5. Result: 270+ daemon processes fighting for socket

- **flock solution** - Only one bd command executes at a time. Queue forms naturally. No parallel socket abuse. Daemon stays stable.

---

## [2.0.13] - 2026-02-08

### Fixed

- **CRITICAL: set -e kills script on agent timeout** - Fixed bug where `set -euo pipefail` would terminate entire script when `run_claude_with_progress` returned non-zero (timeout=124 or failure). Now uses `|| exit_code=$?` pattern to properly capture exit code without triggering set -e.

- **Affected files:**
  - `run-testers.sh` - tester agent timeout now handled gracefully
  - `run-executors.sh` - executor and auditor timeout now handled gracefully
  - `run-analysts.sh` - analyst timeout now handled gracefully

- **Added bd_safe to run-analysts.sh** - All `bd` commands now wrapped with timeout protection (consistent with run-testers.sh fix in 2.0.12).

- **Root cause of "Terminated: 15" crash** - When functional tester hit 10-minute timeout, SIGTERM was sent (exit 124), but `set -e` killed the script before error handling code could execute. This caused hype.sh to exit with code 124 instead of gracefully recovering.

---

## [2.0.12] - 2026-02-08

### Fixed

- **CRITICAL: Beads daemon hang protection** - All `bd` commands in `run-testers.sh` now wrapped with `bd_safe()` which applies 10-second timeout via `timeout_cmd`. Previously, if beads daemon became unresponsive (daemon explosion bug), `bd show/list/update/create/close` calls would hang forever, freezing SMOKE_TEST phase indefinitely.

- **Beads health check at SMOKE_TEST start** - Added daemon health check before running testers. If `bd stats` times out, attempts automatic restart (`bd daemon restart`). If recovery fails, logs FATAL error with manual fix instructions instead of hanging.

- **Root cause of 4+ hour SMOKE_TEST freeze** - Functional tester would complete successfully, but post-completion `bd show` (line 227) to verify trigger status would hang when daemon was unresponsive. Visual tester never started, run-testers.sh became orphan process (PPID=1).

---

## [2.0.11] - 2026-02-06

### Changed

- **Removed hardcoded config validation** - `validate_testing_config()` deleted. LLM (Opus) creates testing.yaml via `ensure_testing_config()` with improved prompts (2.0.10). If config is wrong, testers will find bugs naturally. No hardcoded language-specific checks.

- **Updated troubleshooting docs** - Added "Testers see OLD code" problem for Doctor agent with manual fix instructions

---

## [2.0.10] - 2026-02-06

### Fixed

- **SMOKE_TEST stale code prevention** - Complete rewrite of `testing.yaml` guidance to ensure testers always see fresh code:
  - **Build command now required for packages** - Old guidance said "Python doesn't need build" which was WRONG for installed packages
  - **Python editable install** - Explicit instruction to use `.venv/bin/pip install -e .` as build_command
  - **Runtime warning for Python packages** - `run_build()` warns if pyproject.toml/setup.py exists but no build_command
  - **Language-specific examples** - Added build/start commands for Python, Node.js, Go, Elixir, Rust

  This fixes the cycle: IMPLEMENTATION → SMOKE_TEST → bug → fix → SMOKE_TEST seeing old code

---

## [2.0.9] - 2026-02-06

### Fixed

- **Python venv detection in SMOKE_TEST** - Testers creating `testing.yaml` now get explicit guidance to use venv python (`.venv/bin/python`) instead of system python. Added runtime warning in `start_dev_server()` if project has `.venv/` but `start_command` uses bare `python3`. Prevents testing outdated installed packages instead of current source code.

---

## [2.0.8] - 2026-02-06

### Fixed

- **`hype upgrade` now always recreates symlinks** - Previously upgrade only updated symlinks if they already existed (`-L` check). Now upgrade handles missing, broken, or directory cases - always recreates `.claude/agents`, `.claude/commands`, and `scripts/` symlinks to point to global installation. Fixes "Agent file not found" errors after symlinks are deleted or corrupted.

---

## [2.0.7] - 2026-02-06

### Fixed

- **Trigger tasks no longer block phase transitions** - detect-phase.sh now uses `--label=trigger` for identification instead of hardcoded title patterns. Trigger tasks (run-tester-*, run-analyst-*, run-plan-review, etc.) are excluded from P0 bug count and don't prevent IMPLEMENTATION→SMOKE_TEST transition.

- **Zombie tail/jq processes eliminated** - run_claude_with_progress now saves tail PID to file for explicit cleanup. Added running_marker file for graceful shutdown. Cleanup sequence properly terminates grandchild processes (tail, jq) that previously survived parent death.

### Changed

- **All trigger task creation uses `--label=trigger`** - hype.sh, run-testers.sh now add trigger label when creating run-* tasks. This enables extensible trigger detection without code changes.

- **detect-phase.sh hybrid detection** - Primary detection by label, fallback to title patterns for backward compatibility with pre-label triggers.

---

## [2.0.6] - 2026-02-06

### Fixed

- **Local tests work without GNU parallel** - `bats --jobs 4` now only used if `parallel` command is available. Local environments without parallel installed now run tests sequentially.

---

## [2.0.5] - 2026-02-06

### Fixed

- **Symlink bug in doctor_test.bats** - `mkdir` created scripts/ directory before `ln -sf`, causing symlink to be placed inside as `scripts/scripts` instead of replacing it. Test "Doctor: can detect current phase" now passes.

---

## [2.0.4] - 2026-02-06

### Changed

- **Removed unnecessary skip_if_ci** - Reverted skip added in 2.0.4 since root cause was symlink bug, not CI timing.

---

## [2.0.3] - 2026-02-06

### Fixed

- **CI: install GNU parallel** - `bats --jobs` requires GNU `parallel` which was missing in CI runners. Now installed via brew (macOS) and apt (Linux).

---

## [2.0.2] - 2026-02-06

### Fixed

- **Zombie tail processes on tester interrupt** - `run_claude_with_progress` now uses trap to kill entire process group (tail + jq) on EXIT/INT/TERM, preventing zombie processes when wrapper is interrupted.
- **Tester tasks left in_progress on abnormal exit** - `run_tester` now has cleanup trap that closes beads task if wrapper script is killed before normal completion.

---

## [2.0.1] - 2026-02-06

### Changed

- **CI: parallel test execution** - Integration and e2e tests now run with `bats --jobs 4` for faster CI
- **Test helpers** - Added `skip_if_ci` and `skip_if_flaky` helpers for timing-dependent tests

---

## [2.0.0] - 2026-02-06

### Added

- **Testing Infrastructure** - Complete bats test suite with 133 tests covering all HYPE components:
  - `tests/unit/common_test.bats` — 42 unit tests for common.sh functions
  - `tests/integration/detect_phase_test.bats` — 21 tests for phase detection
  - `tests/integration/hype_test.bats` — 24 tests for hype.sh/bin/hype
  - `tests/integration/executors_test.bats` — 19 tests for run-executors.sh
  - `tests/integration/doctor_test.bats` — 15 tests for Doctor diagnostics
  - `tests/e2e/phase_flow_test.bats` — 12 tests for complete phase transitions (INIT → DONE)
- **Test helpers** - Reusable test infrastructure:
  - `tests/helpers/setup.bash` — common setup/teardown with isolated temp directories
  - `tests/helpers/mock_bd.bash` — mock beads for unit test isolation
  - `tests/fixtures/` — task JSONs and config files for testing
  - `tests/run_tests.sh` — test runner with auto bats install
- **CI/CD workflow** - GitHub Actions for automated testing:
  - `.github/workflows/test.yml` — parallel jobs for unit/integration/e2e
  - Runs on both macOS and Ubuntu
  - Unit tests required, integration/e2e optional (continue-on-error)

---

## [1.9.20] - 2026-02-06

### Added

- **Doctor agent** - New diagnostic agent for runtime HYPE problems. Run `hype doctor` when something goes wrong. Doctor collects system state, matches symptoms to known issues, and creates a doctor-log for the architect. Can also apply runtime fixes (stuck tasks, orphaned labels) with user confirmation.
  - `core/agents/doctor.md` — agent prompt
  - `core/scripts/doctor.sh` — entry point
  - `hype doctor` command added to CLI
  - `hype doctor --report` for non-interactive mode

### Changed

- **Documentation updated** - `docs/architecture.md` and `docs/troubleshooting.md` updated with current agent structure (24 agents), decomposed architects, and known issues for Doctor.
- **PROJECT.md actualized** - Reflects current 24-agent structure, 6 testers, versioner, auditor.

---

## [1.9.19] - 2026-02-06

### Changed

- **Decomposed architect.md into 4 specialized agents** - Single 600-line architect.md split into focused agents for better LLM comprehension:
  - `architect-planner.md` — creates plan from SPEC.md (opus)
  - `architect-reviewer.md` — reviews analyst additions and audit results (opus)
  - `architect-qa.md` — final review and smoke test regression handling (opus)
  - `architect-ops.md` — resolves conflicts and dependency cycles (sonnet)
- **architect-ops uses sonnet** - Mechanical operations (git conflicts, cycle fixes) don't need opus-level reasoning, reducing cost.

---

## [1.9.18] - 2026-02-06

### Fixed

- **Audit task detection was too aggressive** - Keywords in title (Verify/Audit/Check/Validate) and done_when heuristics caused false positives. Tasks like "Add email verification" were incorrectly routed to Auditor, which produced findings instead of code, causing senior-executor to get stuck (no commits). Now uses explicit opt-in only: label `audit` or "AUDIT SCOPE" in description. Default = code task (safer fallback).

---

## [1.9.17] - 2026-02-06

### Added

- **Versioner agent** - New dedicated agent for updating VERSION and CHANGELOG after successful FINAL_REVIEW. Removes versioning responsibility from Architect (was often skipped). Uses haiku model for cost efficiency.

### Changed

- **Architect no longer handles versioning** - Versioning steps removed from architect.md. HYPE now calls versioner agent automatically after `FINAL_REVIEW: PASSED`.

---

## [1.9.16] - 2026-02-06

### Fixed

- **Race condition in milestone creation** - Milestones were created prematurely when trigger tasks were `in_progress` (not visible to `--status=open` check). After timeout, triggers returned to `open` but milestone already existed, causing deadlock. Now checks both `open` AND `in_progress` statuses before creating milestones.
- **Self-healing for premature milestones** - `detect-phase.sh` now detects and removes `milestone:analysts-done` if analyst triggers are still pending, automatically recovering from race conditions.

---

## [1.9.15] - 2026-02-06

### Changed

- **Gradual model escalation** - Instead of jumping directly to opus on failure, models now escalate one level at a time: `haiku → sonnet → opus`. Applies to audit retries (executor, senior-executor) and review retries.

---

## [1.9.14] - 2026-02-06

### Fixed

- **Model escalation ignored** - When escalating to opus, old model labels (`model:haiku`, `model:sonnet`) were not removed. This caused `head -1` to return the old label. Fixed in all 3 escalation points: review retry, audit retry (executor), audit retry (senior-executor).

---

## [1.9.13] - 2026-02-06

### Changed

- **Config cleanup on upgrade** - `hype upgrade` now removes deprecated variables from `.hype/config.sh` that are no longer in the template.

---

## [1.9.12] - 2026-02-06

### Changed

- **Disable spinner tips in projects** - `hype init` creates `.claude/settings.json` with `spinnerTipsEnabled: false`. `hype upgrade` adds this setting to existing projects.

---

## [1.9.11] - 2026-02-06

### Fixed

- **hype clear not cleaning ALL stashes** - Previous fix (1.9.10) only dropped stashes with "hype" in the message. Now uses `git stash clear` to remove ALL stashes for a clean iteration start.

- **hype clear not deleting closed tasks** - `bd admin cleanup --force` was silently failing (stderr redirected to /dev/null). Now shows cleanup output for visibility.

---

## [1.9.10] - 2026-02-06

### Added

- **Backend tester** - New `tester-backend.md` agent that runs existing project tests (pytest, npm test, mix test, etc.) and generates tests for SPEC.md requirements not covered. Uses sonnet model.

### Fixed

- **Milestone tasks picked up by executor/review** - `run-executors.sh` and `run-senior-executor.sh` now filter out tasks with `milestone:*` labels. Previously only title was checked, so milestones with titles like "Planning complete" bypassed the filter.

- **Auditor model escalation** - Auditor now checks for `model:opus` label and escalates from sonnet→opus on timeout/failure. After 3 failures, escalates to Architect with full context.

- **Audit NO_FINDINGS retry tracking** - When auditor produces insufficient findings (<50 chars), task gets `audit-retry:N` label with escalation: retry 1 (sonnet), retry 2 (opus), retry 3 → escalate to Architect.

- **Playwright tester conflict** - `functional` and `visual` testers now run sequentially instead of parallel to avoid Playwright MCP conflicts. Other testers (backend, api, cli) still run in parallel.

- **hype clear not cleaning stash** - Fixed stash cleanup in `cleanup_iteration()`. Previous code failed because stash indices shift after each drop. Now uses loop to drop hype-related stashes correctly.

- **hype clear leaving open tasks** - `bd admin cleanup` only deletes closed tasks. Now closes all open/in_progress tasks first before cleanup. Also fixed stash count integer error (`grep -c` → `wc -l`).

---

## [1.9.9] - 2026-02-06

### Fixed

- **Phase detection not seeing closed milestones** - `detect-phase.sh` now uses `bd list --all` to include closed issues. This was the second occurrence of the same bug fixed in 1.9.8 (which only fixed `has_milestone()` but not `detect-phase.sh`).

---

## [1.9.8] - 2026-02-06

### Fixed

- **Milestone not visible after creation** - `has_milestone()` now uses `bd list --all` to include closed issues. Previously milestones were created and immediately closed, but `bd list` without `--all` only shows open issues, so milestones were never detected.

---

## [1.9.7] - 2026-02-06

### Fixed

- **Beads installation uses homebrew-core** - `install.sh` now uses `brew install beads` (homebrew-core, latest) instead of `brew tap steveyegge/beads && brew install bd` (tap, outdated 0.49.0). Tap version had SQLite bugs causing daemon zombie state. Existing tap installations are auto-migrated.

- **Milestone visibility after creation** - `ensure_milestone()` now uses `bd sync --force` and retries 10 times (up from 5) to ensure milestone is visible to subsequent `bd list` calls. Addresses daemon cache not invalidating after writes.

### Changed

- **New HYPE color scheme** - Updated branding from fire gradient (red→orange→yellow→lime) to neon pink gradient (H=#ff0066, Y=#ff3399, P=#ff66cc, E=#ccff00). Applied to all log outputs and ASCII art logo across all scripts.

---

## [1.9.6] - 2026-02-06

### Fixed

- **Phase transition race condition** - `ensure_milestone()` now includes `bd sync` + verify loop after creating milestone. Previously, bd daemon cache could be stale, causing `detect-phase.sh` to not see the milestone and repeat the same phase (e.g., two PLANNING cycles in a row). Root cause: SQLite write not visible to subsequent `bd list` due to daemon cache inconsistency.

---

## [1.9.5] - 2026-02-06

### Fixed

- **Colorful HYPE in all log outputs** - Fire gradient colors now applied to all log functions across scripts: hype.sh, run-executors.sh, run-analysts.sh, run-testers.sh, run-senior-executor.sh. Previously only bin/hype had colors.

- **Tasks hanging after cleanup** - Added `--force` flag to `bd admin cleanup` in `cleanup_iteration()`. Without it, closed tasks were not properly cleaned and accumulated.

---

## [1.9.4] - 2026-02-06

### Added

- **Colorful HYPE branding** - "HYPE" text now renders with fire gradient colors (H=Red, Y=Orange, P=Yellow, E=Lime) in terminal output. Applied to CLI commands (init, start, status, help).

- **ASCII art logo** - New ASCII art banner displayed on `hype init`, `hype start`, and `hype help`. Makes startup more visually distinctive.

### Changed

- **README.md** - Bilingual (EN/RU), daring style, ASCII art header.

---

## [1.9.3] - 2026-02-06

### Fixed

- **SPEC.prev.md in target project gitignore** - Added `SPEC.prev.md` to gitignore template for target projects. File is generated during `cleanup_iteration()` and should not be tracked. Added to `hype init` and `hype update` paths.

### Changed

- **Auto-commit/push gitignore on update** - `hype update` now auto-commits and pushes `.gitignore` changes if remote exists. Keeps target project repos clean without manual intervention.

---

## [1.9.2] - 2026-02-05

### Fixed

- **JSON validation in detect-phase.sh** - Added jq availability check and validation that `bd list` returns valid JSON arrays. Previously, malformed JSON caused all counters to silently become 0, leading to wrong phase detection.

- **Lock file not released on exit** - Added `trap EXIT` to `acquire_lock()`. Previously, lock file was only removed on SIGINT/SIGTERM. Any `exit 1` (config validation, beads check failure) left the lock file, blocking subsequent runs.

- **Temp file leak in detect_phase()** - Replaced `mktemp` with fixed file `$CLAUDEV_DIR/detect-phase-stderr.tmp`. Previously, temp files accumulated in /tmp on crash/SIGKILL. Now single file is reused and cleaned with `hype clear`.

- **Milestone detection race condition** - Milestones are now searched in ALL tasks, not just closed. If `bd close` fails, milestone was stuck in open status and phase detection broke. Principle: "milestone exists = phase complete" regardless of task status.

### Changed

- **TASK_STALE_TIMEOUT from config** - `check_stale_tasks()` now uses `$TASK_STALE_TIMEOUT` from config instead of hardcoded 600s. Added validation for this parameter. Power users can tune stale detection threshold.

---

## [1.9.1] - 2026-02-05

### Fixed

- **deep-analyze.sh permission-mode** - Added `--permission-mode bypassPermissions` to Claude call. Analysis no longer fails in non-interactive mode.

- **deep-analyze.sh file count** - Excluded `node_modules`, `dist`, `build`, `.git`, `vendor`, `__pycache__` from file count. Projects with 30 real files no longer show 500+ due to dependencies.

- **detect_phase() JSON consistency** - Error cases now return JSON format (`{"phase":"UNKNOWN",...}`) instead of plain strings. Consistent contract for all callers.

- **bd admin cleanup flags** - Removed invalid `--all --force` flags that caused silent failures.

### Added

- **Cleanup in_progress warning** - `cleanup_iteration()` now warns when tasks are in progress. Requires double confirmation before destroying active work.

- **Cleanup preview** - Shows complete list of what will be deleted: logs, tasks, milestones, worktrees, stashes, SPEC.md.

- **analyze-project.sh retry/fallback** - Added `retry_command()` wrapper (3 attempts) and `create_minimal_project_context()` fallback. INIT phase no longer blocks on transient failures.

---

## [1.9.0] - 2026-02-05

### Added

- **`hype clear` command** - Manual cleanup of iteration data. Removes logs, stale worktrees, milestones, and archives SPEC.md. Use after DONE phase or when you want to start fresh.

- **Interactive cleanup prompt** - After DONE phase, system now asks whether to run cleanup instead of automatic cleanup. User can decline and run `hype clear` manually later.

### Changed

- **Centralized bd data cache** - `detect-phase.sh` now outputs JSON with full metadata instead of plain phase string. Reduced bd list/show calls from 10-20+ per HYPE cycle to ≤5 calls.

- **JSON output from detect-phase.sh** - New format includes: phase, stats (total/open/in_progress/closed), progress_pct, in_progress_ids, regression_count, p0_bugs.

- **Optimized run-analysts.sh** - Caches `bd list --json` at start and passes to each analyst. No more individual bd calls per analyst.

- **Optimized run-testers.sh** - Same caching pattern as analysts. Single bd list call shared across all testers.

- **Optimized run-executors.sh** - `count_active_executors()` now accepts optional cache parameter.

- **Optimized show_active_work()** - Uses in_progress_ids from phase JSON instead of `bd show` per task.

---

## [1.8.6] - 2026-02-05

### Changed

- **Configurable stale timeouts** - `WORKTREE_STALE_TIMEOUT` and `TASK_STALE_TIMEOUT` now configurable in `.hype/config.sh`. Defaults: 900s (worktrees), 600s (tasks).

- **Cross-platform notifications** - `notify.sh` now supports Linux (notify-send) and WSL (PowerShell toast) in addition to macOS (osascript). Graceful fallback to echo.

- **WSL date parsing** - Added python3 fallback for date parsing in `common.sh` when both macOS and Linux `date` commands fail.

- **Updated architecture.md** - Added SMOKE_TEST/SMOKE_REVIEW phases, all 12 scripts, Testers agents section, testing.yaml documentation.

### Removed

- **Scope violation check** - Removed unused complexity from `run-senior-executor.sh`, `common.sh`, and `executor.md`. Code review already handles scope contextually. The check only worked for ~50% of tasks and caused infinite loops after escalation.

---

## [1.8.5] - 2026-02-05

### Added

- **SMOKE_REVIEW phase** - Explicit phase for handling regression bugs. Prevents race condition between Architect and Executor - regressions are now processed before executors can grab them. Flow: `SMOKE_TEST → SMOKE_REVIEW → IMPLEMENTATION`.

- **Deep analysis for large projects** - INIT phase now runs `deep-analyze.sh` for existing projects with >50 code files and no good README. Tech Writer gets enriched context about architecture before gathering requirements.

### Changed

- **Beads daemon recovery** - `check_beads()` now uses timeout (5s) to prevent hanging when daemon is frozen. Retries 3 times with `bd daemon restart .` before failing.

### Removed

- **Unused config options** - Removed `CI_ENABLED`, `CD_ENABLED`, `CLEANUP_ENABLED`, `CLEANUP_KEEP_DAYS`, `USER_INPUT_TIMEOUT` from config template and validation. These were never implemented.

---

## [1.8.4] - 2026-02-05

### Fixed

- **Architect smoke_review gets no task IDs** - The `run_agent_with_mode` call had empty prompt, so Architect didn't know which regression tasks to review. Now passes task IDs: `"REGRESSION TASKS TO REVIEW: <id>: <title>..."`.

- **Stale reset loops regression tasks** - `reset_stale_tasks()` was resetting regression tasks to `open` status while keeping the label, causing infinite smoke_review cycles. Now skips tasks with `regression` label.

---

## [1.8.3] - 2026-02-05

### Fixed

- **Revert v1.8.2: Don't check in_progress for regressions** - Checking in_progress tasks caused Architect and Executor to work on the same task simultaneously. Now only checks `open` tasks. If executor already grabbed a regression task, let it finish - next SMOKE_TEST will catch if still broken.

---

## [1.8.2] - 2026-02-05 (REVERTED)

### Fixed (broken)

- ~~Regression check misses in_progress tasks~~ - This caused parallel conflicts between Architect and Executor.

---

## [1.8.1] - 2026-02-05

### Fixed

- **Executors grab regression tasks before Architect** - Added filter to `get_ready_tasks()` to exclude tasks with `regression` label. These now wait for Architect smoke_review.

- **Regressions not processed in IMPLEMENTATION phase** - Added regression check at start of IMPLEMENTATION phase. If regressions exist, Architect runs smoke_review before executors start.

---

## [1.8.0] - 2026-02-05

### Added

- **Regression detection in SMOKE_TEST** - Testers now detect when a bug was previously "fixed" but returned. Instead of creating duplicate bugs, they reopen the original with `regression` label.

- **Smoke review mode for Architect** - New `MODE: smoke_review` routes regression bugs to Architect for analysis. Options: update scope, escalate model (sonnet→opus), send to analysts, or downgrade to P2.

- **Bug Creation Protocol for testers** - All 5 testers now follow a protocol: check for OPEN duplicates (skip), check for CLOSED similar bugs (reopen as regression), then create new with `done_when`.

### Changed

- **Testers add done_when to bugs** - All bug creation examples now include `done_when:` criteria so reviewers can verify fixes.

### Fixed

- **Infinite bug loop** - Previously testers created duplicate bugs every SMOKE_TEST cycle, causing infinite implementation loops. Now duplicates are detected and regressions are properly escalated.

---

## [1.7.7] - 2026-02-05

### Fixed

- **Active log shows stale tasks** - `show_active_work()` showed tasks from old log files even if task was already closed. Now checks task status in beads - only shows tasks that are actually `in_progress`.

---

## [1.7.6] - 2026-02-05

### Changed

- **Testers create P1/P2 bugs too** - Added explicit rules for minor/cosmetic issues. Testers must report everything: P0 for must-have failures, P1 for broken features, P2 for cosmetic/minor issues.

---

## [1.7.5] - 2026-02-05

### Fixed

- **Testers skip bug creation if "similar exists"** - Testers were not creating P0 bugs when they found issues, claiming "bug already reported in previous session". Added explicit rules to ALL 5 testers: always create bugs, never skip because similar exists. Each test run is independent.

---

## [1.7.4] - 2026-02-05

### Fixed

- **SMOKE_TEST hangs after testers complete** - `wait` without arguments waits for ALL background processes including the dev server. Server runs indefinitely → deadlock. Now collects tester PIDs and waits only for them.

---

## [1.7.3] - 2026-02-05

### Fixed

- **YAML parsing breaks on inline comments** - `build_command: ""  # comment` was parsed as non-empty string, causing `bash: : command not found`. Added `parse_yaml_value()` function that strips comments, quotes, and whitespace. All 6 testing.yaml fields now parsed correctly.

- **Instruction template provoked inline comments** - Example in task description showed `build_command: npm run build  # or empty` which led executors to copy the style. Template now uses separate comment block above values.

---

## [1.7.2] - 2026-02-05

### Fixed

- **SMOKE_TEST crash kills HYPE** - `exit 1` in run-testers.sh killed entire hype.sh due to `set -e`. Now uses `return 0` after creating P0 task — system continues to IMPLEMENTATION phase as expected.

- **Server startup failure creates P0 task** - Previously, dev server failure just returned error without creating actionable task. Now creates P0 bug with server log for debugging.

---

## [1.7.1] - 2026-02-05

### Fixed

- **SMOKE_TEST skipped when P1+ bugs exist** - SMOKE_TEST now checks ALL open tasks, not just P0 bugs. Previously, if a tester created a P1 bug, the milestone was still created and system jumped to FINAL_REVIEW, skipping smoke tests after the fix.

### Changed

- **Centralized milestone management** - Extracted 4 idempotent functions to `common.sh`:
  - `has_milestone(label)` - check if milestone exists
  - `ensure_milestone(label, title)` - create if not exists
  - `delete_milestone(label)` - delete milestone task completely
  - `delete_all_milestones()` - delete all milestones (for INIT phase)

- **Unified milestone deletion** - All code now uses `bd delete` instead of mixed `bd delete` / `bd update --remove-label`. Cleaner, no orphaned tasks.

- **All milestone operations use --limit 0** - Ensures correct behavior with >50 closed tasks.

---

## [1.7.0] - 2026-02-05

### Added

- **Testing configuration file** (`.hype/testing.yaml`) - Separate config for testing, SPEC.md no longer modified by system:
  - Contains: type, build_command, start_command, test_url, health_check, startup_timeout
  - If missing for web/api projects → P0 task created for Opus to fill it
  - Library projects don't require testing config

- **Centralized server management** - run-testers.sh now:
  - Starts single dev server before all testers
  - Passes `SERVER_MANAGED=true` flag to testers
  - Testers use existing server instead of starting their own
  - Stops server after all testers complete
  - Eliminates port conflicts when running testers in parallel

### Changed

- **Versioning rules updated**:
  - PATCH (+0.0.1): bugfix, tweak, refactoring (user won't notice)
  - MINOR (+0.1.0): new user-visible functionality
  - MAJOR (X.0.0): only on explicit user request (never automatic)

- **Version on every change** - Architect now versions BEFORE creating P0 bugs, not only on success. Each set of changes = new version.

- **Testers respect SERVER_MANAGED flag** - tester-functional.md and tester-visual.md now check if server is already running before attempting to start their own

---

## [1.6.20] - 2026-02-05

### Fixed

- **Testers now kill stale servers and rebuild** - tester-functional.md now:
  - Kills any existing process on TEST_URL port before starting
  - Runs build command if specified in SPEC.md
  - Auto-reinstalls Python projects (`pip install -e .`) if no build command
  - Verifies server actually started before testing

- **run-testers.sh kills stale processes** - Before launching testers, kills any existing process on test port to ensure fresh server

---

## [1.6.19] - 2026-02-05

### Fixed

- **Critical: Milestones not detected with >50 tasks** - Added `--limit 0` to `bd list` calls in `detect-phase.sh`. Default limit of 50 caused milestones to be invisible when project had many closed tasks, resulting in incorrect phase detection (e.g., jumping back to HELPERS from FINAL_REVIEW).

### Added

- **Force phase mechanism** - `detect-phase.sh` now checks `.hype/force-phase` file first, allowing immediate transition to any phase. File is one-shot (deleted after read).

- **Flexible phase navigation** - `hype reset-phase` now supports ALL phases (INIT, PLANNING, HELPERS, PLAN_REVIEW, IMPLEMENTATION, SMOKE_TEST, FINAL_REVIEW) and can move forward or backward:
  - Moving forward: creates missing prerequisite milestones
  - Moving backward: removes milestones after target phase
  - Uses force-phase for immediate effect

- **ensure_milestone() helper** - New function in bin/hype to create milestones if they don't exist

### Changed

- `delete_milestone()` now uses `--limit 0` for reliable milestone detection

---

## [1.6.18] - 2026-02-04

### Changed

- **tester-functional now requires real UI interaction** - Complete rewrite of tester-functional.md:
  - MUST use Playwright for web projects (curl is not valid for UI testing)
  - Screenshots before/after every action as evidence
  - Reading source code is explicitly NOT valid evidence
  - Creates bugs for ANY issues found (P0 for Must Have failures, P1-P2 for other bugs)
  - Clear examples of what IS and what is NOT valid evidence

---

## [1.6.17] - 2026-02-04

### Fixed

- **Critical: Agents can now execute bash commands** - Changed `--permission-mode dontAsk` to `--permission-mode bypassPermissions` in `run_claude_with_progress()`. The `dontAsk` mode was incorrectly assumed to auto-approve tool calls, but it actually auto-DENIES them unless explicitly in project's allowed list. This caused testers and architects to report "I cannot execute bash commands" and mark tests as passed without actually running them.

---

## [1.6.16] - 2026-02-04

### Added

- **Dedicated Auditor agent** - New `core/agents/auditor.md` specialized for audit/verify tasks. Auditor analyzes code and writes findings to notes without creating branches or commits.

- **Audit task routing at executor level** - `run-executors.sh` now routes audit tasks directly to Auditor agent instead of Executor. Detection via `is_audit_task()` moved to `common.sh` for reuse.

### Changed

- `is_audit_task()` function moved from `run-senior-executor.sh` to `common.sh` (single source of truth)
- `run-executors.sh` main loop now checks task type and routes:
  - Audit tasks → `run_auditor()` (no worktree, sonnet model)
  - Code tasks → `run_executor()` (worktree isolation, configurable model)

### Flow

```
Task created → run-executors.sh:
  ├─ is_audit_task()? → Auditor → writes findings → needs-review → Architect
  └─ else → Executor → writes code → needs-review → Senior Executor
```

---

## [1.6.15] - 2026-02-04

### Added

- **Executor instructions for audit tasks** - Added "КРИТИЧНО: Audit/Verify задачи" section to executor.md. Executors now know to write findings to notes via `bd update --notes` instead of creating commits for audit tasks.

---

## [1.6.14] - 2026-02-04

### Added

- **Audit task routing to Architect** - Tasks with "Verify/Audit/Check/Validate" in title or "AUDIT SCOPE" in description are now routed to Architect instead of code review. Audit tasks don't produce commits - they produce findings in notes which Architect reviews and decides: close as passed, create fix tasks, or escalate critical issues.

### Changed

- `preflight_check()` now detects audit tasks via `is_audit_task()` function
- New preflight results: `NO_FINDINGS` (audit has empty notes), `AUDIT_REVIEW` (route to Architect)
- Added `route_audit_to_architect()` function in run-senior-executor.sh
- Added `MODE: audit_review` to architect.md with instructions for reviewing audit findings

---

## [1.6.13] - 2026-02-04

### Fixed

- **Executor forbidden from creating files in `.beads/`** - Added rule #8 to executor.md: executors must use `bd update` to modify tasks, not create files in `.beads/` directory.

---

## [1.6.12] - 2026-02-04

### Fixed

- **Scope check false positives on branch divergence** - When main branch had files that a task branch was created before (branch doesn't have those files), `git diff` showed them as "deleted" and triggered scope violations. Now uses `--diff-filter=ACMR` to only check Added/Copied/Modified/Renamed files.

---

## [1.6.11] - 2026-02-04

### Fixed

- **Scope check now matches basename** - Tasks defining short filenames like `session_row.html` in their `files:` field would fail scope validation against full paths like `src/chatfilter/templates/partials/session_row.html`. Added basename matching as fallback to existing exact/glob/prefix matching.

---

## [1.6.10] - 2026-02-04

### Fixed

- **Race condition in worktree slot allocation** - Multiple executors could get the same slot because `find_free_slot()` checked directory existence but worktree was created later in background subshell. Now uses `NEXT_SLOT` counter that increments immediately after each allocation.

- **Explicit tool availability in executor prompts** - Added "ДОСТУПНЫЕ ИНСТРУМЕНТЫ" section to executor.md and senior-executor.md to explicitly tell agents that bash/git/bd are available without asking permission.

---

## [1.6.9] - 2026-02-04

### Fixed

- **Tech Writer now reads SPEC.prev.md** - After new iteration starts, SPEC.md is archived to SPEC.prev.md. Tech Writer now checks for this file and uses it to understand previous iteration context, allowing user to request bug fixes or new features based on what was done before.

---

## [1.6.8] - 2026-02-04

### Fixed

- **Complete new iteration reset** - v1.6.7 only removed milestones but left old tasks and SPEC.md, causing system to go to PLANNING instead of INIT. Now properly:
  1. Removes all milestones
  2. Archives old tasks via `bd admin cleanup --force`
  3. Moves SPEC.md → SPEC.prev.md (preserves for reference)

  Result: detect-phase returns INIT, Tech Writer asks what to do next.

---

## [1.6.7] - 2026-02-04

### Added

- **Auto-start new iteration from DONE** - Running `hype start` when project is DONE now automatically starts a new iteration instead of exiting. System removes ALL milestones (project-done, smoke-test-done, plan-reviewed, analysts-done, planning-done) and continues to INIT phase where Tech Writer asks what to do next.

---

## [1.6.6] - 2026-02-04

### Fixed

- **Smoke test skipped after FINAL_REVIEW bug fix** - When Architect found a bug during FINAL_REVIEW and returned to IMPLEMENTATION, the `milestone:smoke-test-done` was not invalidated. After fixing the bug, the system skipped SMOKE_TEST and went directly to FINAL_REVIEW again. Now the milestone is properly removed when returning from FINAL_REVIEW, ensuring smoke tests re-run after fixes.

- **Claude CLI stream-json requires --verbose** - Added `--verbose` flag to `run_claude_with_progress` as required by updated Claude CLI when using `--print --output-format stream-json`.

- **Restore agent autonomy with --permission-mode dontAsk** - The `--print` mode blocks interactive permission approvals, breaking agent autonomy. Added `--permission-mode dontAsk` to auto-approve tool calls while keeping progress logging via stream-json.

---

## [1.6.4] - 2026-02-04

### Added

- **Real-time progress logging** - All agents now show tool calls as they happen:
  ```
  14:32:15 [EXEC 0] → Read
  14:32:16 [ANALYST ux] → Grep
  14:32:18 [ARCH] → Edit
  ```
- New `run_claude_with_progress` helper in common.sh for unified progress logging
- Uses `--output-format stream-json` for real-time streaming

### Changed

- All agent runners (executors, analysts, testers, architect) now use centralized progress function

---

## [1.6.3] - 2026-02-04

### Fixed

- Version bump only (no functional changes)

---

## [1.6.2] - 2026-02-04

### Added

- **Separate timeouts for each phase** - Each agent type now has its own configurable timeout:
  - `PLANNING_TIMEOUT` (15m) - Architect creates plan from SPEC.md
  - `ANALYST_TIMEOUT` (10m) - Each analyst agent
  - `PLAN_REVIEW_TIMEOUT` (10m) - Architect reviews analyst additions
  - `FINAL_REVIEW_TIMEOUT` (15m) - Architect final project review
  - `TASK_TIMEOUT` (10m) - Executor task execution
  - `REVIEW_TIMEOUT` (5m) - Senior executor code review
  - `TESTER_TIMEOUT` (10m) - Each tester agent

### Removed

- `USER_INPUT_TIMEOUT` - Tech Writer runs interactively without timeout (user is typing)

---

## [1.6.1] - 2026-02-04

### Added

- **Build step before SMOKE_TEST** - Runs `Build command` from SPEC.md before testers start, prevents testing stale compiled artifacts
- **FINAL_REVIEW retry** - Architect retries up to RETRY_LIMIT times on timeout instead of immediately creating blocker

### Fixed

- **jq error in run-testers.sh** - Fixed "Cannot index array with string" error when checking task status (`bd show` returns array)
- **Browser isolation warning** - Added critical warning in tester-visual to never use `browser_connect` (prevents hijacking user's browser session)

---

## [1.6.0] - 2026-02-04

### Added

- **SMOKE_TEST phase** - New mandatory phase between IMPLEMENTATION and FINAL_REVIEW that verifies the product actually works before delivery
- **5 parallel testers** (CodeX-Verify pattern):
  - `tester-functional` (sonnet) - Verifies each Must Have from SPEC.md (ALL projects)
  - `tester-visual` (opus) - UI verification via Playwright MCP with screenshots (web)
  - `tester-api` (haiku) - Endpoint testing, status codes, error handling (api, web)
  - `tester-cli` (haiku) - CLI command verification: --help, --version, main commands (cli)
  - `tester-regression` (sonnet) - Runs existing test suite (library)
- **Hard gate mechanism** - P0 bugs block `milestone:smoke-test-done`, system returns to IMPLEMENTATION
- **Evidence requirement** - All testers save proof to `.hype/evidence/` (screenshots, logs, reports)
- **Automatic tester selection** - Based on project type from SPEC.md Testing section
- **Playwright MCP fallback** - Visual tester skips gracefully if Playwright unavailable

### Changed

- Phase flow: `IMPLEMENTATION → SMOKE_TEST → FINAL_REVIEW → DONE`
- Config: Added `TESTER_TIMEOUT`, `SMOKE_TEST_TIMEOUT`, `MODEL_TESTERS`, `MODEL_TESTER_*`

### New files

- `core/agents/tester-functional.md`
- `core/agents/tester-visual.md`
- `core/agents/tester-api.md`
- `core/agents/tester-cli.md`
- `core/agents/tester-regression.md`
- `core/scripts/run-testers.sh`

---

## [1.5.10] - 2026-02-04

### Added

- **Final review report on completion** - When project completes, shows last 40 lines of architect's final review log.

---

## [1.5.9] - 2026-02-04

### Fixed

- **FINAL_REVIEW loops back to INIT** - After project completion, `detect-phase.sh` returned INIT instead of DONE when `milestone:project-done` existed. Now correctly returns DONE to finish the iteration.

---

## [1.5.8] - 2026-02-04

### Fixed

- **Empty executor/review logs** - Claude was running without `--print` flag, causing no output in pipe mode. Added `--print` for non-interactive operation.

---

## [1.5.7] - 2026-02-04

### Fixed

- **Tasks stuck with needs-review + executor** - Review didn't pick up tasks that had both labels. Now `get_review_tasks()` ignores `executor` label - if `needs-review` is set, task is ready for review.
- **Executor label cleanup** - Review now removes `executor` label on all outcomes (reject, approve, return for rework).

---

## [1.5.6] - 2026-02-03

### Fixed

- **Scope violation infinite loop** - Executor didn't receive retry context for scope violations. Now `build_retry_context()` checks all failure labels (`retry:N`, `scope-violation:N`, `review-retry:N`).
- **Scope violation escalation** - After 3 scope violations, task escalates to opus model (like review failures).
- **Clear failure type in context** - Retry context now shows specific issue type: "SCOPE VIOLATION (N times)" or "review rejection (N times)".

---

## [1.5.5] - 2026-02-03

### Fixed

- **Stale reviews loop** - When reviewer completed but took no action, task retries review up to 3 times. After 3 failures, escalates to opus model.

---

## [1.5.4] - 2026-02-03

### Fixed

- **Scope check regex broken** - Files list parsing failed completely (`grep [^\n]` doesn't work in shell, `sed` without `-E` ignores regex). Now uses simple `grep -m1 "^files:"` approach.

---

## [1.5.3] - 2026-02-03

### Fixed

- **Worktree slot collisions** - Slots now assigned by scanning existing worktree directories for first free slot, preventing overwrites when tasks are reset.

---

## [1.5.2] - 2026-02-03

### Fixed

- **Scope check false positives** - File patterns with annotations like `(new)`, `(edit)` now match correctly. Previously `files: docs/STATUS.md (new)` would reject changes to `docs/STATUS.md`.
- **Directory patterns in scope check** - Patterns like `templates/` now match `templates/index.html` and subdirectories.

---

## [1.5.1] - 2026-02-03

### Fixed

- **hype upgrade now adds new config variables** - Previously upgrade skipped config.sh if user had customizations, losing new variables like REVIEW_TIMEOUT. Now `merge_config()` adds missing variables while preserving user values.

---

## [1.5.0] - 2026-02-03

### Added

- **Optimized code review** - 5-10x faster reviews with pre-flight checks and context injection:
  - Pre-flight checks in bash: reject NO_BRANCH, NO_COMMITS, SECRETS_DETECTED, SCOPE_VIOLATION instantly (no Claude needed)
  - Context injection: diff, commits, task notes, executor logs passed directly in prompt (no git commands in Claude)
  - Executor logs included for reviewer context (last 50 lines)

- **Tiered review models** - Review model matches task complexity:
  - `model:opus` tasks → Opus review (quality gate for complex work)
  - All other tasks → Sonnet review (3-5x faster)

- **New REVIEW_TIMEOUT setting** - Separate timeout for optimized reviews:
  - `REVIEW_TIMEOUT="5m"` (default, shorter than TASK_TIMEOUT)
  - Reviews now complete in 1-2 minutes instead of 10

### Fixed

- **P0: Tasks with needs-review lost on stale reset** - When review queue was blocked (e.g., 10min timeout), completed tasks were incorrectly reset to open status and re-executed instead of being reviewed.
  - `reset_stale_tasks()` now skips tasks with `needs-review` label
  - Tasks waiting for review are queued, not stale

### Changed

- senior-executor.md: simplified from 249 to 95 lines (context provided, no git/bd commands needed)
- run-senior-executor.sh: complete rewrite with pre-flight checks and context building
- config.template.sh: MODEL_SENIOR_EXECUTOR removed (tiered review replaces it)

---

## [1.4.2] - 2026-02-03

### Added

- **Per-role model configuration** - New settings in `.hype/config.sh`:
  - `MODEL_TECH_WRITER="opus"` — model for requirements gathering
  - `MODEL_ARCHITECT="opus"` — model for planning and review
  - `MODEL_ANALYSTS="sonnet"` — model for parallel analysis
  - `MODEL_SENIOR_EXECUTOR="opus"` — model for code review
  - `MODEL_MANAGER="sonnet"` — model for problem resolution
  - `MODEL_ANALYZER="opus"` — model for deep project analysis
- All role models respect `ALLOWED_MODELS` restriction via `map_model()`

### Changed

- hype.sh: Tech Writer, Architect, Manager now use configurable models
- run-analysts.sh: uses `MODEL_ANALYSTS` setting
- run-senior-executor.sh: uses `MODEL_SENIOR_EXECUTOR` setting
- deep-analyze.sh: uses `MODEL_ANALYZER` setting, added config loading

---

## [1.4.1] - 2026-02-03

### Added

- **Configurable model restrictions** - New `ALLOWED_MODELS` setting in `.hype/config.sh`:
  - `"opus,sonnet,haiku"` — all models (default)
  - `"opus,sonnet"` — haiku tasks run on sonnet
  - `"sonnet,haiku"` — opus tasks run on sonnet
  - `"opus"` / `"sonnet"` / `"haiku"` — single model for all tasks
- `map_model()` function in common.sh maps requested model to nearest allowed

---

## [1.4.0] - 2026-02-03

### Added

- **Retry Context Injection** - Executor now receives structured context about previous failed attempts:
  - `build_retry_context()` in common.sh builds context from task notes and retry labels
  - `save_attempt_result()` saves structured results after each attempt
  - Executor prompt includes recommendations based on failure type (timeout, scope, tests)

- **Hard Scope Enforcement** - Two-level protection against scope creep:
  - Executor self-check: verifies changed files against `files:` in task description before commit
  - Senior Executor: deletes remote branch on scope violation (next retry starts clean)

- **Work Validation Before Close** - Prevents closing tasks without real work:
  - Senior Executor checks branch has commits before review
  - Validates main actually changed after merge

### Changed

- executor.md: added Retry Context section and scope check before commit
- senior-executor.md: added work validation, scope check with branch cleanup, post-merge validation
- run-executors.sh: integrates retry context into executor prompts

---

## [1.3.16] - 2026-02-03

### Fixed

- **hype upgrade now updates .beads/.gitignore** - Added `update_beads_gitignore()` function that adds `export-state/` to existing projects during upgrade.

---

## [1.3.15] - 2026-02-03

### Fixed

- **PROJECT_ROOT unbound variable** - hype.sh used undefined `$PROJECT_ROOT` instead of `$PROJECT_DIR` in 4 places (lines 383, 664, 666, 667). Caused "unbound variable" error after FINAL_REVIEW passed.

### Added

- **Testing section in SPEC.md** - Tech Writer now collects testing info:
  - Type: web | api | cli | library
  - Start command: how to run the project
  - Test URL: for web/api projects
- **Mandatory browser testing for web projects** - Architect final_review now requires browser check for `Type: web`. No curl fallback allowed.
- **export-state/ to .beads/.gitignore** - Prevents beads daemon state files from appearing in git status.

---

## [1.3.14] - 2026-02-02

### Fixed

- **Progress calculation was inverted** - `bd list` returns only open tasks, so total was wrong. Now correctly counts open+closed.

### Changed

- **Progress bar** - Visual progress indicator:
  - `[████████████░░░░░░░░] 12/20 (60%)`

---

## [1.3.13] - 2026-02-02

### Added

- **Active work monitoring** - Each cycle shows which agents are actively working:
  - `Active: WORK:task-123(15KB,active) CHECK:task-456(8KB,active) ANALYZE:ux(3KB,stale 90s)`
  - Monitors log file growth to detect stale/hung processes
  - Covers all agents: executors, senior, analysts, architect, tech-writer, manager

---

## [1.3.12] - 2026-02-02

### Fixed

- **Prevent infinite FINAL_REVIEW loop** - If architect times out or crashes without creating tasks or saying PASSED, creates a blocker task to prevent infinite loop.

---

## [1.3.11] - 2026-02-02

### Fixed

- **Remove ALL milestones when starting new iteration** - Previously only `project-done` was removed in INIT phase. Other milestones (`planning-done`, `analysts-done`, `plan-reviewed`) remained and confused detect-phase in new iteration.

---

## [1.3.10] - 2026-02-02

### Fixed

- **detect-phase returns PLANNING when all tasks closed** - `bd list` (without --status) returns only open+in_progress tasks. When all tasks are closed, TOTAL=0, causing incorrect PLANNING phase instead of FINAL_REVIEW.

---

## [1.3.9] - 2026-02-02

### Fixed

- **Auto-reopen tasks closed without merge** - Senior-executor sometimes calls `bd close` when intending to reject (writes "REJECTED" in notes but calls wrong command). Now detects this by checking if main SHA changed after Claude runs. If task is closed but main unchanged = no merge happened = auto-reopen with note.

---

## [1.3.8] - 2026-02-02

### Added

- **Review result logging** - [HYPE CHECK] now shows:
  - `APPROVED: task-id (merged)` when task is closed
  - `RETURNED: task-id - reason` when task is sent back for rework
- **Progress indicator** - Each cycle now shows completion progress:
  - `--- Cycle N | Phase: X | Progress: 5/12 (41%) ---`
  - Counts tasks, bugs, features (excludes epics)

---

## [1.3.7] - 2026-02-02

### Changed

- **Renamed log prefixes for clarity**
  - `[RUN-ANALYSTS]` → `[HYPE ANALYZE]`
  - `[RUN-EXECUTORS]` → `[HYPE WORK]`
  - `[SENIOR-EXECUTOR]` → `[HYPE CHECK]`

---

## [1.3.6] - 2026-02-02

### Removed

- **Removed legacy orchestrator.lock checks** (unnecessary complexity)

---

## [1.3.4] - 2026-02-02

### Changed

- **Renamed ORCHESTRATOR → HYPE everywhere**
  - Main module renamed: `orchestrator.sh` → `hype.sh`
  - Logs now show `[HYPE]` instead of `[ORCHESTRATOR]`
  - Lock file: `orchestrator.lock` → `hype.lock`
  - All documentation, comments, and UI messages updated

### Affected files

- `core/scripts/orchestrator.sh` → `core/scripts/hype.sh` (renamed)
- `bin/hype` — updated references
- `core/agents/manager.md`, `executor.md` — updated comments
- `core/scripts/*.sh` — updated comments
- `docs/architecture.md`, `README.md`, `PROJECT.md` — updated docs
- `templates/*.md`, `templates/*.sh` — updated templates

---

## [1.3.3] - 2026-02-02

### Fixed

- **Visual separation now works in terminal (not just log file)**
  - Added `echo ""` to stdout in addition to log file
  - Cycles, executors, senior, analysts now visually separated

### Affected files

- `core/scripts/hype.sh` — empty line before each cycle
- `core/scripts/run-executors.sh` — empty line to terminal
- `core/scripts/run-senior-executor.sh` — empty line to terminal
- `core/scripts/run-analysts.sh` — empty line to terminal

---

## [1.3.2] - 2026-02-02

### Improved

- **Clean logs: suppress bd output in all scripts**
  - All `bd create/update/close/delete` commands now redirect to `/dev/null`
  - Removes "✓ Created/Updated/Closed" noise from terminal and logs
  - Affected: orchestrator.sh, run-executors.sh, run-senior-executor.sh, run-analysts.sh, close-completed-parents.sh

- **Streaming logs with ANSI stripping**
  - `tee` for real-time log output (can `tail -f` log files)
  - `strip_ansi` removes terminal garbage (cursor reports, OSC sequences)
  - `set -o pipefail` preserves exit codes through pipes

- **Visual separation between log blocks**
  - Empty line before each run-executors and run-analysts session
  - Easier to distinguish cycles visually

- **Improved run-executors logging**
  - Pre-check task status before launching subshell
  - Show task title and model in TASK_START log
  - Summary: "Started X executor(s), skipped Y"

### Affected files

- `core/scripts/orchestrator.sh` — suppress bd output (8 commands)
- `core/scripts/run-executors.sh` — streaming, visual separation, improved logging
- `core/scripts/run-senior-executor.sh` — streaming, suppress bd output
- `core/scripts/run-analysts.sh` — streaming, visual separation, suppress bd output
- `core/scripts/close-completed-parents.sh` — suppress bd output

---

## [1.3.1] - 2026-02-02

### Fixed

- **P0: Tech Writer loop after iteration completion**
  - Problem: beads empty + old SPEC.md → PLANNING instead of INIT
  - Solution: `.hype/needs-spec` marker file
    - Created by orchestrator after milestone:project-done
    - Cleaned up by orchestrator after INIT phase (not by LLM prompt)
  - detect-phase.sh: beads=0 + needs-spec → INIT, else → PLANNING

- **P0: Tech Writer infinite loop when milestone:project-done exists**
  - Problem: milestone persists → detect-phase always returns INIT
  - Solution: orchestrator deletes milestone after INIT phase completes

- **Risk mitigation: critical operations moved from LLM prompts to bash**
  - `rm .hype/needs-spec` — now in orchestrator.sh, not tech-writer.md
  - Principle: LLM instructions are suggestions, bash is deterministic

### Affected files

- `core/scripts/detect-phase.sh` — needs-spec marker check
- `core/scripts/orchestrator.sh` — creates/deletes needs-spec, deletes milestone
- `core/agents/tech-writer.md` — removed needs-spec deletion (moved to bash)

---

## [1.3.0] - 2026-02-02

### Added

- **New iteration flow after project completion**
  - Previously: system stuck in DONE state, no way to start new iteration
  - Now: `detect-phase.sh` routes to INIT when:
    - milestone:project-done exists (iteration completed)
    - beads is empty but SPEC.md exists (after cleanup)
  - Tech Writer asks what to do next: fix bugs, add features, or something else

- **Tech Writer analyzes code during dialogue** (step 3)
  - When user mentions specific problem or feature — looks in code
  - Uses `grep -r` to find relevant code patterns
  - Avoids duplicating work: "This is already done in UserService.ts"
  - Provides context: "I see the form sends data to /api/login but has no error handling"

- **Tech Writer context-aware greetings**
  - Completed iteration (SPEC.md + CHANGELOG.md): summarizes what was done, asks what's next
  - Existing project (PROJECT_CONTEXT.md): recognizes stack, asks about changes
  - Draft exists: continues from where left off
  - Empty project: standard greeting

### Affected files

- `core/scripts/detect-phase.sh` — routes DONE/empty to INIT
- `core/agents/tech-writer.md` — code analysis step, context greetings, fixed step numbering

---

## [1.2.2] - 2026-02-02

### Improved

- **Functional testing now supports all project types**
  - 1.2.1 assumed all projects have UI (web apps)
  - Now detects project type: Web App, API, CLI, Library, Script
  - Applies appropriate verification method for each type:
    - Web App → dev server + browser/Playwright
    - API → server + curl endpoints
    - CLI → run with --help and test args
    - Library → run tests, check imports
    - Script → run with test data

### Affected files

- `core/agents/architect.md` — step 3 now handles non-UI projects

---

## [1.2.1] - 2026-02-02

### Fixed

- **P0: No functional testing before project delivery**
  - System marked project as DONE without verifying the product actually works
  - Closed tasks ≠ working product
  - Added mandatory step 3 "Функциональное тестирование" in architect.md final_review:
    - Start dev server
    - Use Playwright MCP to test UI (or curl fallback)
    - Verify each Must Have from SPEC.md works
    - Create bug task and return to IMPLEMENTATION if broken

### Affected files

- `core/agents/architect.md` — added step 3: functional testing in final_review

---

## [1.2.0] - 2026-02-02

### Fixed

- **P0: Infinite PLANNING loop after FINAL_REVIEW** (claudev-q38)
  - `bd admin cleanup --force` deleted milestone:project-done immediately after creation
  - Next cycle → no milestone → falls back to PLANNING → loop
  - Fix: `bd admin cleanup --older-than 1 --force` preserves tasks closed <1 day ago

- **P1: Architect ignored untracked files in FINAL_REVIEW** (claudev-vn9)
  - Untracked utility scripts left in working directory
  - Added step 3 in final_review: delete temp files, commit project files, or add to .gitignore

### Added

- **Real-time agent visibility** (claudev-hqg epic)
  - `strip_ansi()` function removes terminal garbage from logs
  - Streaming logs via `tee` — `tail -f logs/executor-xxx.log` now works
  - `hype status` shows active executors with duration and pending reviews:
    ```
    Active executors:
      beads-abc  "Add login form"     3m 42s  logs/executor-beads-abc.log

    Pending reviews:
      beads-xyz  "Update API"         waiting for senior
    ```

### Improved

- **run-executors logging** (claudev-al3)
  - Shows TASK_START with task title and model
  - Counts started vs skipped executors
  - Pre-checks status to reduce race condition confusion

- **Visual separation in logs** (claudev-w1y)
  - Empty lines between logical blocks in hype.log
  - Cleaner, more readable log output

### Affected files

- `core/scripts/orchestrator.sh` — cleanup --older-than 1
- `core/agents/architect.md` — step 3: handle untracked files
- `core/scripts/common.sh` — strip_ansi() function
- `core/scripts/run-executors.sh` — streaming + improved logging
- `core/scripts/run-senior-executor.sh` — streaming
- `core/scripts/run-analysts.sh` — streaming
- `bin/hype` — status shows active executors

---

## [1.1.3] - 2026-02-01

### Fixed

- **Executors failed immediately — worktree path corrupted by git output** (P0)
  - `git worktree add` outputs "HEAD is now at..." to stdout
  - This polluted `$worktree_path` variable → `cd` failed → executor crashed
  - Symptom: tasks stuck in `in_progress` with `executor` label, no work done
  - Fix: suppress stdout with `>/dev/null 2>&1`

- **Stale task reset returned garbage instead of count** (P1)
  - `bd update` outputs "✓ Updated issue..." to stdout
  - `reset_stale_tasks()` captured this garbage in `$reset_count`
  - Caused "integer expression expected" error in orchestrator
  - Fix: suppress stdout in bd update calls

### Affected files

- `core/scripts/run-executors.sh` — suppress git worktree stdout
- `core/scripts/common.sh` — suppress bd update stdout in reset_stale_tasks

---

## [1.1.2] - 2026-02-01

### Fixed

- **CRITICAL: SQLite lock contention — bd запросы занимали 2 минуты вместо мгновенных** (P0)
  - Коммит 85bf56b добавил `BEADS_NO_DAEMON=1` в run-executors.sh
  - Идея была "избежать daemon conflicts в worktrees"
  - Реальность: worktrees используют redirect file → та же .beads/ база
  - `BEADS_NO_DAEMON=1` = direct SQLite access минуя daemon
  - Daemon продолжает работать → делает import/export
  - Direct access + Daemon = SQLite lock война
  - Результат: `database is locked`, 2+ минуты на каждый bd запрос
  - Исправлено: убран `BEADS_NO_DAEMON=1` — все операции через daemon

### Added

- **Документация архитектуры Beads** в docs/architecture.md
  - Как работает daemon + SQLite
  - Правила работы с beads в high-concurrency сценариях
  - Типичные ошибки и их решения
  - Процедура восстановления после проблем

### Performance

- До исправления: 2:00.22 на `bd list --json`
- После исправления: 0.087s (87 миллисекунд)
- Ускорение: **1400x**

### Affected files

- `core/scripts/run-executors.sh` — убран BEADS_NO_DAEMON=1
- `docs/architecture.md` — добавлена секция "Архитектура Beads"

---

## [1.1.1] - 2026-02-01

### Fixed

- **Senior Executor получал пустой TASK_JSON** (P0)
  - `run-senior-executor.sh` передавал `TASK:` в контекст
  - `senior-executor.md` ожидал `$TASK_JSON` — переменная была undefined
  - Результат: `TASK_TITLE` всегда был "Unknown" → некорректные PR titles
  - Исправлено: senior-executor теперь сам вызывает `bd show $TASK_ID --json` (как executor)
  - Все ссылки `$TASK` заменены на `$TASK_ID` для консистентности

### Changed

- `senior-executor.md` теперь самодостаточен — не зависит от переданного JSON
- `run-senior-executor.sh` упрощён — передаёт только `TASK_ID` и `PROJECT_ROOT`
- Единый паттерн для executor и senior-executor: агент сам получает данные через `bd show`

---

## [1.1.0] - 2026-02-01

### Added

- **Git worktrees для изоляции executors**
  - Каждый executor работает в своём worktree (`.hype-worktrees/executor-{slot}`)
  - Избегает git HEAD conflicts между параллельными executors
  - Предотвращает beads import storms при переключении веток
  - Автоматическая очистка stale worktrees (>15 мин) через `cleanup_stale_worktrees()`

- **Batched queries в detect-phase.sh**
  - Сокращение с 11 bd вызовов до 2 за цикл
  - Кэширование JSON и фильтрация через jq
  - Уменьшает SQLite contention при параллельной работе

- **Общая функция `reset_stale_tasks()` в common.sh**
  - Переиспользуется в orchestrator.sh (shutdown + stale check)
  - Параметры: threshold и log prefix
  - Сохраняет review feedback через append_notes

### Changed

- `run_executor()` принимает slot для worktree изоляции
- executor.md: добавлен WORKTREE_PATH в контекст
- orchestrator.sh: добавлен шаг cleanup_stale_worktrees в main loop

### Result

- Возможность запускать 5-7 параллельных executors вместо 2
- Меньше bd запросов на цикл → меньше contention

---

## [1.0.0] - 2026-01-31

### Changed

- **Project renamed: claudev → hype**
  - CLI command: `claudev` → `hype`
  - Install directory: `~/.claudev` → `~/.hype`
  - Project config: `.claudev/` → `.hype/`
  - Log file: `logs/claudev.log` → `logs/hype.log`
  - Repository: to be renamed on GitHub

### Affected files

- `bin/hype` — renamed from `bin/claudev`
- `install.sh` — updated all paths and names
- `core/scripts/*` — updated HYPE_HOME and .hype paths
- `templates/*` — updated references
- `docs/*`, `README.md` — updated documentation

---

## [0.9.32] - 2026-01-31

### Fixed

- **Stale reset и timeout перезаписывали review feedback**
  - При timeout/stale reset notes полностью перезаписывались
  - Review feedback терялся → executor не знал причину возврата
  - Исправлено: notes теперь аппендятся через `append_notes()` helper
  - Старые notes сохраняются, новые добавляются с разделителем `---`

### Affected files

- `core/scripts/common.sh` — добавлена функция `append_notes()`
- `core/scripts/orchestrator.sh` — stale check аппендит notes
- `core/scripts/run-executors.sh` — timeout/error аппендит notes

---

## [0.9.31] - 2026-01-31

### Fixed

- **Executor игнорировал feedback от reviewer — бесконечный цикл return**
  - После review return executor удалял ветку и начинал с нуля
  - Не читал notes с причиной возврата
  - Повторял ту же ошибку → reviewer снова возвращал → цикл
  - Исправлено:
    - Executor проверяет notes на feedback (grep "review failed")
    - Если ветка существует на remote — продолжает работу, не пересоздаёт
    - Явные инструкции: читать причину, исправлять конкретную проблему

### Affected files

- `core/agents/executor.md` — обработка feedback от reviewer

---

## [0.9.30] - 2026-01-31

### Fixed

- **Race condition in executors** — задача исчезала между list и show
  - `get_review_tasks()` возвращал ID задачи
  - К моменту `bd show` задача уже закрыта/удалена другим процессом
  - Claude получал пустой JSON → "No messages returned" crash
  - Исправлено: валидация существования задачи перед вызовом Claude

- **needs-review label оставался после crash Claude**
  - Senior-executor делал merge, закрывал задачу, потом падал
  - Cleanup код не выполнялся из-за ненулевого exit code
  - Label `needs-review` оставался на закрытой задаче → повторные попытки ревью
  - Исправлено: cleanup labels выполняется всегда если задача уже closed

### Affected files

- `core/scripts/run-executors.sh` — race condition protection
- `core/scripts/run-senior-executor.sh` — race condition + label cleanup

---

## [0.9.29] - 2026-01-31

### Fixed

- **Executors игнорировали bug и feature задачи** (P0)
  - `get_ready_tasks()` фильтровал только `issue_type == "task"`
  - Bug и feature задачи отбрасывались — система брала только tasks
  - Результат: 3 ready задачи (P0 bug, P1 feature, P2 task) → запускалась только P2
  - Исправлено: добавлены типы `bug` и `feature` в фильтр

- **Задачи запускались не по приоритету**
  - P2 task запускалась раньше P0 bug
  - Добавлена сортировка по priority (P0 первым)

### Affected files

- `core/scripts/run-executors.sh` — расширен фильтр типов, добавлена сортировка

---

## [0.9.28] - 2026-01-31

### Changed

- **Баланс scope constraint для аналитиков и архитектора**
  - Раньше: "только если НАПРЯМУЮ в SPEC.md" — архитектор закрывал полезные quality gates
  - Теперь: различаем "новый функционал" (out-of-scope) и "качество исполнения" (in-scope)
  - Quality gates (loading states, validation, error handling) для заявленного функционала — оставляются
  - Новый функционал не из SPEC — закрывается

### Affected files

- `core/agents/architect.md` — уточнены критерии plan_review
- `core/agents/analyst-ux.md` — quality gates = in-scope
- `core/agents/analyst-security.md` — security gates = in-scope
- `core/agents/analyst-ops.md` — ops gates = in-scope
- `core/agents/analyst-reliability.md` — reliability gates = in-scope
- `core/agents/analyst-architecture.md` — architecture gates = in-scope

---

## [0.9.27] - 2026-01-31

### Fixed

- **Мусорные escape sequences в выводе логов**
  - `^[]11;rgb:...` и `^[[25;1R` появлялись перед каждой строкой
  - Причина: beads CLI запрашивал цвет терминала для определения темы
  - Добавлен `NO_COLOR=1` в common.sh для подавления запросов

### Added

- **Цветной вывод логов**
  - INFO/SUCCESS — зелёный
  - WARN — жёлтый
  - ERROR/FATAL — красный
  - TASK_START — голубой
  - Timestamp — серый

### Affected files

- `core/scripts/common.sh` — добавлен `export NO_COLOR=1`
- `core/scripts/log.sh` — цветной вывод в централизованной функции
- `core/scripts/run-analysts.sh` — цветной вывод
- `core/scripts/run-executors.sh` — цветной вывод
- `core/scripts/run-senior-executor.sh` — цветной вывод
- `core/scripts/orchestrator.sh` — цветной вывод

---

## [0.9.26] - 2026-01-31

### Fixed

- **CRITICAL: Бесконечный цикл HELPERS — система застревала запуская аналитиков снова и снова**
  - Опечатка в bd create: `--label=` вместо `--labels=`
  - Milestones создавались БЕЗ меток → detect-phase.sh не находил их
  - Система не переходила из HELPERS в IMPLEMENTATION
  - За 2 часа: 9 задач → 364 задачи (аналитики запускались ~720 раз)
  - Исправлено: `--label=` → `--labels=` в 3 местах

### Affected files

- `core/scripts/orchestrator.sh` — исправлен синтаксис bd create для milestones

---

## [0.9.25] - 2026-01-31

### Fixed

- **`hype stop` не останавливал executor'ы**
  - Stop убивал только orchestrator, executor'ы продолжали работать в фоне
  - Создавали ветки, обновляли задачи даже после stop
  - Теперь `pkill -9 -f "claude --model"` убивает все процессы

### Affected files

- `bin/hype` — cmd_stop() теперь убивает все claude процессы

---

## [0.9.24] - 2026-01-31

### Fixed

- **Exit code неправильно захватывался после `if !`**
  - `$?` после `if !` не сохраняет оригинальный exit code
  - Успешные executor'ы (exit 0) логировались как ERROR
  - Исправлено: exit code захватывается сразу после команды

- **Дубликаты задач из bd ready**
  - bd ready мог возвращать одну задачу несколько раз
  - Одна задача запускалась несколькими executor'ами
  - Добавлен `sort -u` для дедупликации

### Affected files

- `core/scripts/run-executors.sh` — exit code capture + deduplication

---

## [0.9.23] - 2026-01-31

### Fixed

- **Executor не обновлял labels после завершения**
  - Скрипт логировал "completed" но не убирал `executor` label
  - Задачи застревали: queue full, но процессы уже завершились
  - Добавлен fallback: скрипт гарантирует обновление labels после успеха

### Affected files

- `core/scripts/run-executors.sh` — fallback label update после завершения

---

## [0.9.22] - 2026-01-31

### Fixed

- **Race condition between executor and senior**
  - Senior мог взять задачу которую executor только что claim'нул
  - Происходило когда задача имела `needs-review` от предыдущего прогона (retry после timeout)
  - Senior теперь исключает задачи с `executor` label
  - Executor убирает `needs-review` при claim

### Affected files

- `core/scripts/run-senior-executor.sh` — фильтр исключает executor label
- `core/scripts/run-executors.sh` — claim убирает needs-review

---

## [0.9.21] - 2026-01-31

### Added

- **`hype stop` command**
  - Graceful shutdown orchestrator (SIGTERM → wait 5s → SIGKILL)
  - Detached executors continue running until completion
  - Safe for updates: `hype stop && claudev update && claudev start`

### Affected files

- `bin/hype` — added cmd_stop()

---

## [0.9.20] - 2026-01-31

### Changed

- **Streaming executor architecture**
  - Senior executor больше не ждёт завершения ВСЕХ executors
  - Подхватывает готовые задачи сразу, пока другие ещё работают
  - `run-executors.sh`: убран блокирующий `wait`, добавлен `disown -a`
  - `run-senior-executor.sh`: обрабатывает одну задачу за вызов

### Affected files

- `core/scripts/run-executors.sh` — non-blocking launch
- `core/scripts/run-senior-executor.sh` — one task per call
- `core/scripts/orchestrator.sh` — updated log message

---

## [0.9.19] - 2026-01-31

### Fixed

- **Executors не находили задачи из-за неправильного имени поля**
  - jq-фильтр использовал `.type` вместо `.issue_type`
  - Результат: "No ready tasks for executors" даже когда задачи есть
  - Затронуто: run-executors.sh, analyst-architecture.md

### Affected files

- `core/scripts/run-executors.sh` — исправлен фильтр get_ready_tasks()
- `core/agents/analyst-architecture.md` — исправлен фильтр проверки model label

---

## [0.9.18] - 2026-01-31

### Fixed

- **Architect: cycle detection в промпте использовал устаревшую логику**
  - `grep -q "cycle"` давал false positive (слово "cycle" есть в "No dependency cycles detected")
  - Исправлено: теперь `grep -q "→"` — проверяем реальный индикатор цикла

- **Beads daemon auto-restart**
  - Раньше: если daemon падал — orchestrator выходил с ошибкой
  - Теперь: автоматическая попытка рестарта перед fatal exit

### Affected files

- `core/agents/architect.md` — исправлена проверка циклов
- `core/scripts/orchestrator.sh` — auto-restart в check_beads()

---

## [0.9.17] - 2026-01-31

### Added

- **`hype wipe` command** — полная очистка проекта
  - Закрывает все beads задачи
  - Выполняет `bd admin cleanup --force` (удаляет `.beads/`)
  - Выполняет `bd doctor --fix`
  - Удаляет все файлы claudev включая SPEC.md, .mcp.json
  - Очищает записи из .gitignore
  - Результат: остаётся только исходный код и .git/

- **`hype reset-phase` command** — перезапуск фазы
  - `reset-phase PLANNING` — сбросить до планирования
  - `reset-phase HELPERS` — перезапустить аналитиков
  - `reset-phase PLAN_REVIEW` — Architect заново проверит план аналитиков

- **Auto-cleanup after successful iteration** — автоматическая очистка
  - После `FINAL_REVIEW: PASSED` запускается `bd admin cleanup --force` и `bd doctor --fix`
  - Очищает закрытые задачи и исправляет возможные проблемы

### Affected files

- `bin/hype` — новые команды wipe, reset-phase
- `core/scripts/orchestrator.sh` — auto-cleanup в check_and_create_done_milestone()

---

## [0.9.16] - 2026-01-30

### Fixed

- **False positive BLOCKED_CYCLES detection** (P0)
  - `detect-phase.sh` использовал `grep -qi "cycle"` для проверки циклов
  - Вывод "✓ No dependency cycles detected" содержит слово "cycle"
  - Результат: BLOCKED_CYCLES даже когда циклов нет
  - Исправлено: проверяем наличие "→" (стрелки) в выводе — это реальный индикатор цикла

### Affected files

- `core/scripts/detect-phase.sh` — исправлена логика определения циклов

---

## [0.9.15] - 2026-01-30

### Fixed

- **BLOCKED_CYCLES infinite loop — architect not running** (P0)
  - В фазе BLOCKED_CYCLES создавалась P0 задача "Fix dependency cycles"
  - Но Architect НЕ запускался для её выполнения
  - Результат: бесконечный цикл (18+ итераций без выхода)
  - Исправлено:
    - Добавлен `MODE: fix_cycles` в architect.md
    - orchestrator.sh теперь вызывает `run_agent_with_mode "architect" ... "fix_cycles"`
    - Добавлен счётчик последовательных BLOCKED_CYCLES (3 попытки → FATAL exit)
    - Счётчик сбрасывается при успешном переходе в другую фазу

### Affected files

- `core/scripts/orchestrator.sh` — BLOCKED_CYCLES запускает architect + escalation counter
- `core/agents/architect.md` — добавлен MODE: fix_cycles

---

## [0.9.14] - 2026-01-30

### Fixed

- **BLOCKED_CYCLES infinite loop in orchestrator** (P0)
  - `detect_phase()` вызывала `log()` который выводил в stdout через `tee`
  - Весь этот вывод попадал в переменную `$phase` вместе с timestamp
  - Результат: `$phase = "2026-01-30 18:33:02 [ORCHESTRATOR] DEBUG: ... BLOCKED_CYCLES"` вместо просто `"BLOCKED_CYCLES"`
  - Исправлено: debug output теперь пишется напрямую в лог-файл, минуя stdout

- **Analysts creating irrelevant tasks (scope creep)** (P0)
  - Аналитики не получали SPEC.md и не знали scope проекта
  - Генерировали задачи про HTTPS, аутентификацию и другое что не было в SPEC
  - Исправлено:
    - `run-analysts.sh` теперь передаёт SPEC.md в контекст каждого аналитика
    - Все 5 промптов аналитиков получили правило #0 SCOPE CONSTRAINT
    - Architect в `plan_review` теперь удаляет out-of-scope задачи (шаг 3)

### Affected files

- `core/scripts/orchestrator.sh` — detect_phase() пишет в файл, не в stdout
- `core/scripts/run-analysts.sh` — добавлена передача SPEC.md в контекст
- `core/agents/analyst-*.md` (5 файлов) — правило #0 SCOPE CONSTRAINT
- `core/agents/architect.md` — шаг 3 в plan_review для удаления out-of-scope задач

---

## [0.9.13] - 2026-01-30

### Fixed

- **macOS: timeout command not found in helper scripts** (P0)
  - `run-analysts.sh`, `run-executors.sh`, `run-senior-executor.sh`, `deep-analyze.sh` использовали `timeout` напрямую
  - macOS не имеет GNU `timeout` по умолчанию
  - Создан общий `common.sh` с функцией `timeout_cmd()` (fallback: gtimeout > timeout > perl)
  - Все скрипты теперь используют `timeout_cmd` через source common.sh
  - Устранено дублирование кода (timeout_cmd была только в orchestrator.sh)

- **SPEC.md и SPEC.draft.md не добавлялись в .gitignore** (P1)
  - Tech Writer создаёт эти файлы, но они не игнорировались
  - Добавлены SPEC.md и SPEC.draft.md в шаблон .gitignore
  - Обновлена функция update_gitignore() для upgrade

- **Agent prompts with YAML frontmatter fail in helper scripts** (P0)
  - Промпты с `---` (frontmatter) парсились как CLI опция
  - Исправлено в orchestrator.sh (v0.9.12), но не в helper скриптах
  - Теперь run-analysts.sh, run-executors.sh, run-senior-executor.sh передают промпты через stdin

- **`hype update` fails after force-push** (P1)
  - `git pull --ff-only` падал когда история разошлась
  - Теперь автоматически делает `git reset --hard origin/main` при diverged history

### Affected files

- `core/scripts/common.sh` — NEW: общие функции для всех скриптов
- `core/scripts/run-analysts.sh` — source common.sh, timeout → timeout_cmd
- `core/scripts/run-executors.sh` — source common.sh, timeout → timeout_cmd
- `core/scripts/run-senior-executor.sh` — source common.sh, timeout → timeout_cmd
- `core/scripts/deep-analyze.sh` — source common.sh, timeout → timeout_cmd
- `core/scripts/orchestrator.sh` — source common.sh, удалена локальная timeout_cmd
- `bin/hype` — добавлены SPEC.md, SPEC.draft.md в .gitignore шаблон

---

## [0.9.12] - 2026-01-30

### Fixed

- **macOS compatibility: timeout command not found** (P0)
  - macOS не имеет GNU `timeout` по умолчанию
  - Добавлена функция `timeout_cmd()` с fallback: gtimeout (coreutils) > timeout (Linux) > perl
  - Работает из коробки без установки дополнительных пакетов

- **Agent prompts starting with "---" parsed as CLI option** (P0)
  - YAML frontmatter в agent файлах интерпретировался как опция командной строки
  - Исправлено: промпты передаются через stdin вместо `-p` аргумента

- **Planning phase stuck in loop** (P0)
  - Architect создавал план, но не создавал milestone:planning-done
  - Добавлено автоматическое создание milestone если architect пропустил шаг 7

- **Milestones not detected by detect-phase.sh** (P1)
  - `has_label()` проверяла только open задачи, а milestones закрываются сразу
  - Исправлено: теперь проверяет `--status=closed`

### Affected files

- `core/scripts/orchestrator.sh` — timeout_cmd, stdin prompts, auto-milestone
- `core/scripts/detect-phase.sh` — has_label для closed tasks

---

## [0.9.8] - 2026-01-30

### Fixed

- **Tech Writer молчит при запуске** (P0 UX)
  - Claude Code CLI ждёт первый user message даже с `--system-prompt`
  - Добавлен trigger "Начни" как начальное сообщение
  - Теперь Tech Writer сразу начинает диалог

### Affected files

- `core/scripts/orchestrator.sh` — добавлен trigger в `run_interactive_agent()`

---

## [0.9.7] - 2026-01-30

### Added

- **Auto-commit .gitignore при init** (P2 UX)
  - После обновления .gitignore автоматически коммитится
  - Пользователю не нужно делать это вручную

### Affected files

- `bin/hype` — добавлен auto-commit в `cmd_init()`

---

## [0.9.6] - 2026-01-30

### Fixed

- **Неполный .gitignore при init** (P1)
  - Симлинки и служебные папки не игнорировались
  - Добавлены: `.hype/`, `.claude/agents`, `.claude/commands`, `scripts`, `project-scripts/`
  - Исправлено для init и upgrade

### Affected files

- `bin/hype` — обновлён .gitignore template и `update_gitignore()`

---

## [0.9.5] - 2026-01-30

### Fixed

- **Tech Writer не начинал диалог первым** (P1 UX)
  - При запуске Claude показывал пустой промпт "Try edit..."
  - Пользователь не понимал что делать
  - Добавлена секция "ПЕРВОЕ ДЕЙСТВИЕ" — агент теперь сам начинает с приветствия
  - Приветствие адаптируется к контексту (существующий проект / draft / пустой)

- **Tech Writer не говорил как завершить сессию** (P1 UX)
  - После создания SPEC.md пользователь не знал что делать
  - Оркестратор ждёт завершения Claude, Claude ждёт ввода — deadlock
  - Теперь агент явно говорит: "Введите `/exit` чтобы запустить следующую фазу"

### Affected files

- `core/agents/tech-writer.md` — секция "ПЕРВОЕ ДЕЙСТВИЕ", инструкции про `/exit`

---

## [0.9.4] - 2026-01-30

### Fixed

- **Critical: `hype init` breaks on projects with existing `scripts/` folder** (P0)
  - Previous behavior: created symlink INSIDE the folder (`scripts/scripts → ...`)
  - New behavior: renames existing folder to `project-scripts/`, then creates proper symlink
  - Same fix applied to `.claude/agents` and `.claude/commands`

- **Orchestrator shows unhelpful "Unknown phase: UNKNOWN"** (P1)
  - Previous behavior: stderr from `detect-phase.sh` was discarded (`2>/dev/null`)
  - New behavior: stderr is captured and logged at DEBUG level
  - Added check for script existence before calling

### Added

- **Symlink health check at startup** (P2)
  - Orchestrator now validates all symlinks before starting main loop
  - Clear error messages if `scripts/` or `.claude/agents` are broken
  - Quick-fix command shown in error output

- **Debug mode for troubleshooting** (P3)
  - New config option: `DEBUG=true` in `.hype/config.sh`
  - When enabled, `detect-phase.sh` outputs all variable values
  - Helps diagnose phase detection issues

### Affected files

- `bin/hype` — improved symlink handling in `cmd_init()`
- `core/scripts/orchestrator.sh` — health check, stderr logging
- `core/scripts/detect-phase.sh` — debug output
- `templates/config.template.sh` — new DEBUG option

---

## [0.9.3] - 2026-01-30

### Fixed

- **Auto-fix permissions after sudo install**
  - If `~/.hype` is owned by root (from previous `sudo bash install.sh`), installer now automatically fixes ownership
  - Asks for sudo password only when needed, with clear explanation
  - Prevents "Permission denied" errors on subsequent updates

### Notes

Running `curl ... | sudo bash` creates files owned by root, breaking future non-sudo updates. This fix detects the problem and corrects it automatically.

---

## [0.9.2] - 2026-01-30

### Added

- **Anti-overengineering guidelines** for Opus agents (architect, senior-executor)
  - Rule: создавай только задачи, напрямую требуемые для цели
  - Senior executor возвращает код с лишними абстракциями на доработку

- **Anti-hedging guidelines** for Sonnet agents (manager, all 5 analysts)
  - Rule: избегай hedging-слов (might, could, possibly)
  - Принимай решение и действуй, не "возможно стоит"

- **Verification-before-completion** for executor
  - Новая секция 7.5 "Верификация (ОБЯЗАТЕЛЬНО)"
  - Запуск тестов перед ready-for-review
  - Проверка Playwright/browser tools если доступны
  - Ручная верификация если тестов нет

### Notes

Based on Anthropic best practices for Claude 4:
- Opus склонен к over-engineering (лишние абстракции, helpers "на будущее")
- Sonnet hedging в ~34% случаев (research data)
- Common failure mode: marking tasks complete without verification

---

## [0.9.1] - 2026-01-29

### Fixed

- **Critical: beads CLI compatibility** (P0)
  - All agents: `--format=json` → `--json` (beads uses global `--json` flag, not `--format`)
  - All agents and scripts: `bd show --json | jq '.field'` → `jq '.[0].field'` (bd show returns array, not object)

- **Affected files:**
  - `core/agents/*.md` — all 11 agent prompts
  - `core/scripts/orchestrator.sh` — stale task detection
  - `core/scripts/run-executors.sh` — task claiming and retry handling
  - `core/scripts/run-senior-executor.sh` — review processing

### Notes

Without this fix, agents would receive empty results from `bd list --format=json` and errors from `bd show --format=json`, causing all task management to fail silently.

---

## [0.9.0] - 2026-01-29

### Milestone: Project Upgrade Mechanism

Механизм обновления проектов, уже инициализированных через claudev.

### Added

- **Version tracking**: Сохранение версии claudev в `.hype/version` при `init`
  - Позволяет определить нужно ли обновление проекта

- **`hype upgrade` command**: Обновление текущего проекта до последней версии
  - Обновление symlinks (.claude/agents, .claude/commands, scripts/)
  - Merge стратегия для config.sh (сохраняет пользовательские изменения)
  - Автоматическое добавление новых записей в .gitignore
  - Поддержка migration scripts для версионных изменений

- **`hype upgrade --all`**: Обновление всех известных проектов
  - Автоматический поиск в ~/Projects, ~/Code, ~/Dev, ~/Zen/Code, ~/work
  - Поиск до 3 уровней вложенности
  - `--force` флаг для принудительного обновления

- **Migration scripts infrastructure**: Директория `migrations/` для версионных миграций
  - Формат: `{from}-to-{to}.sh` (например `0.8.0-to-0.9.0.sh`)
  - Автоматический запуск при upgrade

### Fixed

- **Fully automatic install.sh**: Установка без ручных шагов
  - `retry()` функция с exponential backoff (3 попытки)
  - Проверка сети перед началом установки
  - Fallback методы для Claude Code (npm, альтернативные DNS)
  - Graceful handling всех сетевых ошибок

---

## [0.8.3] - 2026-01-29

### Added
- **Fish shell support**: PATH configuration now works with fish (`~/.config/fish/config.fish`)
  - Uses `fish_add_path` for proper fish syntax

---

## [0.8.2] - 2026-01-29

### Fixed
- **Shell detection**: PATH now added to ALL existing shell configs (.zshrc, .bashrc, .bash_profile)
  - Previous logic tried to detect shell via `$SHELL` variable, but `sudo bash` loses this
  - Now: if config file exists, add PATH to it (no guessing)

---

## [0.8.1] - 2026-01-29

### Fixed
- **PATH configuration**: Added `~/.local/bin` to PATH (Claude Code installation directory)
  - Previously only `~/.hype/bin` was added, causing "Claude Code NOT INSTALLED" verification failure

### Improved
- **Claude Code installation**: Graceful error handling if network fails
  - Shows manual installation link instead of blocking
  - Verification treats Claude Code as optional (warn instead of error)

---

## [0.8.0] - 2026-01-28

### Milestone: Ready for Production

Полный архитектурный аудит пройден. MCP интеграция добавлена. Система готова к первым реальным запускам.

### Added
- **MCP Integration** (claudev-5xm): Автоматическая настройка MCP серверов при `hype init`
  - **Playwright**: Автоматически (browser automation, тестирование)
  - **GitHub**: Автоматически если `gh auth` настроен (токен НЕ хранится в файле — динамически через `gh auth token`)
  - **PostgreSQL**: Шаблон с placeholder (требует DATABASE_URL)
  - **Supabase**: Шаблон с placeholder (требует SUPABASE_ACCESS_TOKEN)
- `.mcp.json` добавлен в `.gitignore` (security: токены не попадут в git)

### Verified
- **Синтаксис**: Все 10 bash скриптов прошли `bash -n` проверку
- **Beads CLI**: Все используемые команды существуют (`bd children`, `bd dep cycles`, `bd epic close-eligible`)
- **Execution paths**: Все пути от `hype init` до `DONE` фазы проверены
- **Failure modes**: Lock files, stale task reset, draft TTL, WIP commits — всё работает
- **Data flow**: Beads = источник правды для задач, Git = для кода

### Architecture
- 11 агентов: Tech Writer, Manager, Architect, Executor, Senior Executor, Analyzer, 5 Analysts
- 10 скриптов в core/scripts/
- 7 фаз: INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → FINAL_REVIEW → DONE
- Crash recovery: автоматический сброс stale tasks, graceful shutdown

### P0 Critical Issues: 0
### P1 Important Issues: 0

---

## [0.7.3] - 2026-01-28

**Epic:** claudev-h9q — CLOSED

### Added
- **claudev-260**: Auto-start beads daemon в `hype init`
  - Проверка `bd daemon status`, автозапуск если не работает
  - Пользователю не нужно вручную запускать daemon
- **claudev-0ss**: GitHub onboarding flow в `hype init`
  - Проверка `gh auth status`
  - Помощь с авторизацией (`gh auth login`)
  - Предложение создать repo (`gh repo create`) если нет remote
  - Graceful fallback на локальную работу без GitHub
- **claudev-06l**: Auto-setup gitleaks при наличии GitHub
  - Автоматическая установка gitleaks (brew/snap/go) если есть GitHub remote
  - Автоматическая настройка pre-commit hook
  - Локальные проекты без GitHub — пропускаем молча

---

## [0.7.2] - 2026-01-28

### Added
- **orchestrator.sh**: `check_stale_tasks()` — автоматический сброс зависших задач в рабочем цикле
  - Задачи `in_progress` без обновления >10 минут сбрасываются в `open`
  - Раньше stale tasks сбрасывались только при shutdown orchestrator
  - Теперь система самовосстанавливается если executor упал без timeout (kill -9, OOM)

### Verified
- **Архитектурный аудит пройден**: все скрипты, агенты, execution paths проверены
- Синтаксис bash: OK (10 скриптов)
- Beads CLI совместимость: OK (все команды существуют)
- Система готова к первым запускам

---

## [0.7.1] - 2026-01-28

### Fixed
- **run-executors.sh**: Проверка статуса задачи ПЕРЕД claim (избегает путаницы при race condition)
- **run-executors.sh**: Retry counter теперь берёт максимальный retry: label и удаляет старый при инкременте
- **orchestrator.sh**: Heredoc для формирования prompt в run_interactive_agent (безопасно для кавычек в agent prompts)

---

## [0.7.0] - 2026-01-28

### Fixed
- **P0 CRITICAL**: Beads CLI флаги — `--format=json` заменён на `--json` во всех скриптах
  - `bd show` и `bd ready` не поддерживают `--format=json` (только глобальный `--json`)
  - `bd list --format=json` выдавал пустой вывод (Go template, не JSON)
  - Затронуты: orchestrator.sh, run-executors.sh, run-senior-executor.sh, run-analysts.sh, detect-phase.sh

### Added
- **Existing project support**: `hype init` анализирует существующий код и создаёт PROJECT_CONTEXT.md
- **Delete command**: `hype delete` для полного удаления claudev из проекта
- **Deep analysis**: `analyze-project.sh` определяет стек, фреймворк, зависимости
- **Tech Writer integration**: Учитывает PROJECT_CONTEXT.md при создании SPEC.md

---

## [0.6.0] - 2026-01-27

### Added
- **Global installation**: claudev устанавливается в `~/.hype/` и доступен глобально
- **claudev init**: Инициализация проекта командой `hype init` в любой директории
- **Project-local config**: `.hype/config.sh` создаётся в проекте, не глобально
- **Symlinked agents**: `.claude/agents/` ссылается на глобальные агенты

### Changed
- install.sh теперь устанавливает глобально (не в текущую папку)
- bin/hype переписан как полноценный CLI с командами (init, run, status, delete)

---

## [0.5.5] - 2026-01-27

### Added
- **install.sh**: Auto-создание `.claude/settings.json` с pre-approved permissions
  - git, gh, bd — полный доступ без вопросов
  - Скрипты: `./scripts/*`, bash, timeout
  - Утилиты: jq, date, stat, pkill, kill, sleep
  - Файловые операции: Read, Edit, Write, Glob, Grep
- Пользователь больше не будет завален вопросами при запуске orchestrator

---

## [0.5.0] - 2026-01-27

### Milestone: Ready for Testing

Первый полностью функциональный релиз. Все 18 задач закрыты, архитектурный аудит пройден.

### Summary
- 10 агентов: Tech Writer, Manager, Architect, Executor, Senior Executor, 5 Analysts
- 8 скриптов: orchestrator, detect-phase, run-analysts, run-executors, run-senior-executor, close-completed-parents, log, notify
- 7 фаз: INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → FINAL_REVIEW → DONE
- 27 архитектурных решений задокументированы в PROJECT.md
- One-liner установка: `curl -fsSL .../invite.sh | bash`

### Architecture Highlights
- Atomic orchestrator lock (noclobber)
- Graceful shutdown с smart reset (5min threshold)
- Backpressure через MAX_PARALLEL_EXECUTORS
- Squash merge на Senior Executor (Haiku-friendly)
- Draft TTL 24h для Tech Writer
- Beads daemon health check каждую итерацию

---

## [0.4.21] - 2026-01-27

### Fixed
- **P1**: CHANGELOG — добавлена пропущенная запись v0.4.20

### Improved
- **P2**: orchestrator.sh — явная обработка BLOCKED_CYCLES (создаёт P0 задачу для Architect)
- **P2**: PROJECT.md — обновлено решение #15 (squash перенесён на Senior Executor с v0.4.10)

## [0.4.20] - 2026-01-26

### Fixed
- **P1**: executor.md — добавлен TASK_TITLE extraction перед использованием в эскалации
- **P1**: senior-executor.md — убран дублирующий поиск задачи, TASK_ID берётся из контекста

### Improved
- **P2**: analyst-architecture.md — упрощена проверка model: labels (читаемый bash вместо сложного jq)
- **P2**: Все агенты — добавлена секция "Контекст" с явными переменными (TASK_ID, TRIGGER_TASK, PROJECT_ROOT)
- **P2**: executor.md — добавлена заметка для Haiku про пропуск rebase
- **P2**: senior-executor.md — очистка reviewing label во всех exit paths
- **P2**: detect-phase.sh — проверка циклов перед IMPLEMENTATION фазой

### Minor
- **P3**: tech-writer.md — уточнение что timeout это рекомендация
- **P3**: orchestrator.sh — health check для claude CLI при старте
- **P3**: run-executors.sh — удаление executor label при timeout/error

## [0.4.13] - 2026-01-26

### Fixed
- **P2**: senior-executor.md унифицирован подход к labels (`bd label remove` → `bd update --remove-label`)
- **P2**: PROJECT.md примеры обновлены для соответствия реальному коду:
  - `bd list --label=` → jq фильтры (как в orchestrator.sh)
  - `--label=X` → `--labels=X` для bd create

## [0.4.12] - 2026-01-26

### Fixed
- **P0 CRITICAL**: `bd update --label=X` не существует в beads CLI — заменено на `--add-label=X`
  - run-executors.sh: executor claim и retry labels
  - executor.md: needs-rebase, needs-review labels
  - senior-executor.md: reviewing label
  - manager.md: blocked/escalation labels
  - architect.md: blocked:escalation-limit label
  - PROJECT.md: примеры в документации

### Changed
- manager.md: `--label=X --label=Y` заменено на `--labels=X,Y` для bd create
- manager.md: `--label=-retry:*` заменено на `--set-labels=` для сброса labels

## [0.4.11] - 2026-01-26

### Fixed
- **P2**: architect.md heredoc теперь корректно вычисляет дату (переменные до EOF, не внутри 'EOF')

## [0.4.10] - 2026-01-26

### Fixed
- **P1**: Tech Writer больше не использует bd commands (state через файлы SPEC.md/SPEC.draft.md)
- **P1**: Executor больше не делает squash — Senior Executor делает squash merge (безопаснее)
- **P2**: Milestone creation для analysts перенесён в orchestrator (нет race condition)
- **P3**: VERSION path в stats теперь передаётся параметром (корректно при symlinks)

### Changed
- tech-writer.md: убраны `bd update`/`bd close`, только файловые операции
- executor.md: убран шаг squash (git reset --soft), просто push после rebase
- senior-executor.md: local merge теперь `git merge --squash` вместо `--no-ff`
- run-analysts.sh: убрано создание milestone (теперь в orchestrator)
- orchestrator.sh: создаёт milestone:analysts-done после run-analysts.sh

## [0.4.9] - 2026-01-26

### Added
- **Stats generation**: отчёт `stats/iteration-*.md` с метриками итерации (задачи, агенты, токены)
- **Draft TTL check**: SPEC.draft.md старше 24h автоматически архивируется, начинается заново

### Changed
- orchestrator.sh: генерирует stats при завершении итерации (фаза DONE)
- orchestrator.sh: проверяет возраст draft перед INIT фазой

## [0.4.6] - 2026-01-26

### Fixed
- **P2**: Кроссплатформенный date parsing в orchestrator.sh (macOS + Linux)
- executor.md: убраны вызовы `./scripts/log.sh`, упрощены примеры ошибок

### Changed
- run-executors.sh: фильтр задач по title pattern вместо `implementation` label
- run-executors.sh: добавлен warning в лог при fallback на sonnet (если нет `model:*` label)
- architect.md: убран устаревший `--label=implementation` из примеров

### Removed
- `implementation` label больше не используется (избыточен, `model:*` достаточен)

## [0.4.5] - 2026-01-26

### Fixed
- **P1**: architect.md теперь ищет task id по title (bd требует id, не title)
- **P1**: run-senior-executor.sh корректно удаляет label (`--remove-label` вместо `--label=""`)
- **P1**: analyst-architecture.md валидирует наличие `model:*` label на tasks (defense in depth)

### Changed
- orchestrator.sh выводит версию при старте (отладка)
- detect-phase.sh: убрано дублирование в HELPERS фазе

### Removed
- Мёртвый код `run_agent()` из orchestrator.sh (заменён на `run_agent_with_mode`)

## [0.4.4] - 2026-01-26

### Fixed
- **P0 CRITICAL**: orchestrator теперь НАПРЯМУЮ вызывает скрипты по фазам (bash вызывает bash)
- **P0 CRITICAL**: Все агенты теперь с tool use (`-p` вместо `--print`)
  - `--print` отключал Bash tool — агенты не могли выполнять `bd create`, `git commit`
  - Теперь: `claude --model $model -p "$prompt"` — полный доступ к tools
- Исправлено в: orchestrator.sh, run-analysts.sh, run-executors.sh, run-senior-executor.sh
- Manager теперь тоже с tool use — автономно разрешает проблемы

### Changed
- **Архитектура разделена на два уровня:**
  - Механика (bash): orchestrator напрямую вызывает run-analysts.sh, run-executors.sh, агентов
  - Решения (LLM): Manager вызывается при проблемах и САМ их разрешает
- dispatch_phase() теперь содержит прямые вызовы для каждой фазы
- manager.md: переписан как "Problem Resolver" — выполняет команды, не даёт рекомендации

### Added
- `run_agent_with_mode()` — запуск агента с MODE параметром
- `create_analyst_triggers()` — создание trigger tasks для analysts
- `check_and_create_done_milestone()` — проверка FINAL_REVIEW: PASSED
- `check_problems_and_consult_manager()` — вызов Manager при проблемах
- `call_manager_for_problems()` — передача контекста проблем Manager'у

## [0.4.3] - 2026-01-26

### Fixed
- **P0 CRITICAL**: Trigger tasks для analysts теперь создаются (Manager вызывается для всех фаз кроме INIT/DONE)
- **P0 CRITICAL**: Trigger task run-plan-review теперь создаётся Manager'ом
- **P0 CRITICAL**: milestone:project-done теперь создаётся в FINAL_REVIEW
- run_interactive_agent передаёт содержимое файла через --system-prompt (не путь)

### Changed
- orchestrator.sh: dispatch_phase() теперь делегирует Manager'у для всех фаз кроме INIT и DONE
- manager.md: переписан под получение CURRENT_PHASE из контекста orchestrator
- Архитектура: orchestrator определяет фазу → вызывает Manager → Manager выполняет действия

## [0.4.2] - 2026-01-26

### Fixed
- **P0 CRITICAL**: Tech Writer теперь запускается интерактивно (без `--print`)
- Фаза INIT требует диалога с пользователем — невозможно в non-interactive режиме

### Added
- `run_interactive_agent()` — новая функция для агентов требующих user input

## [0.4.1] - 2026-01-26

### Fixed
- Heredoc syntax in orchestrator.sh — `$(cat ...)` теперь выполняется до heredoc
- Heredoc syntax in run-executors.sh — error handler перенесён из heredoc body в if/then
- Heredoc syntax in run-analysts.sh — аналогичное исправление
- Backpressure filter — теперь считает только `executor` label, не `model:*`

### Added
- Phase dispatcher в orchestrator — прямой вызов скриптов по фазам вместо зависимости от Manager
- run-senior-executor.sh — обработка задач с `needs-review` label (sequential quality gate)

### Changed
- Orchestrator больше не зависит от Manager.md для dispatch команд
- Manager становится advisory (опционально для отладки)

## [0.4] - 2026-01-24

### Added
- Architect обязан повышать версию и обновлять changelog в FINAL_REVIEW
- VERSION файл для хранения текущей версии (универсально для любого стека)
- SemVer: MAJOR (breaking) / MINOR (features) / PATCH (bugfixes)

### Changed
- architect.md: расширена секция MODE: final_review с версионированием

## [0.3] - 2026-01-24

### Added
- Auto-close features и epics когда все children завершены
- Новый скрипт `close-completed-parents.sh`
- Использует встроенную команду beads `bd epic close-eligible`

### Changed
- orchestrator.sh вызывает auto-close каждый цикл (шаг 7)

## [0.2] - 2026-01-24

### Added
- One-liner установка: `curl ... | bash`
- Полная автоустановка зависимостей (homebrew, beads, gh, jq, claude-code)
- Поддержка Windows через WSL (автоопределение + инструкции)
- README для пользователей

### Changed
- Очистка .hype/ от файлов разработки после установки
- Пользователь видит только рабочие файлы (core/, templates/, install.sh)

## [0.1] - 2026-01-24

### Added
- Многоагентная система разработки
- 10 агентов: Tech Writer, Manager, Architect, Executor, Senior Executor, 5 Analysts
- Orchestrator с atomic lock, graceful shutdown
- Beads интеграция для управления задачами
- 7 фаз проекта: INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → FINAL_REVIEW → DONE
- Архитектурный аудит: 19 угроз найдено и закрыто
