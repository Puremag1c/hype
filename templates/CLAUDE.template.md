# Project Instructions

Hype — многоагентная AI-система разработки.

## Архитектура

```
hype.sh (bash loop)
    │
    └─► Manager (Sonnet, stateless)
            │
            ├─► Определяет фазу
            ├─► Запускает агентов
            │
            └─► Агенты:
                ├─► Manager (Opus) — собирает требования
                ├─► Architect (Opus) — план, задачи, dependencies
                ├─► Analysts (Sonnet × 5) — аудит плана
                ├─► Coders (по задаче) — реализация
                └─► Senior (Opus) — ревью, merge
```

## Запуск

```bash
# Запустить систему
./scripts/hype.sh

# В фоне
nohup ./scripts/hype.sh &
tail -f logs/hype.log
```

## Фазы

| Фаза | Описание |
|------|----------|
| PREPARING | Нет SPEC.md → Manager собирает требования |
| PLANNING | Architect создаёт план из SPEC.md |
| ANALYZE | 5 Analysts аудитят план параллельно |
| THINKING | Architect ревьюит добавления Analysts |
| CODING | Coders реализуют задачи |
| TESTING | Testers проверяют smoke-тесты |
| REFLEXING | Architect триажит результаты тестов |
| CONSULTATION | Manager эскалирует вопросы пользователю |
| VALIDATING | Architect проверяет целостность |
| REPORTING | Completion Agent генерирует отчёт |
| DONE | Проект завершён |

## Полезные команды

```bash
bd ready                    # Готовые к работе задачи
bd list                     # Все задачи
bd list --status=in_progress # Задачи в работе
bd show <id>                # Детали задачи

./scripts/hype.sh   # Запустить систему
./scripts/detect-phase.sh   # Определить текущую фазу
```

## Конфигурация

Редактируйте `.hype/config.sh`:

```bash
MAX_PARALLEL_CODERS=3       # Параллельные Coders
RETRY_LIMIT=3               # Retry перед эскалацией
TASK_TIMEOUT="10m"          # Таймаут на задачу
```

## Логи

```bash
tail -f logs/hype.log           # Основной лог
ls logs/archive/                   # Архив итераций
cat logs/coder-<task-id>.log       # Лог конкретного coder
```
