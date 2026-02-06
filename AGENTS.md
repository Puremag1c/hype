# Agent Instructions

Инструкции по использованию beads для агента.

## Beads (bd)

```bash
bd ready              # Доступные задачи (без блокеров)
bd show <id>          # Детали задачи
bd update <id> --status in_progress  # Взять в работу
bd close <id>         # Закрыть задачу
bd stats              # Статистика проекта
bd blocked            # Заблокированные задачи
```

## Session Close Protocol

**КРИТИЧНО:** Работа НЕ завершена пока `git push` не прошёл.

```bash
# 1. Проверить что изменилось
git status

# 2. Закрыть выполненные задачи
bd close <id1> <id2> ...

# 3. Создать задачи на follow-up (если есть)
bd create --title="..." --type=task --priority=2

# 4. Синхронизировать и пушить
git add <files>
git commit -m "..."
bd sync
git push

# 5. Проверить
git status  # должен показать "up to date with origin"
```

**Правила:**
- НИКОГДА не останавливаться до git push
- НИКОГДА не говорить "готов к пушу когда захочешь" — ТЫ должен запушить
- Если push падает — разрешить и повторить
