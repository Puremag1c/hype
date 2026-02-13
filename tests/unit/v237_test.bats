#!/usr/bin/env bats
# tests/unit/v237_test.bats
# Tests for v2.3.7: bd_safe auto-recovery, heal-before-dispatch, executor restrictions

load '../helpers/setup'

# =============================================================================
# P0: bd_safe write auto-recovery
# =============================================================================

@test "bd_safe: auto-recovery block exists for write operations" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Must detect write failures (update/close/create/sync)
    grep -q 'update|close|create|sync' "$common_sh"
}

@test "bd_safe: retries failed write after daemon health check" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Must have retry logic after daemon probe
    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    # Must probe daemon health
    echo "$recovery_block" | grep -q 'bd list --limit 1'

    # Must attempt daemon restart
    echo "$recovery_block" | grep -q 'daemon restart'

    # Must retry the command
    echo "$recovery_block" | grep -q 'timeout_cmd.*bd.*"$@"'
}

@test "bd_safe: logs warning on write failure" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    # Must log WARN with command info
    echo "$recovery_block" | grep -q 'WARN.*bd.*failed'
}

@test "bd_safe: logs recovery success" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    echo "$recovery_block" | grep -q 'recovered after retry'
}

@test "bd_safe: logs error on retry failure" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    echo "$recovery_block" | grep -q 'ERROR.*retry failed'
}

@test "bd_safe: does NOT retry read operations (list, show)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # The case statement only matches write operations
    local case_block
    case_block=$(sed -n '/Auto-recovery for failed write/,/esac/p' "$common_sh")

    # Only update|close|create|sync — no list, show, etc.
    echo "$case_block" | grep -q 'update|close|create|sync)'

    # Must NOT contain list or show in the case pattern
    ! echo "$case_block" | grep -q 'list|show'
}

@test "bd_safe: releases lock AFTER retry (not before)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Get line numbers for retry and lock release
    local retry_line lock_line
    retry_line=$(grep -n 'recovered after retry' "$common_sh" | head -1 | cut -d: -f1)
    lock_line=$(grep -n 'Release lock' "$common_sh" | head -1 | cut -d: -f1)

    # Lock release must come after retry
    [ "$retry_line" -lt "$lock_line" ]
}

# =============================================================================
# P1: heal_stuck_tasks before dispatch_phase
# =============================================================================

@test "hype.sh: heal_stuck_tasks runs BEFORE dispatch_phase" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Get line numbers in main loop
    local heal_line dispatch_line
    heal_line=$(grep -n 'heal_stuck_tasks' "$hype_sh" | grep -v '^[0-9]*:heal_stuck_tasks()' | grep -v '#' | head -1 | cut -d: -f1)
    dispatch_line=$(grep -n 'dispatch_phase.*phase.*phase_json' "$hype_sh" | grep -v 'function\|#' | head -1 | cut -d: -f1)

    # heal must run before dispatch
    [ "$heal_line" -lt "$dispatch_line" ]
}

@test "hype.sh: in_progress_cache shared between heal and check_stale" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # v2.3.9: Cache is extracted from tick-cache.json (not bd_safe)
    local cache_line heal_line stale_line
    cache_line=$(grep -n 'in_progress_cache=.*tick-cache' "$hype_sh" | head -1 | cut -d: -f1)
    heal_line=$(grep -n 'heal_stuck_tasks.*in_progress_cache' "$hype_sh" | grep -v '^[0-9]*:heal_stuck_tasks()' | head -1 | cut -d: -f1)
    stale_line=$(grep -n 'check_stale_tasks.*in_progress_cache' "$hype_sh" | head -1 | cut -d: -f1)

    # Order: cache → heal → stale
    [ "$cache_line" -lt "$heal_line" ]
    [ "$heal_line" -lt "$stale_line" ]
}

@test "hype.sh: only ONE in_progress_cache fetch in main loop" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract main loop (from "while [ \$cycle" to "done")
    local main_loop
    main_loop=$(sed -n '/while \[ \$cycle/,/^    done$/p' "$hype_sh")

    # v2.3.9: Count in_progress_cache assignments from tick-cache
    local count
    count=$(echo "$main_loop" | grep 'in_progress_cache=.*tick-cache' | wc -l | tr -d ' ')

    [ "$count" -eq 1 ]
}

# =============================================================================
# P2: executor.md restricts bd create
# =============================================================================

@test "executor.md: has explicit bd create restriction" {
    local executor_md="$CORE_DIR/agents/executor.md"

    grep -q 'НИКОГДА не создавай новые задачи.*bd create' "$executor_md"
}

