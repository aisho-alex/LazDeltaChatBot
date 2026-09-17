# Воркер на Windows-ПК

Инструкция: поднять на Windows-ПК исполнителя задач из очереди Delta Chat-бота.
После этого `/agent pc <задача>` из Delta Chat выполняется на ПК (Hermes с инструментами,
терминалом и браузером), а в чат возвращаются 1–3 строки ответа и файлы-вложения.

Схема:

```
Delta Chat  ←→  бот на 82.202.139.144  ←→  очередь /opt/echo-bot/queue
                                              ↑ ssh (исходящий с ПК)
                                          воркер на Windows-ПК:
                                          agent_poller.py → hermes chat -q
```

ПК выключен — задачи не теряются: лежат в `inbox/` и ждут. Воркер сам стучится к
серверу по ssh, входящих портов на ПК открывать не нужно.

---

## 0. Что понадобится

- Windows 10 x64, ~5 ГБ свободного места, интернет.
- Права администратора (для установки зависимостей; uv и Python ставятся без админа).
- Клиент OpenSSH в Windows (в Win10 1809+ встроен): проверка `ssh -V`.
  Если нет — Параметры → Приложения → Дополнительные компоненты → «Клиент OpenSSH».
- Пароль пользователя Windows под рукой (нужен для запуска задачи Планировщика
  без входа в систему; см. шаг 6).

Всё, что создаётся на ПК, живёт в двух местах и удаляется целиком:

- `C:\HermesWorker\` — репозиторий с воркером, лог-обёртка, логи;
- `%LOCALAPPDATA%\hermes\` — установленный Hermes (Python, venv, конфиг, ключи API).

Плюс одна задача в Планировщике заданий (`HermesWorker`) и ключ в
`~/.ssh/authorized_keys` на сервере.

---

## 1. SSH-доступ к очереди

Ключ без пароля — обязательное условие: поллер запускает ssh в режиме
`BatchMode=yes`, и на запрос пароля он не ответит.

```powershell
# ключ (Enter на вопрос о пароле — пароля быть не должно)
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\dc_worker -N '""'

# публичная часть — на сервер
type $env:USERPROFILE\.ssh\dc_worker.pub | ssh ubuntu@82.202.139.144 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Псевдоним в `%USERPROFILE%\.ssh\config` (чтобы не трогать существующие ключи и не
писать в командах ни ключ, ни хост):

```
Host dcbothost
    HostName 82.202.139.144
    User ubuntu
    IdentityFile ~/.ssh/dc_worker
    IdentitiesOnly yes
```

Проверка (должно ответить `ok` и НЕ спросить пароль):

```powershell
ssh -o BatchMode=yes dcbothost "echo ok; ls /opt/echo-bot/queue"
```

В списке должны быть каталоги `inbox  claimed  outbox  done  files`.

---

## 2. Установка Hermes

Установщик для Windows — PowerShell-скрипт `install.ps1` (`install.sh` на Windows
специально отказывается работать и отправляет к нему).

```powershell
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1' -OutFile "$env:TEMP\install.ps1"
& "$env:TEMP\install.ps1"
```

Что он делает сам (проверено по коду установщика):

- ставит `uv` и через него Python 3.11 — без прав администратора;
- ставит git (portable) и прописывает `HERMES_GIT_BASH_PATH`;
- ставит Node.js 22 (через winget, иначе zip-архивом в `%LOCALAPPDATA%\hermes\node`),
  ripgrep, ffmpeg;
- разворачивает репозиторий в `%LOCALAPPDATA%\hermes\hermes-agent`, создаёт venv
  `...\hermes-agent\venv` и добавляет `venv\Scripts` в PATH пользователя — там же
  появляется `hermes.exe`;
- тянет Chromium для браузерных инструментов (`npx playwright install chromium`,
  ~300 МБ). Если браузер воркеру не нужен — шаг можно не повторять вручную;
- в конце предлагает мастер настройки. Если запускаешь без интерактивного мастера —
  `& "$env:TEMP\install.ps1" -SkipSetup`.

Дальше — модель и ключи (мастер или вручную):

```powershell
hermes model          # выбор провайдера/модели
hermes doctor         # проверка окружения
hermes config set approvals.mode manual   # у воркера approvals не нужны: их снимает --yolo
```

`approvals.mode: manual` оставляем сознательно: подтверждения должны работать в
твоих интерактивных сессиях. Воркер запускается с `--yolo` (см. шаг 4) — иначе
неинтерактивный прогон упрётся в запрос подтверждения опасной команды, отвечать
некому, через 60 с придёт отказ, и задача вернётся как «не выполнена».

---

## 3. Код воркера на ПК

Поллер — один файл на стандартной библиотеке Python, без зависимостей.

```powershell
New-Item -ItemType Directory -Force C:\HermesWorker | Out-Null
cd C:\HermesWorker

# вариант А: из репозитория
git clone https://github.com/aisho-alex/LazDeltaChatBot.git

# вариант Б: только файл воркера (достаточно)
mkdir C:\HermesWorker\worker
# скопировать туда scripts/agent_poller.py из репозитория
```

Python берём тот, что поставил Hermes (отдельный ставить не нужно):

```powershell
$py = "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\python.exe"
& $py --version      # Python 3.11.x
```

---

## 4. Проверки до автозапуска

```powershell
cd C:\HermesWorker\LazDeltaChatBot

# 1) связь и права на очередь
& $py scripts\agent_poller.py --worker pc --host dcbothost --check

# 2) один проход без запуска агента: видно, как задача забирается и возвращается
& $py scripts\agent_poller.py --worker pc --host dcbothost --once --dry-run

# 3) сам Hermes в неинтерактивном режиме (важно: с --yolo)
hermes chat -Q -q "ответь одним словом: тест" --yolo
```

