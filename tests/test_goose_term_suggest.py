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

    def test_default_candidate_prefers_exact_history(self):
        exact = [goose_term_suggest.HistoryEntry(cmd="make test", uses=3, last_run=10, scope="pwd")]
        repo = [goose_term_suggest.HistoryEntry(cmd="git status", uses=2, last_run=9, scope="repo")]
        self.assertEqual(
            goose_term_suggest.default_candidate("/tmp/project", "/tmp/project", exact, repo),
            "make test",
        )


if __name__ == "__main__":
    unittest.main()