@test "executor.md: allows bd create exception for rebase conflicts" {
    local executor_md="$CORE_DIR/agents/executor.md"

    # Rule mentions rebase as exception
    grep -q 'rebase' "$executor_md" | head -1

    # The actual bd create in the rebase section still exists
    grep -q 'bd create.*Resolve rebase conflict' "$executor_md"
}

# =============================================================================
# v2.3.9: File-based milestones (replaced bd tasks)
# =============================================================================

@test "common.sh: milestone functions are file-based (no bd calls)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # _milestone_file returns .hype/milestone-{name} path
    local func_body
    func_body=$(sed -n '/^_milestone_file()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'milestone-'

    # has_milestone checks file existence (not bd)
    func_body=$(sed -n '/^has_milestone()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q '\[ -f '
    ! echo "$func_body" | grep -q 'bd_safe'

    # ensure_milestone writes file (not bd create)
    func_body=$(sed -n '/^ensure_milestone()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'echo.*>.*\$mfile'
    ! echo "$func_body" | grep -q 'bd_safe'

    # delete_milestone uses rm -f (not bd)
    func_body=$(sed -n '/^delete_milestone()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'rm -f'
    ! echo "$func_body" | grep -q 'bd_safe'
}

@test "common.sh: delete_all_milestones globs .hype/milestone-*" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local func_body
    func_body=$(sed -n '/^delete_all_milestones()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'milestone-\*'
    ! echo "$func_body" | grep -q 'bd_safe'
}

@test "common.sh: milestone functions use HYPE_DIR with .hype default" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local func_body
    func_body=$(sed -n '/^_milestone_file()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'HYPE_DIR:-.hype'
}

# =============================================================================
# v2.3.9: tick-cache.json
# =============================================================================

@test "detect-phase.sh: writes tick-cache.json after bd list" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Must write ALL_TASKS_JSON to tick-cache
    grep -q 'tick-cache.json' "$detect_sh"
    grep -q 'ALL_TASKS_JSON.*tick-cache' "$detect_sh"
}

@test "detect-phase.sh: uses _check_milestone with file fallback to bd" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Must check file first
    grep -q 'milestone-.*echo 1.*return' "$detect_sh"
    # Must fall back to bd task labels for backward compat (≤v2.3.8)
    grep -q 'ALL_TASKS_JSON.*milestone:' "$detect_sh"
}

@test "detect-phase.sh: empty bd response guard (prevents phase regression)" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # If TOTAL==0 but milestones exist → ERROR (not PLANNING)
    grep -q 'milestones exist.*daemon returned empty' "$detect_sh"
    grep -q 'output_json "ERROR"' "$detect_sh"
}

@test "hype.sh: exports HYPE_DIR for milestone functions" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    grep -q 'export HYPE_DIR=' "$hype_sh"
}

@test "hype.sh: dispatch_phase reads tick-cache for IMPLEMENTATION" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # IMPLEMENTATION dispatch should NOT have bd_safe list
    local impl_block
    impl_block=$(sed -n '/^        IMPLEMENTATION)/,/;;$/p' "$hype_sh")
    ! echo "$impl_block" | grep -q 'bd_safe list'
}

@test "hype.sh: dispatch_phase reads tick-cache for SMOKE_TEST" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_block
    smoke_block=$(sed -n '/^        SMOKE_TEST)/,/;;$/p' "$hype_sh")

    # tick-cache reads exist
    echo "$smoke_block" | grep -q 'tick-cache.json'

    # No bd_safe list
    ! echo "$smoke_block" | grep -q 'bd_safe list'
}

@test "hype.sh: dispatch_phase reads tick-cache for SMOKE_REVIEW" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_review_block
    smoke_review_block=$(sed -n '/^        SMOKE_REVIEW)/,/;;$/p' "$hype_sh")

    echo "$smoke_review_block" | grep -q 'tick-cache.json'
    # No bd_safe list calls (excluding comments)
    ! echo "$smoke_review_block" | grep -v '^[[:space:]]*#' | grep -q 'bd_safe list'
}

@test "hype.sh: dispatch_phase reads tick-cache for USER_REVIEW" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local user_block
    user_block=$(sed -n '/^        USER_REVIEW)/,/;;$/p' "$hype_sh")

    echo "$user_block" | grep -q 'tick-cache.json'
    ! echo "$user_block" | grep -q 'bd_safe list'
}

@test "hype.sh: FINAL_REVIEW keeps bd_safe for post-agent checks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # FINAL_REVIEW must still use bd_safe list (post-agent, needs fresh data)
    local final_block
    final_block=$(sed -n '/^        FINAL_REVIEW)/,/;;$/p' "$hype_sh")
    echo "$final_block" | grep -q 'bd_safe list'
}

