#!/bin/bash
# .hype/config.sh — конфигурация Hype
# Скопировано из templates/config.template.sh при установке
#
# Редактируйте значения под свой проект.
# Orchestrator перечитывает этот файл каждую итерацию.

# === Основные настройки ===

# Максимум параллельных Coder агентов
MAX_PARALLEL_CODERS=3

# Максимум параллельных Senior агентов (v2.2)
MAX_PARALLEL_SENIORS=3

# Лимит retry перед эскалацией к Architect
RETRY_LIMIT=3

# Пауза между итерациями HYPE (seconds)
ITERATION_DELAY=30

# === Таймауты ===

# Таймаут выполнения задачи агентом (coder)
TASK_TIMEOUT="10m"

# Таймаут code review (короче т.к. контекст передаётся в prompt)
REVIEW_TIMEOUT="5m"

# Таймаут для PLANNING (architect создаёт план из SPEC.md)
PLANNING_TIMEOUT="15m"

# Таймаут для каждого analyst агента
# NOTE: Increased from 10m to handle slow bd operations under load
ANALYST_TIMEOUT="15m"

# Таймаут для THINKING (architect ревьюит добавления analysts)
THINKING_TIMEOUT="10m"

# Таймаут для каждого tester агента (TESTING phase)
TESTER_TIMEOUT="10m"

# Общий таймаут на TESTING фазу
TESTING_TIMEOUT="15m"

# Таймаут для VALIDATING (architect проверяет весь проект)
VALIDATING_TIMEOUT="15m"

# Таймаут stale worktrees (секунды) — worktree старше этого удаляется
WORKTREE_STALE_TIMEOUT=900

# Таймаут stale tasks (секунды) — in_progress задача без обновлений сбрасывается
TASK_STALE_TIMEOUT=600

# === Модели ===

# Разрешённые модели (через запятую)
# Варианты: opus, sonnet, haiku
# Примеры:
#   "opus,sonnet,haiku" — все модели (default)
#   "opus,sonnet"       — без haiku (haiku→sonnet)
#   "sonnet,haiku"      — без opus (opus→sonnet)
#   "opus"              — только opus
#   "sonnet"            — только sonnet
ALLOWED_MODELS="opus,sonnet,haiku"

# Модели для каждой роли (применяется map_model с ALLOWED_MODELS)
MODEL_MANAGER="opus"
MODEL_ARCHITECT="opus"
MODEL_ANALYSTS="sonnet"
# Модель для senior (v2.2): sonnet по умолчанию, opus при reject:2+
MODEL_SENIOR="sonnet"
MODEL_ANALYZER="opus"

# Модели для TESTING testers
MODEL_TESTERS="haiku"               # Default for api, cli testers
MODEL_TESTER_FUNCTIONAL="sonnet"    # Must Have verification
MODEL_TESTER_VISUAL="opus"          # UI testing (needs vision)
MODEL_TESTER_REGRESSION="sonnet"    # Test suite runner

# === Логирование ===

# Режим отладки — показывает детальную диагностику
# Включает: значения переменных в detect-phase, stderr скриптов
DEBUG=false

# Логировать оценку токенов (для анализа расхода)
LOG_TOKENS=false

