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
DEFAULT_MODEL = "gpt-5-nano"
GOOSE_TIMEOUT_SECONDS = 12
EXACT_LIMIT = 15
REPO_LIMIT = 25
_WHITESPACE_RE = re.compile(r"\s+")
_CODE_BLOCK_RE = re.compile(r"```(?:[^\n]*\n)?(.*?)```", re.DOTALL)


@dataclass(frozen=True)
class HistoryEntry:
    cmd: str
    uses: int
    last_run: int
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
        "goose term",
        "codex",
        "codex ",
    )
    return normalized.startswith(prefix_ignored)


def query_history(db_path: str, cwd: str, repo_root: str) -> tuple[list[HistoryEntry], list[HistoryEntry]]:
    path = Path(db_path).expanduser()
    if not path.exists():
        return [], []

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
            ORDER BY uses DESC, last_run DESC
            LIMIT ?
            """,
            (cwd, EXACT_LIMIT * 4),
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
                ORDER BY uses DESC, last_run DESC
                LIMIT ?
                """,
                (f"{repo_root}%", cwd, REPO_LIMIT * 4),
                "repo",
                REPO_LIMIT,
            )
        return exact, _dedupe_against(repo, {entry.cmd for entry in exact})
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


def default_candidate(cwd: str, repo_root: str, exact: list[HistoryEntry], repo: list[HistoryEntry]) -> str:
    if exact:
        return exact[0].cmd
    if repo:
        return repo[0].cmd
    return "git status" if repo_root and repo_root != cwd or _is_git_directory(cwd) else "ls -la"


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


def build_prompt(cwd: str, repo_root: str, partial: str, exact: list[HistoryEntry], repo: list[HistoryEntry]) -> str:
    repo_text = repo_root or "(none)"
    partial_text = partial.strip()
    instructions = [
        "Return exactly one shell command.",
        "Output one line only.",
        "Do not include markdown, quotes, bullets, or explanations.",
        "Prefer commands from the provided history.",
        "Use current directory context strongly.",
    ]
    if partial_text:
        instructions.append(f"The command must start with this prefix: {partial_text}")
    else:
        instructions.append("Suggest the most likely next command the user wants to run.")

    prompt = [
        "You are generating a zsh command suggestion.",
        *instructions,
        "",
        f"Current directory: {cwd}",
        f"Repository root: {repo_text}",
    ]
    if exact:
        prompt.extend(["", "History for this exact directory:"])
        prompt.extend(f"- {entry.cmd} (uses={entry.uses})" for entry in exact)
    if repo:
        prompt.extend(["", "History from this repository:"])
        prompt.extend(f"- {entry.cmd} (uses={entry.uses})" for entry in repo)
    prompt.extend(
        [
            "",
            "Fallback policy:",
            "- If the directory is in a git repository and no better candidate exists, return git status.",
            "- Otherwise return ls -la.",
        ]
    )
    return "\n".join(prompt)


def run_goose(prompt: str, model: str) -> tuple[str, str]:
    cmd = [
        "goose",
        "run",
        "--quiet",
        "--no-session",
        "--model",
        model,
        "--text",
        prompt,
    ]
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=GOOSE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return "", str(exc)

    if proc.returncode != 0:
        return "", proc.stderr.strip()
    return proc.stdout.strip(), ""


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
    return line


def suggest_command(cwd: str, repo_root: str, history_db: str, model: str, partial: str) -> str:
    exact, repo = query_history(history_db, cwd, repo_root)
    fallback = default_candidate(cwd, repo_root, exact, repo)

    if not shutil_which("goose"):
        return _apply_partial_fallback(fallback, partial)

    prompt = build_prompt(cwd, repo_root, partial, exact, repo)
    raw, _ = run_goose(prompt, model)
    suggestion = sanitize_suggestion(raw, partial)
    if suggestion:
        return suggestion
    return _apply_partial_fallback(fallback, partial)


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
    parser.add_argument("--partial", default="", help="Partial command prefix to continue")
    parser.add_argument("--print-debug", action="store_true", help="Print debug data to stderr")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    cwd = os.path.abspath(os.path.expanduser(args.pwd))
    repo_root = os.path.abspath(os.path.expanduser(args.repo_root)) if args.repo_root else ""
    suggestion = suggest_command(cwd, repo_root, args.history_db, args.model, args.partial)
    if args.print_debug:
        exact, repo = query_history(args.history_db, cwd, repo_root)
        print(f"cwd={cwd}", file=sys.stderr)
        print(f"repo_root={repo_root}", file=sys.stderr)
        print(f"exact={len(exact)} repo={len(repo)}", file=sys.stderr)
        print(f"suggestion={suggestion}", file=sys.stderr)
    if suggestion:
        print(suggestion)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