@test "hype.sh: heal reads from tick-cache in main loop" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Main loop extracts in_progress from tick-cache
    grep -q 'jq.*in_progress.*tick-cache.json' "$hype_sh"
}

@test "hype.sh: check_and_route_troubleshoot reads tick-cache" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_body
    func_body=$(sed -n '/^check_and_route_troubleshoot()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'tick-cache.json'
    ! echo "$func_body" | grep -q 'bd_safe list'
}

@test "hype.sh: check_problems_and_consult_manager reads tick-cache" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_body
    func_body=$(sed -n '/^check_problems_and_consult_manager()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'tick-cache.json'
    ! echo "$func_body" | grep -q 'bd_safe list'
}

@test "hype.sh: generate_iteration_stats reads tick-cache" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_body
    func_body=$(sed -n '/^generate_iteration_stats()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'tick-cache.json'
    ! echo "$func_body" | grep -q 'bd_safe list'
}

# =============================================================================
# v2.3.9: reset-phase cleans legacy bd milestone labels
# =============================================================================

@test "bin/hype: reset-phase cleans legacy bd milestone labels" {
    local hype_bin="$PROJECT_ROOT/bin/hype"

    # cmd_reset_phase must have legacy bd milestone cleanup
    local func_body
    func_body=$(sed -n '/^cmd_reset_phase()/,/^}/p' "$hype_bin")

    # Must iterate over all 5 milestone labels
    echo "$func_body" | grep -q 'milestone:planning-done'
    echo "$func_body" | grep -q 'milestone:plan-reviewed'
    echo "$func_body" | grep -q 'milestone:project-done'

    # Must check has_milestone (only clean deleted ones)
    echo "$func_body" | grep -q 'has_milestone'

    # Must remove labels from bd tasks
    echo "$func_body" | grep -q 'remove-label.*milestone_label'
}

@test "bin/hype: reset-phase deletes tick-cache.json" {
    local hype_bin="$PROJECT_ROOT/bin/hype"

    local func_body
    func_body=$(sed -n '/^cmd_reset_phase()/,/^}/p' "$hype_bin")
    echo "$func_body" | grep -q 'tick-cache.json'
}

@test "common.sh: cleanup_iteration deletes tick-cache.json" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local func_body
    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'tick-cache.json'
}

@test "common.sh: cleanup_iteration counts file milestones in preview" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local func_body
    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")

    # Must check file milestones (not just bd)
    echo "$func_body" | grep -q 'milestone-\*'
}

# =============================================================================
# v2.3.10: Batch bd call optimizations
# =============================================================================

@test "common.sh: cleanup_stale_trigger accepts optional cache parameter" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local func_body
    func_body=$(sed -n '/^cleanup_stale_trigger()/,/^}/p' "$common_sh")

    # Must have optional cache parameter
    echo "$func_body" | grep -q 'bd_cache=.*{2:-}'

    # Must filter cache by status != closed (tick-cache has --all)
    echo "$func_body" | grep -q 'status.*!=.*closed'

    # Must still have fallback bd_safe list when no cache
    echo "$func_body" | grep -q 'bd_safe list'
}

@test "hype.sh: create_analyst_triggers reads tick-cache once (not N bd_safe list)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_body
    func_body=$(sed -n '/^create_analyst_triggers()/,/^}/p' "$hype_sh")

    # Must read tick-cache.json once
    echo "$func_body" | grep -q 'tick-cache.json'

    # Must pass cache to cleanup_stale_trigger
    echo "$func_body" | grep -q 'cleanup_stale_trigger.*\$bd_cache'

    # Must NOT have its own bd_safe list call (excluding comments)
    ! echo "$func_body" | grep -v '^[[:space:]]*#' | grep -q 'bd_safe list'
}

@test "hype.sh: dispatch_phase passes tick-cache to single trigger cleanups" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # PLAN_REVIEW: passes cache
    local plan_block
    plan_block=$(sed -n '/^        PLAN_REVIEW)/,/;;$/p' "$hype_sh")
    echo "$plan_block" | grep -q 'cleanup_stale_trigger "run-plan-review" "\$bd_cache"'

    # FINAL_REVIEW: versioner passes cache
    grep -q 'cleanup_stale_trigger "run-versioning" "\$bd_cache"' "$hype_sh"
}

@test "hype.sh: close-completed-parents skipped when no features/epics" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Must check tick-cache for features/epics before calling script
    grep -q 'issue_type.*feature.*epic' "$hype_sh"
    grep -q 'close-completed-parents.sh' "$hype_sh"
}

