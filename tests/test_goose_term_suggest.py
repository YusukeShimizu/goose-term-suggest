import unittest

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

    def test_failure_followups_for_go_test(self):
        self.assertEqual(
            goose_term_suggest.failure_followups("go test ./..."),
            ["go test ./... 2>&1 | tail -n 80", "rg -n 'FAIL|panic:|expected|got|error:' ."],
        )

    def test_build_candidate_pool_prefers_fix_for_exit_code_one(self):
        candidates = goose_term_suggest.build_candidate_pool(
            partial="",
            last_command="go test ./...",
            last_status=1,
            exact=[goose_term_suggest.HistoryEntry(cmd="git status", uses=3, last_run=10, scope="pwd")],
            repo=[],
            recent_exact=[],
            recent_repo=[],
            fallback="git status",
        )
        self.assertEqual(candidates[0], "go test ./... 2>&1 | tail -n 80")


if __name__ == "__main__":
    unittest.main()
