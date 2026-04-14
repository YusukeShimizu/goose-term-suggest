import unittest
from unittest import mock

import goose_term_suggest


class GooseTermSuggestTests(unittest.TestCase):
    def test_sanitize_single_line(self):
        self.assertEqual(
            goose_term_suggest.sanitize_suggestion("git status\n", partial=""),
            "git status",
        )

    def test_sanitize_rejects_multiline(self):
        self.assertEqual(
            goose_term_suggest.sanitize_suggestion("git status\nexplanation", partial=""),
            "",
        )

    def test_sanitize_respects_partial(self):
        self.assertEqual(
            goose_term_suggest.sanitize_suggestion("git commit -m test", partial="git "),
            "git commit -m test",
        )
        self.assertEqual(
            goose_term_suggest.sanitize_suggestion("ls -la", partial="git "),
            "",
        )

    def test_rejects_meta_command_suggestion_without_partial(self):
        self.assertEqual(
            goose_term_suggest.sanitize_suggestion("claude --dangerously-skip-permissions", partial=""),
            "",
        )

    def test_default_candidate_prefers_exact_history(self):
        exact = [goose_term_suggest.HistoryEntry(cmd="make test", uses=3, last_run=10, scope="pwd")]
        repo = [goose_term_suggest.HistoryEntry(cmd="git status", uses=2, last_run=9, scope="repo")]
        self.assertEqual(
            goose_term_suggest.default_candidate("/tmp/project", "/tmp/project", exact, repo),
            "make test",
        )

    def test_build_candidate_pool_filters_meta_commands(self):
        candidates = goose_term_suggest.build_candidate_pool(
            partial="",
            last_command="claude --dangerously-skip-permissions",
            last_status=1,
            exact=[goose_term_suggest.HistoryEntry(cmd="go test ./...", uses=3, last_run=10, scope="pwd")],
            repo=[],
            recent_exact=[],
            recent_repo=[],
            fallback="git status",
        )
        self.assertEqual(candidates[0], "go test ./...")
        self.assertNotIn("claude --dangerously-skip-permissions", candidates)

    def test_build_candidate_pool_omits_failed_command_and_uses_history(self):
        candidates = goose_term_suggest.build_candidate_pool(
            partial="",
            last_command="go test",
            last_status=1,
            exact=[goose_term_suggest.HistoryEntry(cmd="go test ./...", uses=3, last_run=10, scope="pwd")],
            repo=[],
            recent_exact=[goose_term_suggest.RecentEntry(cmd="go mod tidy", exit_code=0, when_run=11, scope="pwd")],
            recent_repo=[],
            fallback="git status",
        )
        self.assertEqual(candidates[0], "go mod tidy")
        self.assertNotIn("go test", candidates)

    def test_build_prompt_mentions_terminal_session_context(self):
        prompt = goose_term_suggest.build_prompt(
            cwd="/tmp/project",
            repo_root="/tmp/project",
            partial="",
            last_command="go test",
            last_status=1,
            exact=[],
            repo=[],
            recent_exact=[],
            recent_repo=[],
            candidates=["go mod tidy", "git status"],
        )
        self.assertIn("active Goose terminal session already contains the very recent shell history", prompt)
        self.assertIn("The previous command failed.", prompt)
        self.assertIn("- go mod tidy", prompt)

    def test_non_failure_uses_primary_model(self):
        with mock.patch.object(goose_term_suggest, "run_goose_term", return_value=("go test ./...", "")) as run_goose:
            suggestion = goose_term_suggest.suggest_command(
                cwd="/tmp/project",
                repo_root="/tmp/project",
                history_db="/tmp/missing.db",
                model="gpt-5.4-nano-low",
                failure_model="gpt-5.4-nano-medium",
                partial="",
                last_command="go test ./...",
                last_status=0,
            )
        self.assertEqual(suggestion, "go test ./...")
        self.assertEqual(run_goose.call_args.args[1], "gpt-5.4-nano-low")

    def test_failure_uses_failure_model(self):
        with mock.patch.object(goose_term_suggest, "run_goose_term", return_value=("go test -v ./...", "")) as run_goose:
            suggestion = goose_term_suggest.suggest_command(
                cwd="/tmp/project",
                repo_root="/tmp/project",
                history_db="/tmp/missing.db",
                model="gpt-5.4-nano-low",
                failure_model="gpt-5.4-nano-medium",
                partial="",
                last_command="go test",
                last_status=1,
            )
        self.assertEqual(suggestion, "go test -v ./...")
        self.assertEqual(run_goose.call_args.args[1], "gpt-5.4-nano-medium")


if __name__ == "__main__":
    unittest.main()