@test "run-testers.sh: create_tester_triggers accepts cache parameter" {
    local testers_sh="$SCRIPTS_DIR/run-testers.sh"

    local func_body
    func_body=$(sed -n '/^create_tester_triggers()/,/^}/p' "$testers_sh")

    # Must accept cache as $2
    echo "$func_body" | grep -q 'bd_cache=.*{2:-}'

    # Must pass cache to cleanup_stale_trigger
    echo "$func_body" | grep -q 'cleanup_stale_trigger.*\$bd_cache'
}

# =============================================================================
# v2.3.11: Hybrid merge queue (script + merger agent fallback)
# =============================================================================

@test "merger.md: agent prompt exists with required structure" {
    local merger_md="$SCRIPTS_DIR/../agents/merger.md"
    [ -f "$merger_md" ]

    # YAML frontmatter
    grep -q '^name: merger' "$merger_md"
    grep -q '^model: opus' "$merger_md"

    # Required sections
    grep -q 'TASK_ID' "$merger_md"
    grep -q 'BRANCH' "$merger_md"
    grep -q 'MAIN_REF' "$merger_md"
}

@test "merger.md: requires hook-free git operations" {
    local merger_md="$SCRIPTS_DIR/../agents/merger.md"

    # Must instruct agent to use git -c core.hooksPath=/dev/null
    grep -q 'core.hooksPath=/dev/null' "$merger_md"
}

@test "merger.md: requires bd close on success" {
    local merger_md="$SCRIPTS_DIR/../agents/merger.md"

    # Must instruct agent to close task on success
    grep -q 'bd close' "$merger_md"
}

@test "merger.md: requires bd update on failure" {
    local merger_md="$SCRIPTS_DIR/../agents/merger.md"

    # Must instruct agent to update task with notes on failure
    grep -q 'bd update.*--status=open.*--remove-label=approved' "$merger_md"
}

@test "run-merge-queue.sh: defines try_fast_merge function" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    grep -q '^try_fast_merge()' "$merge_sh"

    local func_body
    func_body=$(sed -n '/^try_fast_merge()/,/^}/p' "$merge_sh")

    # Must do rebase
    echo "$func_body" | grep -q 'rebase'

    # Must do squash merge
    echo "$func_body" | grep -q 'merge --squash'

    # Must push
    echo "$func_body" | grep -q 'push origin'
}

@test "run-merge-queue.sh: defines run_merger_agent function" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    grep -q '^run_merger_agent()' "$merge_sh"

    local func_body
    func_body=$(sed -n '/^run_merger_agent()/,/^}/p' "$merge_sh")

    # Must use run_claude_with_progress
    echo "$func_body" | grep -q 'run_claude_with_progress'

    # Must load merger.md prompt
    echo "$func_body" | grep -q 'merger.md'

    # Must verify task was closed after agent
    echo "$func_body" | grep -q 'post_status'
}

@test "run-merge-queue.sh: merge_task calls agent on fast merge failure" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    local func_body
    func_body=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")

    # Must call try_fast_merge first
    echo "$func_body" | grep -q 'try_fast_merge'

    # Must call run_merger_agent on failure
    echo "$func_body" | grep -q 'run_merger_agent'

    # Must clean state between fast merge and agent
    echo "$func_body" | grep -q 'reset --hard'
}

@test "run-merge-queue.sh: no merge-conflict counter loop (replaced by agent)" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # Must NOT have merge-conflict:N counter logic (old retry system)
    ! grep -q 'merge-conflict' "$merge_sh"
    ! grep -q 'conflict_count' "$merge_sh"
    ! grep -q 'get_counter_value.*merge' "$merge_sh"
    ! grep -q 'set_counter_label.*merge' "$merge_sh"
}

@test "run-merge-queue.sh: empty merge detection before agent launch" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    local func_body
    func_body=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")

    # After fast merge fails, must check if branch has diff
    echo "$func_body" | grep -q 'has_diff'

    # Empty merge → close task (not call agent)
    echo "$func_body" | grep -q 'Empty merge.*branch changes already in main'
}

@test "run-merge-queue.sh: agent failure returns task to executor" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    local func_body
    func_body=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")

    # After agent fails: clean state + return to executor
    echo "$func_body" | grep -q 'Merger agent failed'
    echo "$func_body" | grep -q 'status=open.*remove-label=approved'
}

# === v2.3.12: Task granularity directive in architect agents ===

