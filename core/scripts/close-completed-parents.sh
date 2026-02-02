#!/bin/bash
# core/scripts/close-completed-parents.sh
# Автоматически закрывает features и epics когда все их children завершены.
#
# Вызывается из orchestrator.sh каждый цикл.
# Использует встроенную команду beads для epics + аналогичную логику для features.

set -euo pipefail

SCRIPT_DIR=$(dirname "$0")
source "$SCRIPT_DIR/log.sh"

# === Close completed features ===
# Features закрываются когда все их children (tasks) имеют статус closed

close_completed_features() {
    local closed_count=0

    # Получаем все open features
    local features
    features=$(bd list --type=feature --status=open --json 2>/dev/null || echo "[]")

    # Проверяем каждую feature
    for feature_id in $(echo "$features" | jq -r '.[].id' 2>/dev/null); do
        # Получаем children этой feature
        local children
        children=$(bd children "$feature_id" --json 2>/dev/null || echo "[]")

        local total closed
        total=$(echo "$children" | jq 'length')
        closed=$(echo "$children" | jq '[.[] | select(.status == "closed")] | length')

        # Если есть children и все closed — закрываем feature
        if [ "$total" -gt 0 ] && [ "$total" = "$closed" ]; then
            bd close "$feature_id" --reason="All $total children completed" >/dev/null 2>&1
            log "MANAGER" "AUTO_CLOSE" "Feature $feature_id closed (all $total children done)"
            ((closed_count++))
        fi
    done

    echo "$closed_count"
}

# === Close completed epics ===
# Использует встроенную команду beads

close_completed_epics() {
    local output
    output=$(bd epic close-eligible 2>&1 || true)

    # Логируем если что-то закрылось
    if echo "$output" | grep -q "Closed"; then
        log "MANAGER" "AUTO_CLOSE" "Epics auto-closed: $output"
    fi
}

# === Main ===

main() {
    # 1. Сначала закрываем features (они могут быть children epics)
    local features_closed
    features_closed=$(close_completed_features)

    # 2. Потом закрываем epics (теперь их children features могут быть closed)
    close_completed_epics

    # Выводим summary если что-то закрылось
    if [ "$features_closed" -gt 0 ]; then
        echo "Auto-closed $features_closed feature(s)"
    fi
}

main "$@"
