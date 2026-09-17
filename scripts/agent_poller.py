#!/usr/bin/env python3
"""Poller: забирает задачи из очереди Delta Chat-бота и выполняет их Hermes.

Живёт на машине-воркере (ноутбук сейчас, ПК потом). Наружу ничего не открывает:
если очередь на другом хосте, работает через ssh — воркер сам стучится к боту,
а не наоборот.

Протокол очереди (см. dcqueue.pas):
  inbox/<id>.json                задача ждёт
  claimed/<id>.json.<worker>     захват: атомарный `mv`, поэтому два воркера
                                 физически не могут взять одну задачу
  outbox/<id>.json               результат, который бот отправит в чат
  done/broken-<id>.json          нечитаемые задачи (чтобы не спотыкаться вечно)
  files/<id>/...                 вложения задачи и файлы результата

Жизненный цикл одной задачи:
  claim (mv) → heartbeat (touch каждые 60 с) → скачать вложения → запустить
  `hermes chat -q` → выгрузить файлы из out/ → записать результат в outbox
  → снять claim (иначе бот через QUEUE_CLAIM_TIMEOUT вернёт задачу в inbox)

Использование:
  python3 agent_poller.py --worker laptop                    # цикл, опрос раз в 60 с
  python3 agent_poller.py --worker laptop --once --dry-run    # один проход, агент не запускается
  python3 agent_poller.py --worker pc --transport local --queue /opt/echo-bot/queue
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time

DEFAULT_HOST = "ubuntu@82.202.139.144"
DEFAULT_QUEUE = "/opt/echo-bot/queue"

PROMPT_TEMPLATE = """[Задача от Алекса через Delta Chat]

{task}

{context}{attachments}
Инструкция:
- Выполни задачу по-максимуму: инструменты, терминал, файлы, браузер — всё доступно.
- Ответь КОРОТКО (1-3 строки): это уйдёт в чат Delta Chat, канал медленный.
- Подробности, отчёты и большие тексты пиши ФАЙЛОМ в каталог: {outdir}
  Всё, что появится в этом каталоге, уедет в чат вложениями.