Ожидаемое: `--check` → `связь : ok`, `запись : ok`; dry-run → задача уходит обратно
в `inbox`; Hermes отвечает одной строкой без запросов подтверждения.

Затем реальный боевой запуск (в отдельном окне):

```powershell
& $py -u scripts\agent_poller.py --worker pc --host dcbothost --yolo --interval 30
```

и из Delta Chat: `/agent pc посчитай 2+2` → в чат приходит «4».

Ключи поллера:

| Ключ | Зачем |
|------|-------|
| `--worker pc` | имя воркера; берёт задачи с `worker=pc` и `worker=any` |
| `--host dcbothost` | псевдоним ssh из шага 1 |
| `--yolo` | снять подтверждения у агента (обязательно для автономной работы) |
| `--interval 30` | период опроса очереди, секунд |
| `--once` | один проход и выход |
| `--dry-run` | не запускать агента |
| `--check` | диагностика и выход |
| `--timeout 1800` | лимит на одну задачу, секунд |
| `--hermes <путь>` | если `hermes` не виден в PATH |

---

## 5. Автозапуск: обёртка и Планировщик

Планировщик не умеет перенаправлять вывод, поэтому запускаем через `.cmd`-обёртку —
она же перезапускает воркер, если тот упал, и ведёт лог.

`C:\HermesWorker\run_worker.cmd` (сохранить в UTF-8 **без BOM**):

```bat
@echo off
chcp 65001 >nul
set PY=%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\python.exe
set REPO=C:\HermesWorker\LazDeltaChatBot
set LOG=C:\HermesWorker\worker.log

cd /d %REPO%
:loop
echo [%DATE% %TIME%] worker start >> "%LOG%"
"%PY%" -u scripts\agent_poller.py --worker pc --host dcbothost --yolo --interval 30 >> "%LOG%" 2>&1
echo [%DATE% %TIME%] worker exited, restart in 10s >> "%LOG%"
timeout /t 10 /nobreak >nul
goto loop
```

Задача в Планировщике (командная строка, запускать от имени администратора):

```cmd
schtasks /Create /TN "HermesWorker" /TR "cmd.exe /c C:\HermesWorker\run_worker.cmd" ^
  /SC ONSTART /DELAY 0000:30 /RU "%USERNAME%" /RP * /F
```

`/RP *` спросит пароль пользователя: он нужен, чтобы задача работала без входа в
систему. Если хранить пароль не хочется — замени `/SC ONSTART` на `/SC ONLOGON`
(тогда воркер живёт, пока пользователь в системе).

В свойствах задачи (Планировщик → HermesWorker) довести:

- «Выполнять вне зависимости от регистрации пользователя» — включено (вход в систему не нужен);
- «Перезапускать задачу при сбое» — каждые 1 мин, до 3 раз;
- «Остановить задачу, если она выполняется дольше…» — **выключить** (воркер живёт постоянно);
- «При пропуске запуска — выполнить как можно скорее» — включено.

Питание: ПК не должен засыпать, иначе задачи копятся до пробуждения.

```cmd
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 15
```

---

## 6. Чек-лист приёмки

1. `ssh -o BatchMode=yes dcbothost "ls /opt/echo-bot/queue"` — отвечает без пароля.
2. `--check` → `связь : ok`, `запись : ok`.
3. `--once --dry-run` — задача берётся и возвращается в `inbox`.
4. Из Delta Chat `/agent pc посчитай 2+2` → «4».
5. Перезагрузка ПК → через 30 с воркер поднялся сам, `/agent pc ...` снова работает.
6. `C:\HermesWorker\worker.log` — видно `worker start` и цикл опроса каждые 30 с.

---

## 7. Грабли (Windows-специфичные)

- **Подтверждения.** Без `--yolo` задача вернётся как «не выполнена», а в тексте будет
  `DANGEROUS COMMAND ... Timeout - denying command`. Подтверждения в интерактивных
  сессиях при этом остаются как были — `--yolo` действует только на запуск воркера.
- **Кириллица.** Воркер читает вывод Hermes как UTF-8 (иначе на русской Windows
  ответы приезжали кракозябрами), но `.cmd`-обёртку сохраняй в UTF-8 без BOM и с
  `chcp 65001`, иначе поедут пути в логе.
- **Путь.** `C:\HermesWorker` — короткий, без пробелов и кириллицы. Так меньше
  поводов для кавычек в Планировщике.
- **`hermes` не найден.** Воркер ищет CLI по PATH (в том числе `hermes.exe/.cmd`);
  если не находит — запусти с `--hermes "%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\hermes.exe"`.
- **Длина промпта.** Промпт задачи передаётся аргументом командной строки, у Windows
  лимит ~32 КБ; контекст к задаче поэтому короткий (3 последние реплики чата) —
  остальное задача должна добрать сама.
- **Два воркера и `worker=any`.** Задачи с `any` забирает тот, кто опросил первым.
  Пока на ноуте тоже запущен поллер, адресуй ПК явно: `/agent pc …`; ноут лучше
  держать выключенным, когда за ним работает человек.
- **Браузер.** Chromium (~300 МБ) ставится установщиком Hermes; если браузерные
  задачи не нужны, качать его не обязательно.
- **Входящие порты** открывать не нужно, нужен только исходящий ssh (22) на
  82.202.139.144.

---

## 8. Откат

```cmd
schtasks /Delete /TN "HermesWorker" /F
rmdir /s /q C:\HermesWorker
```

Плюс убрать строку ключа из `~/.ssh/authorized_keys` на сервере (если воркер больше
не нужен) и при желании удалить `%LOCALAPPDATA%\hermes`.
