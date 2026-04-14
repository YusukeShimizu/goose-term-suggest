#!/usr/bin/env python3
"""Goose-powered shell command suggestions backed by McFly history."""

from __future__ import annotations

import argparse
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_HISTORY_DB = os.path.expanduser("~/Library/Application Support/McFly/history.db")
DEFAULT_MODEL = "gpt-5.4-nano-low"
DEFAULT_FAILURE_MODEL = "gpt-5.4-nano-medium"
GOOSE_TIMEOUT_SECONDS = 12
EXACT_LIMIT = 6
REPO_LIMIT = 8
RECENT_LIMIT = 4
_WHITESPACE_RE = re.compile(r"\s+")
_CODE_BLOCK_RE = re.compile(r"```(?:[^\n]*\n)?(.*?)```", re.DOTALL)
LOW_SIGNAL_COMMANDS = (
    "git status",
    "git diff",
    "git log",
    "git branch",
    "git remote",
    "ls",
    "ls -la",
    "pwd",
)
REJECTED_SUGGESTION_PREFIXES = (
    "sudo ",
    "rm -rf",
    "git reset --hard",
    "git clean -fd",
)
META_COMMAND_PREFIXES = (
    "goose",
    "codex",
    "claude",
    "opencode",
)


@dataclass(frozen=True)
class HistoryEntry:
    cmd: str
    uses: int
    last_run: int
    scope: str


@dataclass(frozen=True)
class RecentEntry:
    cmd: str
    exit_code: int
    when_run: int
    scope: str


def _normalize_cmd(cmd: str) -> str:
    return _WHITESPACE_RE.sub(" ", cmd.strip())


def _is_ignored_command(cmd: str) -> bool:
    normalized = _normalize_cmd(cmd)
    if not normalized:
        return True

    exact_ignored = {
        "cd",
        "ls",
        "ls -la",
        "pwd",
        "clear",
        "history",
        "exit",
        "source ~/.zshrc",
        "exec zsh",
        "code .",
        "zed .",
    }
    if normalized in exact_ignored:
        return True

    prefix_ignored = (
        "cd ",
        "which ",
        "@goose",
        "@g ",
        "goose",
        "goose ",
        "goose term",
        "codex",
        "codex ",
        "claude",
        "claude ",
        "opencode",
        "opencode ",
    )
    return normalized.startswith(prefix_ignored)


def _is_low_signal_command(cmd: str) -> bool:
    normalized = _normalize_cmd(cmd)
    return normalized in LOW_SIGNAL_COMMANDS or normalized.startswith(("find ", "rg ", "grep "))


def query_history(
    db_path: str,
    cwd: str,
    repo_root: str,
) -> tuple[list[HistoryEntry], list[HistoryEntry], list[RecentEntry], list[RecentEntry]]:
    path = Path(db_path).expanduser()
    if not path.exists():
        return [], [], [], []

    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        exact = _fetch_history_scope(
            conn,
            """
            SELECT cmd, COUNT(*) AS uses, MAX(when_run) AS last_run
            FROM commands
            WHERE exit_code = 0 AND dir = ?
            GROUP BY cmd
            LIMIT ?
            """,
            (cwd, EXACT_LIMIT * 6),
            "pwd",
            EXACT_LIMIT,
        )
        repo = []
        if repo_root:
            repo = _fetch_history_scope(
                conn,
                """
                SELECT cmd, COUNT(*) AS uses, MAX(when_run) AS last_run
                FROM commands
                WHERE exit_code = 0 AND dir LIKE ? AND dir != ?
                GROUP BY cmd
                LIMIT ?
                """,
                (f"{repo_root}%", cwd, REPO_LIMIT * 6),
                "repo",
                REPO_LIMIT,
            )
        recent_exact = _fetch_recent_scope(
            conn,
            """
            SELECT cmd, exit_code, when_run
            FROM commands
            WHERE dir = ?
            ORDER BY when_run DESC
            LIMIT ?
            """,
            (cwd, RECENT_LIMIT * 4),
            "pwd",
            RECENT_LIMIT,
        )
        recent_repo = []
        if repo_root:
            recent_repo = _fetch_recent_scope(
                conn,
                """
                SELECT cmd, exit_code, when_run
                FROM commands
                WHERE dir LIKE ? AND dir != ?
                ORDER BY when_run DESC
                LIMIT ?
                """,
                (f"{repo_root}%", cwd, RECENT_LIMIT * 6),
                "repo",
                RECENT_LIMIT,
            )
        return exact, _dedupe_against(repo, {entry.cmd for entry in exact}), recent_exact, recent_repo
    finally:
        conn.close()


