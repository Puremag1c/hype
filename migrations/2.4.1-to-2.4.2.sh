#!/bin/bash
# Migration: 2.4.1 → 2.4.2
# Description: Rename config variables to match new agent names

config=".hype/config.sh"
[ -f "$config" ] || return 0

rename_var() {
    local old=$1 new=$2
    if grep -q "^${old}=" "$config" && ! grep -q "^${new}=" "$config"; then
        sed -i '' "s/^${old}=/${new}=/" "$config"
        info "Renamed config: $old → $new"
    fi
}

rename_var MAX_PARALLEL_EXECUTORS MAX_PARALLEL_CODERS
rename_var MAX_PARALLEL_REVIEWERS MAX_PARALLEL_SENIORS
rename_var MODEL_TECH_WRITER MODEL_MANAGER
rename_var MODEL_REVIEWER MODEL_SENIOR
