# Changelog

## 1.0.0 — 2026-10-19
- Реальная очистка включена по умолчанию (проверено на живом маке: +47 ГБ). Тестовый режим: флаг `-dry-run`.
- Точечные цифры: убран серый «прямоугольник» вокруг чисел на ярких карточках.
First release.

### RU
- Три уровня безопасности (зелёный / жёлтый / красный) и режимы Быстро / Глубоко / Всё.
- Каталог из 37 правил: система и браузеры, Adobe (After Effects, Premiere, Media Encoder, CEP-панели), Blender, DaVinci Resolve, Final Cut, Xcode (DerivedData, DeviceSupport, симуляторы, архивы), Homebrew, npm/yarn/pnpm/pip/uv, `node_modules`, Docker, HuggingFace, Ollama, LM Studio, Корзина, Загрузки.
- Инструменты: большие файлы, дубликаты (размер → частичный хеш → SHA-256), старые файлы, Загрузки с фильтрами, `node_modules`.
- SafetyGuard: запрещённые папки, защита от симлинков, повторная проверка перед удалением, «не менялось после скана»; запущенные программы блокируют своё правило.
- Очистка с пробным прогоном, историей и графиком; настройки (исключения, напоминание, порог больших файлов, зелёный в Корзину, язык RU/EN).
- Онбординг с Full Disk Access, меню-бар, CLI `doclean`.
- Без Developer ID: инструкция первого запуска в README.

### EN
- Three safety tiers (green / yellow / red) and Quick / Deep / Everything modes.
- 37-rule catalog: system and browsers, Adobe (After Effects, Premiere, Media Encoder, CEP panels), Blender, DaVinci Resolve, Final Cut, Xcode (DerivedData, DeviceSupport, simulators, archives), Homebrew, npm/yarn/pnpm/pip/uv, `node_modules`, Docker, HuggingFace, Ollama, LM Studio, Trash, Downloads.
- Tools: large files, duplicates (size → partial hash → SHA-256), old files, Downloads with filters, `node_modules`.
- SafetyGuard: forbidden folders, symlink protection, re-check before removal, "unchanged since scan"; running apps block their rule.
- Cleaning with dry run, history and chart; settings (exclusions, reminder, large-file threshold, green to Trash, RU/EN).
- Onboarding with Full Disk Access, menu bar, `doclean` CLI.
- Not signed with a Developer ID: first-launch instructions in the README.