def _fetch_history_scope(
    conn: sqlite3.Connection,
    query: str,
    params: tuple[object, ...],
    scope: str,
    limit: int,
) -> list[HistoryEntry]:
    rows = conn.execute(query, params).fetchall()
    entries: list[HistoryEntry] = []
    for row in rows:
        cmd = _normalize_cmd(row["cmd"])
        if _is_ignored_command(cmd):
            continue
        entries.append(
            HistoryEntry(
                cmd=cmd,
                uses=int(row["uses"] or 0),
                last_run=int(row["last_run"] or 0),
                scope=scope,
            )
        )
    entries.sort(key=lambda entry: (_is_low_signal_command(entry.cmd), -entry.uses, -entry.last_run))
    return entries[:limit]


def _fetch_recent_scope(
    conn: sqlite3.Connection,
    query: str,
    params: tuple[object, ...],
    scope: str,
    limit: int,
) -> list[RecentEntry]:
    rows = conn.execute(query, params).fetchall()
    entries: list[RecentEntry] = []
    seen: set[str] = set()
    for row in rows:
        cmd = _normalize_cmd(row["cmd"])
        if _is_ignored_command(cmd) or cmd in seen:
            continue
        seen.add(cmd)
        entries.append(
            RecentEntry(
                cmd=cmd,
                exit_code=int(row["exit_code"] or 0),
                when_run=int(row["when_run"] or 0),
                scope=scope,
            )
        )
        if len(entries) >= limit:
            break
    return entries


def _dedupe_against(entries: Iterable[HistoryEntry], seen: set[str]) -> list[HistoryEntry]:
    deduped: list[HistoryEntry] = []
    for entry in entries:
        if entry.cmd in seen:
            continue
        seen.add(entry.cmd)
        deduped.append(entry)
    return deduped


def default_candidate(
    cwd: str,
    repo_root: str,
    exact: list[HistoryEntry],
    repo: list[HistoryEntry],
) -> str:
    if exact:
        return exact[0].cmd
    if repo:
        return repo[0].cmd
    return "git status" if repo_root and _is_git_directory(cwd) else "ls -la"


