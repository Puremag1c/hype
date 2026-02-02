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

# Таймаут выполнения задачи агентом
TASK_TIMEOUT="10m"

# Таймаут ожидания ввода пользователя (Tech Writer)
USER_INPUT_TIMEOUT="30m"

# === CI/CD ===

# Включить интеграцию с GitHub CI
CI_ENABLED=false

# Включить автоматический релиз (CD)
CD_ENABLED=false

# === Логирование ===

# Режим отладки — показывает детальную диагностику
# Включает: значения переменных в detect-phase, stderr скриптов
DEBUG=false

# Логировать оценку токенов (для анализа расхода)
LOG_TOKENS=false

# === Cleanup ===

# Автоматически удалять старые логи
CLEANUP_ENABLED=false

# Хранить логи N дней (если CLEANUP_ENABLED=true)
CLEANUP_KEEP_DAYS=30
