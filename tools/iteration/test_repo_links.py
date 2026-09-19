#!/usr/bin/env python3
"""Unit tests for iteration_state.check_repo_links (the --repo-root cross-checks)."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import iteration_state


class RepoLinkChecks(unittest.TestCase):
    """check_repo_links proves the *references* a state file makes against a repo tree."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.write("docs/ACCEPTANCE_MATRIX.md", "| B1 | PASS |\n")
        self.write("docs/EVIDENCE.md", "| ID | x |\n| E-1 | ok |\n")
        self.write("docs/DECISIONS.md", "DEC-1 accepted\n")
        self.write("docs/DEFECTS.md", "| D-20260101-01 | P3 | closed |\n")
        self.write("docs/evidence/g-test.log", "ok\n")
        self.write("docs/audits/r1.md", "clean\n")
        self.write("docs/PROJECT_AUDIT.md", "A-01\n")
        self.write("lib/a.dart", "// see D-20260101-01\n")
        self.data = {
            "gates": [
                {"id": "G-1", "required": True, "status": "PASS", "evidence": ["docs/evidence/g-test.log"]}
            ],
            "audits": [{"id": "A-1", "report": "docs/audits/r1.md"}],
            "artifacts": [
                {"path": "docs/ACCEPTANCE_MATRIX.md", "evidence": ["E-1"]},
                {"path": "docs/EVIDENCE.md", "evidence": ["E-1"]},
                {"path": "docs/DECISIONS.md", "evidence": ["DEC-1"]},
                {"path": "docs/DEFECTS.md", "evidence": ["E-1"]},
            ],
            "hygiene": {"secret_scan_evidence": ["docs/evidence/g-test.log"]},
            "blockers": [{"id": "BL-1", "evidence": ["docs/PROJECT_AUDIT.md（A-01）"]}],
            "score": {"history": [{"iteration": 0, "total": 1, "source_hash": self.matrix_hash()}]},
            "candidates": [{"id": "W-1", "status": "DONE", "review_id": "A-1"}],
        }

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def matrix_hash(self) -> str:
        return iteration_state._sha256_file(self.root / "docs/ACCEPTANCE_MATRIX.md")

    def errors(self) -> list[str]:
        errors, _warnings = iteration_state.check_repo_links(self.data, self.root)
        return errors

    def test_consistent_repo_has_no_errors(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_missing_gate_evidence_file(self) -> None:
        (self.root / "docs/evidence/g-test.log").unlink()
        self.assertTrue(any("G-1" in e and "missing" in e for e in self.errors()))

    def test_required_gate_without_evidence(self) -> None:
        self.data["gates"][0]["evidence"] = []
        self.assertTrue(any("no evidence recorded" in e for e in self.errors()))

    def test_missing_audit_report(self) -> None:
        (self.root / "docs/audits/r1.md").unlink()
        self.assertTrue(any("audit A-1" in e for e in self.errors()))

    def test_missing_artifact_path(self) -> None:
        (self.root / "docs/DECISIONS.md").unlink()
        self.assertTrue(any("artifact missing on disk" in e for e in self.errors()))

    def test_unknown_evidence_id(self) -> None:
        self.data["artifacts"][1]["evidence"] = ["E-99"]
        self.assertTrue(any("E-99" in e for e in self.errors()))

    def test_unknown_decision_id(self) -> None:
        self.data["artifacts"][2]["evidence"] = ["DEC-99"]
        self.assertTrue(any("DEC-99" in e for e in self.errors()))

    def test_matrix_changed_without_history_entry(self) -> None:
        self.write("docs/ACCEPTANCE_MATRIX.md", "| B1 | PARTIAL |\n")
        self.assertTrue(any("acceptance matrix" in e and "changed" in e for e in self.errors()))

    def test_defect_cited_in_code_must_be_registered(self) -> None:
        self.write("lib/b.dart", "// fixes D-20260202-02\n")
        self.assertTrue(any("D-20260202-02" in e for e in self.errors()))

    def test_done_candidate_needs_known_review(self) -> None:
        self.data["candidates"][0]["review_id"] = None
        self.assertTrue(any("DONE without review_id" in e for e in self.errors()))
        self.data["candidates"][0]["review_id"] = "A-404"
        self.assertTrue(any("A-404" in e for e in self.errors()))

    def test_annotated_blocker_evidence_resolves(self) -> None:
        self.assertEqual([e for e in self.errors() if "BL-1" in e], [])
        self.data["blockers"][0]["evidence"] = ["docs/NOPE.md（A-01）"]
        self.assertTrue(any("BL-1" in e for e in self.errors()))

    def test_python_selftest_fixtures_are_not_defect_citations(self) -> None:
        # iter3 F-1: the validator's own self-tests carry synthetic ids.
        self.write("tools/test_fixture.py", "ids = ['D-20260303-03']\n")
        self.assertEqual([e for e in self.errors() if "D-20260303-03" in e], [])
        self.write("tools/helper.py", "# fixes D-20260404-04\n")
        self.assertTrue(any("D-20260404-04" in e for e in self.errors()))

    def test_decision_id_is_not_matched_as_prefix(self) -> None:
        # iter3 F-6: DEC-1 must not be satisfied by DEC-10.
        self.write("docs/DECISIONS.md", "DEC-10 accepted\n")
        self.assertTrue(any("DEC-1 " in e or "DEC-1 not" in e for e in self.errors()))
        self.write("docs/DECISIONS.md", "| DEC-1 | accepted |\n")
        self.assertEqual([e for e in self.errors() if "DEC-1" in e], [])

    def test_literal_path_with_parentheses_is_tried_first(self) -> None:
        # iter3 F-7: a real path containing "(" must not be truncated into a miss.
        self.write("docs/notes (2026).md", "x\n")
        self.data["blockers"][0]["evidence"] = ["docs/notes (2026).md"]
        self.assertEqual([e for e in self.errors() if "BL-1" in e], [])


if __name__ == "__main__":
    unittest.main()
