# Echo Bot - Free Pascal

### Installing deltachat-rpc-server

For the bot to work, first `deltachat-rpc-server` program needs to be
installed and available in your `PATH`. To install it from source run:

```sh
cargo install --git https://github.com/deltachat/deltachat-core-rust/ deltachat-rpc-server
```

For more info and pre-built binaries check:
https://github.com/deltachat/deltachat-core-rust/tree/master/deltachat-rpc-server

### Compiling

You need Free Pascal Compiler 3.3.1+ (or Lazarus/fpcupdeluxe). Compile with:

```sh
fpc -Fu<fpc-units>/rtl -Fu<fpc-units>/rtl-objpas -Fu<fpc-units>/fcl-json \
    -Fu<fpc-units>/fcl-base -Fu<fpc-units>/fcl-process -Fu<fpc-units>/pthreads \
    echobot.lpr
```

Example with fpcupdeluxe:

```sh
FPC=/home/alexander/fpcupdeluxe_trunc/fpc
UNITS=$FPC/units/x86_64-linux
$FPC/bin/x86_64-linux/fpc \
    -Fu$UNITS/rtl -Fu$UNITS/rtl-objpas -Fu$UNITS/fcl-json \
    -Fu$UNITS/fcl-base -Fu$UNITS/fcl-process -Fu$UNITS/pthreads \
    echobot.lpr
```

### Using the bot

To run the bot, the first time you need to pass the credentials
as command line arguments:

```sh
./echobot $yourEmail $yourPassword
```

This will create a subdirectory called `accounts` in the current
working directory, this is where deltachat stores the state.  The
credentials will be stored there so further invocations do not need
them specified again:

```sh
./echobot
```

Open a chat with the bot address in your Delta Chat and write some messages
to test the bot.

### Explicit IMAP/SMTP configuration

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
