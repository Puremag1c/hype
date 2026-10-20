# Agent Instructions

## Session Close Protocol

**КРИТИЧНО:** Работа НЕ завершена пока `git push` не прошёл.

```bash
# 1. Проверить что изменилось
git status

# 2. Закоммитить и запушить
git add <files>
git commit -m "..."
git push

# 3. Проверить
git status  # должен показать "up to date with origin"
```

**Правила:**
- НИКОГДА не останавливаться до git push
- НИКОГДА не говорить "готов к пушу когда захочешь" — ТЫ должен запушить
- Push упал по сети — повторить. Non-fast-forward — `git pull --rebase` и снова push. Любая другая причина отказа (защищённая ветка, права) — остановиться и сообщить. Force-push запрещён