@test "architect-reviewer.md: has task granularity directive (1-5 min)" {
    local reviewer="$AGENTS_DIR/architect-reviewer.md"

    # Critical rule about task size
    grep -q '1-5 минут' "$reviewer"

    # Granularity check in plan_review
    grep -q '>3 файлов' "$reviewer"
}

@test "architect-qa.md: has task granularity directive (1-5 min)" {
    local qa="$AGENTS_DIR/architect-qa.md"

    # Critical rule about task size
    grep -q '1-5 минут' "$qa"

    # Granularity in smoke_review section G (split subtasks)
    local section_g
    section_g=$(sed -n '/Нужно раздробить/,/^---/p' "$qa")
    echo "$section_g" | grep -q '1-5 минут'

    # Granularity in final_review section 3.5 (create bug tasks)
    local section_35
    section_35=$(sed -n '/Шаг 3: Создай новый баг/,/NEEDS_FIXES/p' "$qa")
    echo "$section_35" | grep -q '1-5 минут'
}

@test "architect-planner.md: has task granularity directive (baseline)" {
    local planner="$AGENTS_DIR/architect-planner.md"

    # Both locations
    grep -q '1-5 минут каждая' "$planner"
    grep -q '1-5 минут для LLM' "$planner"
}

@test "all architect agents: consistent granularity rule" {
    # All three architect agents that create/manage tasks should have the directive
    for agent in architect-planner.md architect-reviewer.md architect-qa.md; do
        local file="$AGENTS_DIR/$agent"
        grep -q '1-5 минут' "$file" || {
            echo "MISSING in $agent"
            return 1
        }
    done
}

# === v2.3.13: Force SMOKE_TEST while testers running ===

@test "detect-phase.sh: forces SMOKE_TEST when testers PID alive" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Must read PID file
    grep -q 'run-testers.pid' "$detect_sh"

    # Must check if process is alive (kill -0)
    grep -q 'kill -0' "$detect_sh"

    # PID alive → output SMOKE_TEST and exit
    # This block must come BEFORE SMOKE_REVIEW check
    local pid_block
    pid_block=$(sed -n '/testers actively running/,/exit 0/p' "$detect_sh")
    echo "$pid_block" | grep -q 'SMOKE_TEST'
}

@test "detect-phase.sh: SMOKE_REVIEW only reachable when testers done" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # PID check (exits with SMOKE_TEST) must come BEFORE SMOKE_REVIEW
    local pid_line smoke_review_line
    pid_line=$(grep -n 'testers actively running' "$detect_sh" | head -1 | cut -d: -f1)
    smoke_review_line=$(grep -n 'SMOKE_TRIAGE_OPEN.*-gt 0' "$detect_sh" | head -1 | cut -d: -f1)

    [ "$pid_line" -lt "$smoke_review_line" ]
}

@test "detect-phase.sh: SMOKE_REVIEW check is simple (no testers guard needed)" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # SMOKE_REVIEW condition should be simple — testers check is upstream
    local smoke_block
    smoke_block=$(sed -n '/SMOKE_TRIAGE_OPEN.*-gt 0/,/exit 0/p' "$detect_sh" | head -5)
    echo "$smoke_block" | grep -q 'SMOKE_REVIEW'
    # No TESTERS_STILL_RUNNING in the SMOKE_REVIEW block itself
    ! echo "$smoke_block" | grep -q 'TESTERS_STILL_RUNNING'
}

@test "hype.sh: SMOKE_REVIEW cleans leftover smoke labels (safety net)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract SMOKE_REVIEW handler
    local smoke_block
    smoke_block=$(sed -n '/SMOKE_REVIEW)/,/;;/p' "$hype_sh")

    # Must read remaining smoke task IDs from tick-cache
    echo "$smoke_block" | grep -q 'remaining_smoke_ids'
    echo "$smoke_block" | grep -q 'tick-cache.json'

    # Must force-remove smoke and regression labels
    echo "$smoke_block" | grep -q 'remove-label=smoke'
    echo "$smoke_block" | grep -q 'remove-label=regression'
}

@test "run-merge-queue.sh: FAST_MERGE_ERROR captures failure context" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # Shared variable defined
    grep -q '^FAST_MERGE_ERROR=""' "$merge_sh"

    # try_fast_merge captures errors into it
    local func_body
    func_body=$(sed -n '/^try_fast_merge()/,/^}/p' "$merge_sh")
    echo "$func_body" | grep -q 'FAST_MERGE_ERROR='

    # run_merger_agent receives it
    local agent_call
    agent_call=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")
    echo "$agent_call" | grep -q 'FAST_MERGE_ERROR'
}
