#!/usr/bin/env python3
"""Install or remove Agent Monitor's Codex and Claude Code hooks."""

from __future__ import annotations

import argparse
import difflib
import json
import re
import shlex
import shutil
import sys
import time
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None

CODEX_HOOK_EVENTS = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
CLAUDE_HOOK_EVENTS = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
DESCRIPTION = "Report agent session state to Agent Monitor"
BEGIN = "# BEGIN Agent Monitor"
END = "# END Agent Monitor"
DISPATCHER_NAME = "agent-monitor-notify"
NOTIFY_BACKUP_NAME = "agent-monitor-original-notify.json"


def backup(path: Path) -> None:
    if path.exists():
        shutil.copy2(path, path.with_name(f"{path.name}.backup-{int(time.time())}"))


def hook_entry(helper: Path, event: str, subcommand: str) -> dict:
    command = f'"{helper}" {subcommand}'
    hook = {"type": "command", "command": command, "timeout": 3}
    if event != "SessionEnd":
        hook["async"] = True
    return {"matcher": "", "hooks": [hook]}


def is_monitor_hook(entry: dict) -> bool:
    return any("agent-monitor-helper" in hook.get("command", "") for hook in entry.get("hooks", []))


def show_plan(path: Path, before: str, after: str) -> None:
    print("".join(difflib.unified_diff(
        before.splitlines(keepends=True),
        after.splitlines(keepends=True),
        fromfile=str(path),
        tofile=str(path),
    )), end="")


def install_hooks(path: Path, helper: Path, events: list[str], subcommand: str, dry_run: bool, add_description: bool = False) -> None:
    original = path.read_text() if path.exists() else ""
    document = json.loads(original) if original else {}
    hooks = document.setdefault("hooks", {})
    if add_description:
        document.setdefault("description", DESCRIPTION)
    for event, entries in list(hooks.items()):
        hooks[event] = [entry for entry in entries if not is_monitor_hook(entry)]
        if not hooks[event]:
            del hooks[event]
    for event in events:
        entries = hooks.setdefault(event, [])
        entries.append(hook_entry(helper, event, subcommand))
    rendered = json.dumps(document, indent=2) + "\n"
    show_plan(path, original, rendered)
    if not dry_run:
        backup(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered)


def config_without_monitor(text: str) -> str:
    lines = text.splitlines()
    result, skipping = [], False
    for line in lines:
        if line == BEGIN:
            skipping = True
            continue
        if line == END:
            skipping = False
            continue
        if not skipping:
            result.append(line)
    rendered = "\n".join(result).strip("\n")
    return rendered + ("\n" if rendered else "")


def parsed_notify(text: str) -> list[str] | None:
    if not text:
        return None
    if tomllib is not None:
        value = tomllib.loads(text).get("notify")
        if value is None:
            return None
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise ValueError("notify must be an array of strings")
        return value
    match = re.search(r"(?m)^\s*notify\s*=\s*(\[[^\n]*\])\s*(?:#.*)?$", text)
    if not match:
        return None
    value = json.loads(match.group(1))
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError("notify must be an array of strings")
    return value


def remove_top_level_notify(text: str) -> str:
    return re.sub(r"(?m)^\s*notify\s*=\s*\[[^\n]*\]\s*(?:#.*)?\n?", "", text, count=1)


def insert_top_level(text: str, block: str) -> str:
    lines = text.splitlines(keepends=True)
    table_index = next((index for index, line in enumerate(lines) if line.lstrip().startswith("[")), len(lines))
    prefix = "".join(lines[:table_index]).strip("\n")
    suffix = "".join(lines[table_index:]).strip("\n")
    return "\n\n".join(part for part in (prefix, block.strip("\n"), suffix) if part) + "\n"


def write_dispatcher(path: Path, commands: list[list[str]], dry_run: bool) -> None:
    calls = []
    for command in commands:
        rendered = " ".join(shlex.quote(argument) for argument in command)
        calls.append(f"{rendered} \"$payload\" || true")
    content = "#!/bin/zsh\npayload=${1:-}\n" + "\n".join(calls) + "\n"
    if dry_run:
        print(f"Will write notification dispatcher {path} for {len(commands)} commands.")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o700)


