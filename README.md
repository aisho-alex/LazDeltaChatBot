# Echo Bot - Free Pascal

A Free Pascal port of the Delta Chat echo bot that talks to
[deltachat-rpc-server](https://github.com/chatmail/core/tree/master/deltachat-rpc-server)
via JSON-RPC over stdio.

On the wire the bot replies to `/start` with the literal string
`работаю`; every other text message from a real contact is forwarded to an
LLM (see "LLM replies" below) and the model's answer is sent back.

## LLM replies

The bot speaks the OpenAI-compatible `/v1/chat/completions` protocol, so it
works against any provider that exposes it — neuraldeep Hub, Drift, a local
Hermes gateway `api_server`, etc. The backend is selected purely via
environment variables; no code changes needed.

| Variable         | Description                                             | Default                          |
|------------------|---------------------------------------------------------|----------------------------------|
| `LLM_BASE_URL`   | API base URL                                            | `https://api.neuraldeep.ru/v1`   |
| `LLM_API_KEY`    | Bearer token (`sk-*` for Hub, `dft_*` for Drift, …)     | *(empty = LLM disabled)*         |
| `LLM_MODEL`      | Model name                                              | `gpt-oss-120b`                   |
| `LLM_SYSTEM`     | System prompt                                           | short Russian assistant prompt   |
| `LLM_TIMEOUT`    | Connect + I/O timeout, seconds                          | `120`                            |
| `LLM_MAX_TOKENS` | Max output tokens (reasoning models need headroom)      | `1024`                           |
| `LLM_TEMPERATURE`| Sampling temperature                                    | `0.2`                            |
| `LLM_HISTORY`    | Messages kept per chat (multi-turn context)             | `20`                             |
| `LLM_HISTORY_DIR`| Directory for per-chat history files (`<chatId>.json`)  | `history`                        |
| `LLM_RETRIES`    | Extra attempts on 429 / 5xx / network errors            | `2`                              |

Example (neuraldeep Hub, model with long context):

```sh
LLM_API_KEY=sk-... LLM_MODEL=qwen3.6-35b-a3b ./echobot
```

Behavior notes:

- `/start` always replies `работаю` without calling the LLM (health check).
- Chat commands (all except `/start` require an authorized contact):
  - `/model` — show the current per-chat model and the list from `GET /v1/models`
  - `/model <name>` — switch the model for this chat (persisted in
    `LLM_HISTORY_DIR/<chatId>.meta`, survives restarts)
  - `/search <query>` — web search; `/search tg <query>` — Telegram-channel
    search; `/search crawl <url>` — crawl a site (neuraldeep Search API,
    same key, separate quota; 5 results)
  - `/clear` — reset the chat context: for Hub backends wipes the in-memory
    history and deletes `<chatId>.json`; for Drift forgets the
    `conversation_id` so the next request starts a NEW session on the
    provider side
  - `/help` — list of commands
- When `LLM_BASE_URL` contains `drift`, the bot talks to Drift: it sends
  only the latest user prompt plus `conversation_id` (Drift keeps its own
  per-conversation memory in its DB, so sending history would duplicate it).
  A new conversation is created automatically on first use.
- The last `LLM_HISTORY` messages per chat are sent along, so multi-turn
  conversations have context. History is updated only on success, so a
  failed call never poisons the next request.
- History is persisted to `LLM_HISTORY_DIR/<chatId>.json` after every
  successful exchange (atomic write via `.tmp` + rename) and reloaded on
  startup, so conversations survive bot restarts (e.g. watchdog-triggered).
  A missing/corrupt file is logged and ignored — the chat starts fresh.
- Each chat pins an upstream worker via the `user: dcbot:<chatId>` field
  (session-sticky routing keeps the KV cache warm on the Hub).
- Rate limits (429) and transient errors are retried with a short backoff
  honoring `Retry-After`; client errors (401/400) are logged and skipped.
- If the model returns null/empty content (e.g. a reasoning model that
  spent the whole token budget), the request is retried once, then the
  error is logged with the raw response snippet.
- With no `LLM_API_KEY` the bot falls back to the plain echo behavior.

## Authorization

When `BOT_AUTH_CODE` is set, the bot only talks to contacts that have
authorized themselves once by sending:

    /start <кодовая фраза>

Authorized contact ids are stored in `accounts/authorized.txt`
(override with `BOT_AUTH_FILE`), so access survives restarts. The file
is gitignored and travels with the `accounts/` directory when you
deploy elsewhere.

| Variable        | Description                                     | Default                    |
|-----------------|-------------------------------------------------|----------------------------|
| `BOT_AUTH_CODE` | Secret phrase; empty = authorization disabled   | *(empty = open bot)*       |
| `BOT_AUTH_FILE` | File with authorized contact ids (one per line) | `accounts/authorized.txt`  |

Unauthorized contacts: `/start` alone gets a hint, a wrong code gets a
rejection, any other message is ignored silently. Authorized contacts
keep the usual behavior (`/start` → `работаю`, everything else → LLM).

## Build & run

Prerequisites:
- A POSIX shell with `curl` (Linux + macOS) or PowerShell 5+ (Windows)
- GNU Make
- Free Pascal Compiler ≥ 3.3.1 (with units `rtl`, `rtl-objpas`,
  `fcl-json`, `fcl-base`, `fcl-process`, `pthreads`)

```sh
cd freepascal
make run
```

`make` will:
1. Download a standalone `deltachat-rpc-server` binary for the current
   platform from the pinned GitHub release into `./.deps/` (cached on
   subsequent builds).
2. Compile `echobot` with the configured Free Pascal compiler.
3. Launch `./echobot` with `DC_RPC_SERVER` pointed at the downloaded
   binary.

Useful targets:

| Target             | What it does                                              |
|--------------------|-----------------------------------------------------------|
| `make deps`        | download `deltachat-rpc-server` (skipped if cached)       |
| `make build`       | compile `echobot`                                          |
| `make run`         | build + run with the right `DC_RPC_SERVER`                 |
| `make clean`       | remove `echobot` and intermediate files                    |
| `make clean-deps`  | also remove `./.deps/` (forces re-download)               |

Overriding defaults:

```sh
RPC_VERSION=v2.58.0 make deps     # use a newer release
```

With fpcupdeluxe at `/home/alexander/fpcupdeluxe_trunc/fpc`:

```sh
FPC=/home/alexander/fpcupdeluxe_trunc/fpc
FPC_UNITS="$FPC/units/x86_64-linux/rtl \
           $FPC/units/x86_64-linux/rtl-objpas \
           $FPC/units/x86_64-linux/fcl-json \
           $FPC/units/x86_64-linux/fcl-base \
           $FPC/units/x86_64-linux/fcl-process \
           $FPC/units/x86_64-linux/pthreads" \
  make run
```

The `FPC` variable may point at either an `fpc` binary directly or at an
fpcupdeluxe-style tree root (in which case the Makefile picks
`$FPC/bin/$(host-triple)/fpc` automatically). `FPC_UNITS` only needs
to be set when the default FPC install does not pick up all required
units from its own search paths.

## Configuring the bot account

The first time you run `./echobot`, pass the credentials as command line
arguments:

```sh
./echobot $yourEmail $yourPassword
```

This creates a subdirectory called `accounts` in the current working
directory. Delta Chat state and the bot's credentials are stored there,
so further invocations don't need them:

```sh
./echobot
```

Open a chat with the bot address in your Delta Chat and send `/start`.
The bot replies with `работаю`.

To deploy somewhere else, copy the whole `accounts/` directory along
with the binary — it contains everything the bot needs to reconnect.

## Explicit IMAP/SMTP configuration

Some providers (e.g. Yandex, Mail.ru, Outlook) require explicit server
settings. Set the following environment variables before the first run:

| Variable      | Description                          |
|---------------|--------------------------------------|
| `MAIL_SERVER` | IMAP hostname                        |
| `MAIL_PORT`   | IMAP port (usually 993)              |
| `MAIL_USER`   | IMAP username (defaults to addr)     |
| `SEND_SERVER` | SMTP hostname                        |
| `SEND_PORT`   | SMTP port (usually 587 or 465)       |
| `SEND_USER`   | SMTP username (defaults to addr)     |
| `SEND_PW`     | SMTP password (defaults to mail_pw)  |

Example for Yandex (enable IMAP in Yandex Mail settings and create an
app password at id.yandex.ru/security):

```sh
MAIL_SERVER=imap.yandex.com MAIL_PORT=993 \
SEND_SERVER=smtp.yandex.com SEND_PORT=465 \
./echobot $yourYandexAddr $yourAppPassword
```

> Note: Outlook.com / Office365 (`outlook.office365.com`) no longer
> works for bots. Microsoft has disabled Basic Auth (IMAP `AUTHENTICATE
> PLAIN`) for these accounts, and `deltachat-rpc-server` does not expose
> OAuth2, so the bot cannot log in there. Use a provider that still
> supports app-password Basic Auth (Yandex, Mail.ru, Gmail with an app
> password) or a chatmail relay instead.

## End-to-end encryption caveats

The bot's `accounts/<uuid>/dc.db` is the runtime database. For the bot
to send end-to-end encrypted replies to a contact, three things must
be true:

1. `force_encryption=0` in the `config` table. The upstream default
   is `1`, which makes `prefetch_should_download` discard plaintext
   DC messages entirely, so the bot won't even see them.
2. The bot has its own keypair in the `keypairs` table (generated the
   first time you `configure()` the account). On Linux this happens
   automatically when you pass credentials to the bot on first run.
3. For each contact the bot will send encrypted replies to, the
   contact's `fingerprint` column must be populated with the contact's
   public-key fingerprint from `public_keys`. The upstream main branch
   does **not** link these automatically when an Autocrypt header
   arrives, so for any newly seen contact you have to run a one-off
   SQL update:

   ```sql
   UPDATE contacts
   SET fingerprint = (SELECT pk.fingerprint FROM public_keys pk
                      WHERE pk.fingerprint IS NOT NULL LIMIT 1)
   WHERE id = :contact_id AND (fingerprint IS NULL OR fingerprint = '');
   ```

   until that upstream bug is fixed. The conversation will still be
   transport-encrypted via SMTP TLS in the meantime.