- Если что-то не получилось — скажи коротко, что именно.
"""


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Transport:
    """Доступ к каталогу очереди: напрямую (local) или через ssh."""

    def __init__(self, mode: str, host: str, queue: str) -> None:
        self.mode = mode
        self.host = host
        self.queue = queue.rstrip("/")
        self.ssh = shutil.which("ssh")
        if mode == "ssh" and not self.ssh:
            raise SystemExit("ssh не найден в PATH (нужен для --transport ssh)")

    # --- низкий уровень ---------------------------------------------------
    def _argv(self, args: list[str]) -> list[str]:
        if self.mode == "local":
            return args
        return [self.ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", self.host] + args

    def _run(self, args: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(self._argv(args), capture_output=True, text=True)

    def _run_bytes(self, args: list[str], stdin_bytes: bytes | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(self._argv(args), input=stdin_bytes, capture_output=True)

    def q(self, *parts: str) -> str:
        return "/".join([self.queue, *parts])

    # --- файловые операции ------------------------------------------------
    def listdir(self, rel: str) -> list[str]:
        r = self._run(["bash", "-lc", f"ls -1 {shlex.quote(self.q(rel))} 2>/dev/null"])
        if r.returncode != 0 or not r.stdout.strip():
            return []
        return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]

    def read_text(self, rel: str) -> str | None:
        r = self._run(["cat", self.q(rel)])
        return r.stdout if r.returncode == 0 else None

    def write_text(self, rel: str, text: str) -> bool:
        """Записать текст в файл очереди (результат задачи)."""
        data = text.encode("utf-8")
        if self.mode == "local":
            p = pathlib.Path(self.q(rel))
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            return True
        cmd = (f"mkdir -p {shlex.quote(os.path.dirname(self.q(rel)))} && "
               f"cat > {shlex.quote(self.q(rel))}")
        r = self._run_bytes(["bash", "-lc", cmd], stdin_bytes=data)
        return r.returncode == 0

    def fetch_file(self, rel: str, dest: pathlib.Path) -> bool:
        """Скачать файл (бинарно-безопасно: вложения бывают картинками)."""
        dest.parent.mkdir(parents=True, exist_ok=True)
        if self.mode == "local":
            src = pathlib.Path(self.q(rel))
            if not src.is_file():
                return False
            shutil.copy2(src, dest)
            return True
        r = self._run_bytes(["cat", self.q(rel)])
        if r.returncode != 0:
            return False
        dest.write_bytes(r.stdout)
        return True

    def push_file(self, rel: str, local: pathlib.Path) -> bool:
        if self.mode == "local":
            dest = pathlib.Path(self.q(rel))
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(local, dest)
            return True
        cmd = (f"mkdir -p {shlex.quote(os.path.dirname(self.q(rel)))} && "
               f"cat > {shlex.quote(self.q(rel))}")
        with open(local, "rb") as fh:
            r = subprocess.run(
                self._argv(["bash", "-lc", cmd]), stdin=fh, capture_output=True,
            )
        return r.returncode == 0

    # --- протокол очереди -------------------------------------------------
    def claim(self, filename: str, worker: str) -> bool:
        """Атомарный захват: mv внутри одной ФС — это rename, race невозможен."""
        r = self._run(["mv", self.q("inbox", filename), self.q("claimed", f"{filename}.{worker}")])
        return r.returncode == 0

    def heartbeat(self, filename: str, worker: str) -> None:
        self._run(["touch", self.q("claimed", f"{filename}.{worker}")])

    def drop_claim(self, filename: str, worker: str) -> None:
        """Снять claim после публикации результата. ВАЖНО: без этого бот решит,
        что воркер умер, и вернёт задачу в inbox — она выполнится второй раз."""
        self._run(["rm", "-f", self.q("claimed", f"{filename}.{worker}")])

    def release(self, filename: str, worker: str) -> None:
        """Вернуть задачу в inbox (например, битый JSON) — будет вторая попытка."""
        self._run(["mv", self.q("claimed", f"{filename}.{worker}"), self.q("inbox", filename)])

    def quarantine(self, filename: str, worker: str) -> None:
        """Убрать задачу из оборота (нечитаемые данные, чтобы не зациклиться)."""
        r = self._run(["bash", "-lc",
                       f"mkdir -p {shlex.quote(self.q('done'))} && "
                       f"mv {shlex.quote(self.q('claimed', f'{filename}.{worker}'))} "
                       f"{shlex.quote(self.q('done', f'broken-{filename}'))}"])
        if r.returncode != 0:
            self.drop_claim(filename, worker)


def heartbeat_loop(transport: Transport, filename: str, worker: str, stop: threading.Event) -> None:
    while not stop.wait(60):
        try:
            transport.heartbeat(filename, worker)
        except Exception as exc:  # noqa: BLE001
            log(f"heartbeat failed: {exc}")


def build_prompt(task: dict, workdir: pathlib.Path) -> str:
    ctx_lines = []
    for item in task.get("context") or []:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role", "?"))
        text = str(item.get("content") or item.get("text") or "").strip()
        if text:
            ctx_lines.append(f"{role}: {text}")
    context = "[Последние реплики чата]\n" + "\n".join(ctx_lines) + "\n\n" if ctx_lines else ""

    att_lines = []
    for att in task.get("attachments") or []:
        name = att.get("name") or os.path.basename(str(att.get("path", "")))
        local = workdir / "in" / name
        if local.is_file():
            att_lines.append(f"- {local} ({att.get('mime') or '?'})")
    attachments = ""
    if att_lines:
        attachments = "[Вложения задачи, уже скачаны локально]\n" + "\n".join(att_lines) + "\n\n"

    return PROMPT_TEMPLATE.format(
        task=str(task.get("task") or "").strip() or "(без текста — смотри вложения)",
        context=context,
        attachments=attachments,
        outdir=str(workdir / "out"),
    )


def run_agent(args: argparse.Namespace, prompt: str, workdir: pathlib.Path) -> tuple[bool, str]:
    cmd = [args.hermes, "chat", "-q", prompt]
    if args.model:
        cmd += ["-m", args.model]
    if args.yolo:
        cmd.append("--yolo")
    log(f"running hermes chat -q (промпт {len(prompt)} символов)")
    try:
        proc = subprocess.run(cmd, cwd=str(workdir), capture_output=True, text=True,
                              timeout=args.timeout)
    except subprocess.TimeoutExpired:
        return False, f"таймаут выполнения ({args.timeout} с)"
    except FileNotFoundError:
        return False, f"не найден Hermes CLI: {args.hermes} (укажи --hermes)"
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    if proc.returncode != 0:
        return False, (out + "\n" + err).strip() or f"exit code {proc.returncode}"
    return True, out


def handle_task(args: argparse.Namespace, transport: Transport, filename: str, raw: str) -> None:
    try:
        task = json.loads(raw)
    except json.JSONDecodeError as exc:
        log(f"битый JSON в {filename}: {exc} — убираю в done/broken-*")
        transport.quarantine(filename, args.worker)
        return

    task_id = str(task.get("id") or filename.split(".")[0])
    att_count = len(task.get("attachments") or [])
    log(f"взял {task_id} (worker={task.get('worker')}, вложений: {att_count})")

    if args.dry_run:
        log(f"dry-run, задача не выполняется: {json.dumps(task, ensure_ascii=False)[:300]}")
        transport.release(filename, args.worker)
        return

    stop = threading.Event()
    threading.Thread(
        target=heartbeat_loop, args=(transport, filename, args.worker, stop), daemon=True,
    ).start()

    workdir = pathlib.Path(tempfile.mkdtemp(prefix=f"task-{task_id}-", dir=args.workdir))
    (workdir / "in").mkdir(parents=True, exist_ok=True)
    (workdir / "out").mkdir(parents=True, exist_ok=True)
    published = False
    try:
        for att in task.get("attachments") or []:
            rel = str(att.get("path") or "")
            name = att.get("name") or os.path.basename(rel)
            if rel and transport.fetch_file(rel, workdir / "in" / name):
                log(f"вложение скачано: {name}")
            else:
                log(f"WARN: не удалось скачать вложение {rel}")

        ok, text = run_agent(args, build_prompt(task, workdir), workdir)

        attachments = []
        for produced in sorted((workdir / "out").glob("*")):
            if not produced.is_file():
                continue
            rel = f"files/{task_id}/out/{produced.name}"
            if transport.push_file(rel, produced):
                attachments.append({"path": rel, "name": produced.name, "mime": ""})
                log(f"результат выгружен: {produced.name}")
            else:
                log(f"WARN: не удалось выгрузить {produced.name}")

        result = {
            "id": task_id,
            "chat_id": task.get("chat_id"),
            "ok": ok,
            "worker": args.worker,
            "text": text[:3500],
            "attachments": attachments,
        }
        published = transport.write_text(
            f"outbox/{task_id}.json", json.dumps(result, ensure_ascii=False),
        )
        if published:
            log(f"готово {task_id}: ok={ok}, {len(text)} символов, вложений {len(attachments)}")
        else:
            log(f"ERROR: не удалось записать результат {task_id} — возвращаю задачу в inbox")
            transport.release(filename, args.worker)
    finally:
        stop.set()
        if published:
            transport.drop_claim(filename, args.worker)
        shutil.rmtree(workdir, ignore_errors=True)


def process_inbox(args: argparse.Namespace, transport: Transport) -> int:
    processed = 0
    for filename in sorted(transport.listdir("inbox")):
        if not filename.endswith(".json"):
            continue
        raw = transport.read_text(f"inbox/{filename}")
        if raw is None:
            continue
        try:
            task = json.loads(raw)
        except json.JSONDecodeError:
            task = {}
        owner = str(task.get("worker") or "any").lower()
        if owner not in ("any", args.worker):
            continue
        if not transport.claim(filename, args.worker):
            log(f"{filename}: задачу уже взял другой воркер")
            continue
        handle_task(args, transport, filename, raw)
        processed += 1
    return processed


def main() -> int:
    ap = argparse.ArgumentParser(description="Hermes worker для очереди задач Delta Chat-бота")
    ap.add_argument("--worker", required=True, help="имя воркера: laptop | pc")
    ap.add_argument("--transport", choices=["ssh", "local"], default="ssh")
    ap.add_argument("--host", default=DEFAULT_HOST, help="для ssh: user@host")
    ap.add_argument("--queue", default=DEFAULT_QUEUE, help="каталог очереди на хосте бота")
    ap.add_argument("--hermes", default="hermes", help="команда Hermes CLI на этой машине")
    ap.add_argument("--model", default="", help="передать -m <model> в hermes")
    ap.add_argument("--interval", type=int, default=60, help="период опроса, с")
    ap.add_argument("--timeout", type=int, default=1800, help="лимит на одну задачу, с")
    ap.add_argument("--workdir", default=None, help="каталог для временных файлов задач")
    ap.add_argument("--once", action="store_true", help="один проход и выход")
    ap.add_argument("--dry-run", action="store_true", help="не запускать агента")
    ap.add_argument("--yolo", action="store_true", help="передать --yolo в hermes")
    args = ap.parse_args()

    if args.workdir is None:
        args.workdir = tempfile.gettempdir()

    try:
        transport = Transport(args.transport, args.host, args.queue)
    except SystemExit as exc:
        log(str(exc))
        return 2

    log(f"worker={args.worker} transport={args.transport} host={args.host} queue={args.queue}")
    while True:
        try:
            n = process_inbox(args, transport)
            if n:
                log(f"обработано задач: {n}")
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR: проход не удался: {exc}")
        if args.once:
            break
        time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