def _is_git_directory(cwd: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


def build_candidate_pool(
    partial: str,
    last_command: str,
    last_status: int,
    exact: list[HistoryEntry],
    repo: list[HistoryEntry],
    recent_exact: list[RecentEntry],
    recent_repo: list[RecentEntry],
    fallback: str,
) -> list[str]:
    candidates: list[str] = []

    def add(cmd: str) -> None:
        normalized = _normalize_cmd(cmd)
        if not normalized or _is_ignored_command(normalized) or _is_rejected_suggestion(normalized, partial):
            return
        if normalized not in candidates:
            candidates.append(normalized)

    if last_command and last_status == 0:
        add(last_command)
    for entry in recent_exact:
        add(entry.cmd)
    for entry in exact:
        add(entry.cmd)
    for entry in recent_repo:
        add(entry.cmd)
    for entry in repo:
        add(entry.cmd)
    add(fallback)

    partial_text = partial.strip()
    if partial_text:
        filtered = [cmd for cmd in candidates if cmd.startswith(partial_text)]
        return filtered or [partial_text]
    return candidates[:6] or [fallback]


def build_prompt(
    cwd: str,
    repo_root: str,
    partial: str,
    last_command: str,
    last_status: int,
    exact: list[HistoryEntry],
    repo: list[HistoryEntry],
    recent_exact: list[RecentEntry],
    recent_repo: list[RecentEntry],
    candidates: list[str],
) -> str:
    repo_text = repo_root or "(none)"
    partial_text = partial.strip()
    instructions = [
        "Return exactly one shell command.",
        "Output one line only.",
        "Do not include markdown, quotes, bullets, or explanations.",
        "The active Goose terminal session already contains the very recent shell history for this terminal.",
        "Use that terminal-session context together with the McFly history below.",
        "Prefer concrete commands the user is likely to run next.",
        "Do not default to git status unless repo inspection is clearly the strongest signal.",
        "Do not suggest agent launcher commands such as goose, codex, claude, or opencode unless the user already typed that prefix.",
    ]
    if last_command:
        instructions.append("Use the last command and its exit status heavily.")
    if last_status != 0:
        instructions.append(
            "The previous command failed. Prefer a repair, retry with better flags, or a targeted follow-up over generic inspection."
        )
    if partial_text:
        instructions.append(f"The command must start with this prefix: {partial_text}")
    else:
        instructions.append("Suggest the most likely next command the user wants to run right now.")

    prompt = [
        "You are generating a zsh command suggestion.",
        *instructions,
        "",
        f"Current directory: {cwd}",
        f"Repository root: {repo_text}",
    ]
    if last_command:
        prompt.extend(
            [
                "",
                f"Last command: {last_command}",
                f"Last command exit status: {last_status}",
                "Interpret exit status 0 as success and non-zero as failure.",
            ]
        )
    if recent_exact:
        prompt.extend(["", "Recent McFly commands in this exact directory:"])
        prompt.extend(f"- {entry.cmd} (exit={entry.exit_code})" for entry in recent_exact)
    if exact:
        prompt.extend(["", "Successful McFly commands often used in this exact directory:"])
        prompt.extend(f"- {entry.cmd} (uses={entry.uses})" for entry in exact)
    if recent_repo and not exact:
        prompt.extend(["", "Recent McFly commands elsewhere in this repository:"])
        prompt.extend(f"- {entry.cmd} (exit={entry.exit_code})" for entry in recent_repo)
    if repo and not exact:
        prompt.extend(["", "Successful McFly commands often used in this repository:"])
        prompt.extend(f"- {entry.cmd} (uses={entry.uses})" for entry in repo)
    prompt.extend(["", "Candidate fallbacks from McFly history:"])
    prompt.extend(f"- {candidate}" for candidate in candidates)
    prompt.extend(
        [
            "",
            "Fallback policy:",
            "- Prefer a repair-oriented next step after failures.",
            "- Prefer McFly-backed commands when they fit.",
            "- If nothing stronger exists, pick the best candidate fallback.",
        ]
    )
    return "\n".join(prompt)


def run_goose_term(prompt: str, model: str) -> tuple[str, str]:
    if "AGENT_SESSION_ID" not in os.environ:
        return "", "missing AGENT_SESSION_ID"

    cmd = ["goose", "term", "run", prompt]
    env = os.environ.copy()
    env["GOOSE_MODEL"] = model
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=GOOSE_TIMEOUT_SECONDS,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return "", str(exc)

    if proc.returncode != 0:
        return "", proc.stderr.strip()
    return proc.stdout.strip(), ""


def _is_rejected_suggestion(cmd: str, partial: str) -> bool:
    normalized = _normalize_cmd(cmd)
    if any(normalized.startswith(prefix) for prefix in REJECTED_SUGGESTION_PREFIXES):
        return True
    if partial:
        return False
    return normalized in META_COMMAND_PREFIXES or any(normalized.startswith(f"{prefix} ") for prefix in META_COMMAND_PREFIXES)


def sanitize_suggestion(raw: str, partial: str) -> str:
    text = raw.strip()
    if not text:
        return ""

    block_match = _CODE_BLOCK_RE.search(text)
    if block_match:
        text = block_match.group(1).strip()

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        return ""

    line = lines[0]
    line = line.strip("`")
    line = re.sub(r"^\s*command\s*:\s*", "", line, flags=re.IGNORECASE)

    if not line or line.startswith(("-", "*")):
        return ""
    if partial and not line.startswith(partial):
        return ""
    if _is_rejected_suggestion(line, partial):
        return ""
    return line


def suggest_command(
    cwd: str,
    repo_root: str,
    history_db: str,
    model: str,
    failure_model: str,
    partial: str,
    last_command: str,
    last_status: int,
) -> str:
    exact, repo, recent_exact, recent_repo = query_history(history_db, cwd, repo_root)
    fallback = default_candidate(cwd, repo_root, exact, repo)

    if not shutil_which("goose"):
        return _apply_partial_fallback(fallback, partial)

    candidates = build_candidate_pool(
        partial,
        last_command,
        last_status,
        exact,
        repo,
        recent_exact,
        recent_repo,
        fallback,
    )
    prompt = build_prompt(
        cwd,
        repo_root,
        partial,
        last_command,
        last_status,
        exact,
        repo,
        recent_exact,
        recent_repo,
        candidates,
    )
    selected_model = failure_model if last_status != 0 else model
    raw, _ = run_goose_term(prompt, selected_model)
    suggestion = sanitize_suggestion(raw, partial)
    if suggestion:
        return suggestion
    return candidates[0] if candidates else _apply_partial_fallback(fallback, partial)


def _apply_partial_fallback(fallback: str, partial: str) -> str:
    partial_text = partial.strip()
    if partial_text and fallback.startswith(partial_text):
        return fallback
    return fallback if not partial_text else partial_text


def shutil_which(binary: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        candidate = Path(directory) / binary
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate Goose-powered shell command suggestions.")
    parser.add_argument("--pwd", default=os.getcwd(), help="Current working directory")
    parser.add_argument("--repo-root", default="", help="Repository root for the current directory")
    parser.add_argument("--history-db", default=DEFAULT_HISTORY_DB, help="Path to the McFly SQLite database")
    parser.add_argument("--model", default=os.environ.get("GOOSE_TERM_SUGGEST_MODEL", DEFAULT_MODEL))
    parser.add_argument(
        "--failure-model",
        default=os.environ.get("GOOSE_TERM_SUGGEST_FAILURE_MODEL", DEFAULT_FAILURE_MODEL),
        help="Model to use when the last command failed",
    )
    parser.add_argument("--partial", default="", help="Partial command prefix to continue")
    parser.add_argument("--last-command", default="", help="Last shell command that ran before the prompt")
    parser.add_argument("--last-status", type=int, default=0, help="Exit status for the last command")
    parser.add_argument("--print-debug", action="store_true", help="Print debug data to stderr")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    cwd = os.path.abspath(os.path.expanduser(args.pwd))
    repo_root = os.path.abspath(os.path.expanduser(args.repo_root)) if args.repo_root else ""
    suggestion = suggest_command(
        cwd,
        repo_root,
        args.history_db,
        args.model,
        args.failure_model,
        args.partial,
        _normalize_cmd(args.last_command),
        args.last_status,
    )
    if args.print_debug:
        exact, repo, recent_exact, recent_repo = query_history(args.history_db, cwd, repo_root)
        print(f"cwd={cwd}", file=sys.stderr)
        print(f"repo_root={repo_root}", file=sys.stderr)
        print(f"last_command={args.last_command!r} last_status={args.last_status}", file=sys.stderr)
        print(f"agent_session={'AGENT_SESSION_ID' in os.environ}", file=sys.stderr)
        print(
            f"selected_model={args.failure_model if args.last_status != 0 else args.model}",
            file=sys.stderr,
        )
        print(f"exact={len(exact)} repo={len(repo)} recent_exact={len(recent_exact)} recent_repo={len(recent_repo)}", file=sys.stderr)
        print(f"suggestion={suggestion}", file=sys.stderr)
    if suggestion:
        print(suggestion)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
