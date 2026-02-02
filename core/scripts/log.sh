#!/bin/bash
# core/scripts/log.sh
# Хелпер для логирования в Hype.
#
# Формат: YYYY-MM-DD HH:MM:SS [AGENT] EVENT: message
# Файл: logs/hype.log
#
# Использование:
#   source ./scripts/log.sh
#   log "MANAGER" "INFO" "Starting phase detection"
#   log "EXECUTOR" "TASK_START" "hype-abc"
#   log "HYPE" "FATAL" "Beads daemon not running"
#
# Или напрямую:
#   ./scripts/log.sh MANAGER INFO "Starting phase detection"

# Находим корень проекта (где .hype/)
find_project_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.hype" ]; then
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    echo "$PWD"
}

PROJECT_ROOT=$(find_project_root)
LOGS_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOGS_DIR/hype.log"

# Создаём директорию если нет
mkdir -p "$LOGS_DIR"

# Цвета для терминала
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_CYAN="\033[36m"
COLOR_GRAY="\033[90m"

# Функция логирования
log() {
    local agent=$1
    local event=$2
    local message=$3
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Plain text to log file
    echo "$timestamp [$agent] $event: $message" >> "$LOG_FILE"

    # Colored output to terminal
    if [ -t 1 ]; then
        local color=""
        case "$event" in
            INFO|TASK_DONE|SUCCESS)  color="$COLOR_GREEN" ;;
            WARN|WARNING)            color="$COLOR_YELLOW" ;;
            ERROR|FATAL|FAIL)        color="$COLOR_RED" ;;
            TASK_START|START)        color="$COLOR_CYAN" ;;
            *)                       color="$COLOR_GRAY" ;;
        esac
        printf "${COLOR_GRAY}%s${COLOR_RESET} [%s] ${color}%s${COLOR_RESET}: %s\n" "$timestamp" "$agent" "$event" "$message"
    fi
}

# Если запущен напрямую (не source)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 3 ]; then
        echo "Usage: $0 AGENT EVENT MESSAGE"
        echo "Example: $0 MANAGER INFO 'Starting phase detection'"
        exit 1
    fi
    log "$1" "$2" "$3"
fi
