#!/bin/bash
# deep-analyze.sh — глубокий анализ проекта через Claude
#
# Когда использовать:
# - Проект большой (>50 файлов кода)
# - README неинформативный или отсутствует
# - Пользователь явно попросил детальный анализ
#
# Выход: обогащённый PROJECT_CONTEXT.md с глубоким пониманием архитектуры

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

HYPE_HOME="${HYPE_HOME:-$HOME/.hype}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
CONFIG_FILE="$PROJECT_ROOT/.hype/config.sh"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# === Check if deep analysis needed ===

needs_deep_analysis() {
    # Count code files
    local code_files=$(find "$PROJECT_ROOT" -type f \( \
        -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
        -o -name "*.py" -o -name "*.ex" -o -name "*.exs" \
        -o -name "*.go" -o -name "*.rs" \
    \) 2>/dev/null | wc -l | tr -d ' ')

    # Check README quality
    local has_good_readme=false
    if [[ -f "README.md" ]]; then
        local readme_lines=$(wc -l < README.md | tr -d ' ')
        if [[ $readme_lines -gt 50 ]]; then
            has_good_readme=true
        fi
    fi

    # Need deep analysis if:
    # - More than 50 files AND
    # - No good README
    if [[ $code_files -gt 50 ]] && [[ "$has_good_readme" = false ]]; then
        return 0  # true - needs deep analysis
    fi

    return 1  # false - basic analysis sufficient
}

# === Main ===

main() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]]; then
        if ! needs_deep_analysis; then
            echo "Deep analysis not needed (small project or good README exists)"
            echo "Use --force to run anyway"
            exit 0
        fi
    fi

    # Check PROJECT_CONTEXT.md exists (should be created by analyze-project.sh first)
    if [[ ! -f "$PROJECT_ROOT/PROJECT_CONTEXT.md" ]]; then
        echo "Running basic analysis first..."
        "$HYPE_HOME/core/scripts/analyze-project.sh"
    fi

    echo "Running deep analysis with Claude..."

    # Run analyzer agent
    local analyzer_model
    analyzer_model=$(map_model "${MODEL_ANALYZER:-opus}")
    timeout_cmd 5m claude --model "$analyzer_model" --print < "$HYPE_HOME/core/agents/analyzer.md" << EOF

---
PROJECT_ROOT: $PROJECT_ROOT
BASIC_CONTEXT: $(cat "$PROJECT_ROOT/PROJECT_CONTEXT.md")

Please analyze this project deeply. Read key files, understand architecture,
and enhance PROJECT_CONTEXT.md with your findings.
EOF

    echo "Deep analysis complete"
}

main "$@"
