#!/bin/bash
# .hype/config.sh — конфигурация Hype
# Скопировано из templates/config.template.sh при установке
#
# Редактируйте значения под свой проект.
# Orchestrator перечитывает этот файл каждую итерацию.

# === Основные настройки ===

# Максимум параллельных Executor агентов
MAX_PARALLEL_EXECUTORS=3

# Лимит retry перед эскалацией к Architect
RETRY_LIMIT=3

# Пауза между итерациями HYPE (seconds)
ITERATION_DELAY=30

# === Таймауты ===

# Таймаут выполнения задачи агентом (executor)
TASK_TIMEOUT="10m"

# Таймаут code review (короче т.к. контекст передаётся в prompt)
REVIEW_TIMEOUT="5m"

# Таймаут для PLANNING (architect создаёт план из SPEC.md)
PLANNING_TIMEOUT="15m"

# Таймаут для каждого analyst агента
ANALYST_TIMEOUT="10m"

# Таймаут для PLAN_REVIEW (architect ревьюит добавления analysts)
PLAN_REVIEW_TIMEOUT="10m"

# Таймаут для каждого tester агента (SMOKE_TEST phase)
TESTER_TIMEOUT="10m"

# Общий таймаут на SMOKE_TEST фазу
SMOKE_TEST_TIMEOUT="15m"

# Таймаут для FINAL_REVIEW (architect проверяет весь проект)
FINAL_REVIEW_TIMEOUT="15m"

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
MODEL_TECH_WRITER="opus"
MODEL_ARCHITECT="opus"
MODEL_ANALYSTS="sonnet"
# MODEL_SENIOR_EXECUTOR не используется напрямую —
# tiered review: opus задачи → opus review, остальные → sonnet
MODEL_MANAGER="sonnet"
MODEL_ANALYZER="opus"

# Модели для SMOKE_TEST testers
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

