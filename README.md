# Echo Bot - Free Pascal

A Free Pascal port of the Delta Chat echo bot that talks to
[deltachat-rpc-server](https://github.com/chatmail/core/tree/master/deltachat-rpc-server)
via JSON-RPC over stdio.

On the wire the bot replies to `/start` with the literal string
`работаю`; other incoming messages are ignored.

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
