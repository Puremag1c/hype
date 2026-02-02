# Hype — Project Context

## Что это

**Hype** — многоагентная система автоматической разработки на базе Claude Code.

Запустите `hype init` в любом проекте, опишите что хотите словами — система сама создаст план, распределит задачи между агентами и выдаст готовый результат.

**Версия:** 1.2.2

## Целевая аудитория

**Обычные люди без технического бэкграунда.** Пользователь может не знать что такое git, Python или терминал.

**Принцип:** Всё что можно автоматизировать — автоматизировано:
- Установка зависимостей (beads, gh, gitleaks) — автоматически
- Инициализация git и beads — автоматически
- Создание GitHub репозитория — предложение + автоматически
- Авторизация в GitHub — пошаговые подсказки
- Запуск системы — одна команда

**Пользователю нужно только:**
1. Скопировать команду установки в терминал
2. Отвечать на вопросы системы словами
3. Получить результат

## Структура проекта

```
hype/
├── bin/hype              # CLI (init, start, status, update, delete)
├── core/
│   ├── agents/              # Промпты агентов (11 шт)
│   │   ├── manager.md       # Координатор фаз (Sonnet)
│   │   ├── tech-writer.md   # Сбор требований (Opus)
│   │   ├── architect.md     # Планирование (Opus)
│   │   ├── executor.md      # Реализация задач (по label)
│   │   ├── senior-executor.md # Code review + merge (Opus)
│   │   ├── analyzer.md      # Глубокий анализ кода
│   │   └── analyst-*.md     # 5 аналитиков (Sonnet)
│   ├── scripts/             # Bash скрипты (10 шт)
│   │   ├── orchestrator.sh  # Главный цикл с lock file
│   │   ├── detect-phase.sh  # Определение фазы проекта
│   │   ├── run-analysts.sh  # Параллельный запуск аналитиков
│   │   ├── run-executors.sh # Параллельный запуск исполнителей
│   │   └── ...
│   └── commands/            # Slash-команды (/start, /status)
├── templates/               # Шаблоны (config, SPEC, CLAUDE)
├── docs/architecture.md     # Детальная архитектура
├── install.sh               # Глобальная установка
└── CHANGELOG.md             # История версий
```

## Фазы работы

```
INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → FINAL_REVIEW → DONE
```

| Фаза | Агент | Что происходит |
|------|-------|----------------|
| INIT | Tech Writer | Собирает требования, создаёт SPEC.md |
| PLANNING | Architect | Создаёт задачи в beads, расставляет deps |
| HELPERS | Analysts ×5 | Параллельный аудит плана |
| PLAN_REVIEW | Architect | Ревью добавлений от Analysts |
| IMPLEMENTATION | Executors | Параллельная реализация задач |
| FINAL_REVIEW | Architect | Проверка целостности |
| DONE | — | Проект завершён |

## Ключевые принципы

### Архитектура
- **Bash вызывает bash** — механика в скриптах, LLM только для решений
- **Beads как источник правды** — всё состояние в задачах, не в файлах
- **Атомарные операции** — lock file через `set -C`, claim через `bd update --claim`
- **Fail fast** — daemon down = stop, не продолжаем без sync

### Агенты
- **Изоляция** — каждый агент работает со своими данными
- **Простые команды** — одна операция = одна команда bd
- **Идемпотентность** — повторный запуск даёт тот же результат
- **Таймауты** — 10 мин на задачу, 3 retry до эскалации

### Git workflow
- Executor: работает в ветке `task/beads-xxx`, WIP commit перед rebase
- Senior Executor: squash merge через PR, cleanup веток
- Backpressure: лимит параллельных PR через `MAX_PARALLEL_EXECUTORS`

## Конфигурация проекта

После `hype init` создаётся `.hype/config.sh`:

```bash
MAX_PARALLEL_EXECUTORS=3    # Лимит параллельных задач
RETRY_LIMIT=3               # Retry до эскалации
TASK_TIMEOUT="10m"          # Таймаут на задачу
USER_INPUT_TIMEOUT="30m"    # Таймаут ожидания user
CI_ENABLED=false            # GitHub Actions
CD_ENABLED=false            # Автоматический релиз
```

## Зависимости

**Обязательные:**
- beads — управление задачами
- claude — Claude Code CLI

**Опциональные:**
- gh — GitHub CLI (для PR workflow)
- gitleaks — secret detection (авто-установка при наличии GitHub)

## Планируется

- OS Notifications (macOS/Linux)
- Webhook уведомления (Telegram, Slack)
- Автодокументация (README, API docs)
- Web UI для мониторинга

---

## ВАЖНО: Работа с файлами агентов

Файлы в `core/agents/*.md` — это **КОД ПРОЕКТА**, не инструкции для текущей сессии.

При работе над hype эти файлы редактируются как обычный код. Они станут инструкциями когда система будет установлена в целевой проект.
