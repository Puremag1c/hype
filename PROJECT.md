# Hype — Project Context

## Что это

**Hype** — многоагентная система автоматической разработки на базе Claude Code.

Запустите `hype init` в любом проекте, опишите что хотите словами — система сама создаст план, распределит задачи между агентами и выдаст готовый результат.

**Версия:** 2.0.18
**Next:** 2.1.0

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
├── bin/hype                 # CLI (init, start, status, update, delete, doctor)
├── core/
│   ├── agents/              # Промпты агентов (24 шт)
│   │   ├── manager.md           # Координатор фаз (Sonnet)
│   │   ├── tech-writer.md       # Сбор требований (Opus)
│   │   ├── architect-planner.md # Создание плана из SPEC (Opus)
│   │   ├── architect-reviewer.md# Ревью добавлений аналитиков (Opus)
│   │   ├── architect-qa.md      # Final review + regression (Opus)
│   │   ├── architect-ops.md     # Conflicts, cycles (Sonnet)
│   │   ├── executor.md          # Реализация задач (по label)
│   │   ├── senior-executor.md   # Code review + merge (tiered)
│   │   ├── auditor.md           # Аудит задач с label:audit (Sonnet→Opus)
│   │   ├── analyzer.md          # Deep analysis кода (Opus)
│   │   ├── versioner.md         # VERSION + CHANGELOG (Haiku)
│   │   ├── analyst-*.md         # 5 аналитиков (Sonnet)
│   │   └── tester-*.md          # 6 тестеров (по типу проекта)
│   ├── scripts/             # Bash скрипты (14 шт)
│   │   ├── hype.sh              # Главный цикл с lock file
│   │   ├── detect-phase.sh      # Определение фазы (JSON output)
│   │   ├── common.sh            # Shared functions
│   │   ├── run-analysts.sh      # Параллельный запуск аналитиков
│   │   ├── run-executors.sh     # Параллельный запуск исполнителей
│   │   ├── run-senior-executor.sh # Review + merge workflow
│   │   ├── run-testers.sh       # Параллельный запуск тестеров
│   │   └── ...
│   └── commands/            # Slash-команды (/start, /status)
├── docs/                    # Документация
│   ├── architecture.md          # Как работает HYPE (для Doctor)
│   └── troubleshooting.md       # Известные проблемы (для Doctor)
├── templates/               # Шаблоны (config, SPEC, CLAUDE)
├── install.sh               # Глобальная установка
└── CHANGELOG.md             # История версий
```

## Фазы работы

```
INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → SMOKE_TEST → FINAL_REVIEW → DONE
                                              ↑                 ↓
                                              └── SMOKE_REVIEW ←┘ (если есть regression)
```

| Фаза | Агент | Что происходит |
|------|-------|----------------|
| INIT | Tech Writer | Собирает требования, создаёт SPEC.md (+ deep analysis для больших проектов) |
| PLANNING | Architect-Planner | Создаёт задачи в beads, расставляет deps |
| HELPERS | Analysts ×5 | Параллельный аудит плана |
| PLAN_REVIEW | Architect-Reviewer | Ревью добавлений от Analysts |
| IMPLEMENTATION | Executors + Auditor | Параллельная реализация + аудит задач |
| SMOKE_TEST | Testers ×6 | Параллельная проверка (по типу проекта) |
| SMOKE_REVIEW | Architect-QA | Обработка regression bugs |
| FINAL_REVIEW | Architect-QA | Проверка целостности |
| VERSIONING | Versioner | Обновление VERSION + CHANGELOG |
| DONE | — | Проект завершён |

### SMOKE_TEST Testers

| Tester | Model | Project Types | Focus |
|--------|-------|---------------|-------|
| tester-functional | sonnet | ALL | Must Have из SPEC.md |
| tester-visual | opus | web | UI через Playwright MCP |
| tester-api | haiku | api, web | Endpoints, статус коды |
| tester-cli | haiku | cli | Команды, --help |
| tester-regression | sonnet | library | Тестовый suite |
| tester-backend | sonnet | ALL | Запуск существующих тестов + генерация новых |

**Hard gate:** P0 bugs блокируют milestone:smoke-test-done → возврат в IMPLEMENTATION

**Regression detection:** Если баг был закрыт, но вернулся — testers reopenят его с `regression` label. Architect-QA анализирует регрессии: эскалирует модель, отправляет аналитикам, или понижает приоритет.

### Deep Analysis (INIT)

Для существующих проектов с >50 файлами кода и без хорошего README — автоматически запускается глубокий анализ через Claude (Opus). Tech Writer получает обогащённый контекст об архитектуре проекта.

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
```

### Testing config (`.hype/testing.yaml`)

Для web/api проектов — конфигурация тестирования:

```yaml
type: web                    # web | api | cli | library
build_command: npm run build # Команда сборки (опционально)
start_command: npm start     # Запуск dev-сервера
test_url: http://localhost:3000
health_check: /health        # Endpoint для проверки готовности
startup_timeout: 30          # Секунды на запуск сервера
```

Если файл отсутствует — создаётся P0 задача для Opus.

## Зависимости

**Обязательные:**
- beads — управление задачами
- claude — Claude Code CLI

**Опциональные:**
- gh — GitHub CLI (для PR workflow)
- gitleaks — secret detection (авто-установка при наличии GitHub)

## v2.0.0: Testing Infrastructure (завершено)

**Doctor** — диагностический инструмент архитектора внутри целевого проекта.

```bash
hype doctor          # Интерактивная диагностика
hype doctor --report # Только создать doctor-log
```

**Назначение:**
Когда у пользователя проблема с HYPE — Doctor собирает информацию и формирует структурированный отчёт (doctor-log). Пользователь передаёт этот отчёт архитектору HYPE, который понимает проблему и может её исправить.

**Workflow:**
1. Пользователь запускает `hype doctor`
2. Doctor спрашивает "что беспокоит"
3. Doctor собирает данные: bd stats, логи, процессы, фазу
4. Doctor формирует doctor-log с диагнозом
5. Пользователь передаёт doctor-log архитектору HYPE
6. (Опционально) Doctor предлагает runtime-фиксы для простых проблем

**Принципы:**
- ВСЕГДА создаёт doctor-log (главный результат)
- НЕ правит код — ни HYPE, ни проекта
- Runtime-фиксы через bd только с подтверждением (stuck tasks, orphaned labels)

**Знания Doctor:**
- `docs/architecture.md` — как работает HYPE
- `docs/troubleshooting.md` — известные проблемы и решения

## Планируется (после 2.0.0)

- OS Notifications (macOS/Linux)
- Webhook уведомления (Telegram, Slack)
- Автодокументация (README, API docs)
- Web UI для мониторинга

---

## ВАЖНО: Работа с файлами агентов

Файлы в `core/agents/*.md` — это **КОД ПРОЕКТА**, не инструкции для текущей сессии.

При работе над hype эти файлы редактируются как обычный код. Они станут инструкциями когда система будет установлена в целевой проект.