def is_codex_computer_use(command: list[str]) -> bool:
    return bool(command) and Path(command[0]).name == "SkyComputerUseClient" and command[1:2] == ["turn-ended"]


def install_notify(path: Path, helper: Path, dry_run: bool) -> None:
    existing = path.read_text() if path.exists() else ""
    clean = config_without_monitor(existing)
    original = parsed_notify(clean)
    codex_directory = path.parent
    dispatcher = codex_directory / "bin" / DISPATCHER_NAME
    notify_backup = codex_directory / NOTIFY_BACKUP_NAME

    if original:
        if not dry_run:
            notify_backup.write_text(json.dumps(original, separators=(",", ":")) + "\n")
            notify_backup.chmod(0o600)
        clean = remove_top_level_notify(clean)
    elif notify_backup.exists():
        original = json.loads(notify_backup.read_text())

    helper_command = [str(helper), "codex-notify"]
    if original and is_codex_computer_use(original):
        installed = list(original)
        if "--previous-notify" in installed:
            index = installed.index("--previous-notify")
            previous = json.loads(installed[index + 1])
            write_dispatcher(dispatcher, [previous, helper_command], dry_run)
            installed[index + 1] = json.dumps([str(dispatcher)], separators=(",", ":"))
        else:
            installed.extend(["--previous-notify", json.dumps(helper_command, separators=(",", ":"))])
    elif original:
        write_dispatcher(dispatcher, [original, helper_command], dry_run)
        installed = [str(dispatcher)]
    else:
        installed = helper_command

    block = f"{BEGIN}\nnotify = {json.dumps(installed, separators=(',', ':'))}\n{END}\n"
    rendered = insert_top_level(clean, block)
    show_plan(path, existing, rendered)
    if not dry_run:
        backup(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered)


def uninstall_notify(path: Path, dry_run: bool) -> None:
    if not path.exists():
        return
    original = path.read_text()
    clean = config_without_monitor(original)
    dispatcher = path.parent / "bin" / DISPATCHER_NAME
    notify_backup = path.parent / NOTIFY_BACKUP_NAME
    if parsed_notify(clean) is None and notify_backup.exists():
        previous = json.loads(notify_backup.read_text())
        clean = insert_top_level(clean, f"notify = {json.dumps(previous, separators=(',', ':'))}\n")
    show_plan(path, original, clean)
    if not dry_run:
        if clean != original:
            backup(path)
            path.write_text(clean)
        dispatcher.unlink(missing_ok=True)
        notify_backup.unlink(missing_ok=True)


def uninstall_hooks(path: Path, dry_run: bool) -> None:
    if path.exists():
        document = json.loads(path.read_text())
        for event, entries in list(document.get("hooks", {}).items()):
            document["hooks"][event] = [entry for entry in entries if not is_monitor_hook(entry)]
            if not document["hooks"][event]:
                del document["hooks"][event]
        if document.get("description") == DESCRIPTION:
            document.pop("description")
        rendered = json.dumps(document, indent=2) + "\n"
        show_plan(path, path.read_text(), rendered)
        if not dry_run:
            backup(path)
            path.write_text(rendered)


def uninstall(path_hooks: Path, path_config: Path, claude_settings: Path, dry_run: bool) -> None:
    print("Will remove only entries created by Agent Monitor.")
    uninstall_hooks(path_hooks, dry_run)
    uninstall_hooks(claude_settings, dry_run)
    uninstall_notify(path_config, dry_run)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    codex = Path.home() / ".codex"
    hooks, config = codex / "hooks.json", codex / "config.toml"
    claude_settings = Path.home() / ".claude" / "settings.json"
    if args.action == "install":
        if not args.helper:
            parser.error("--helper is required for installation")
        install_hooks(hooks, args.helper.resolve(), CODEX_HOOK_EVENTS, "codex-hook", args.dry_run, add_description=True)
        install_notify(config, args.helper.resolve(), args.dry_run)
        install_hooks(claude_settings, args.helper.resolve(), CLAUDE_HOOK_EVENTS, "claude-hook", args.dry_run)
    else:
        uninstall(hooks, config, claude_settings, args.dry_run)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Configuration unchanged: {error}", file=sys.stderr)
        raise SystemExit(1)
