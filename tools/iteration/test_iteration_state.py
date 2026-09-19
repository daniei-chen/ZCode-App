#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import copy
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import iteration_state


ROOT = Path(__file__).resolve().parent
TEMPLATE = ROOT / "assets" / "ITERATION_STATE.template.json"


def load_template() -> dict:
    return json.loads(TEMPLATE.read_text(encoding="utf-8"))


def make_terminated() -> dict:
    data = load_template()
    data.update({"run_id": "test-run", "revision": 2, "iteration": 2, "phase": "DECIDE"})
    data["checkpoint"] = {
        "id": "cp-2",
        "git_head": "abc123",
        "diff_fingerprint": "sha256:test",
        "recorded_at": "2026-09-16T00:00:00Z",
    }
    data["defects"] = {"P0": 0, "P1": 0, "P2": 0, "P3": 0}
    data["acceptance"] = {
        "OPEN": 0,
        "PARTIAL": 0,
        "FAIL": 0,
        "BLOCKED": 0,
        "PASS": 5,
        "DEFERRED": 0,
        "NA": 0,
    }
    for item in data["score"]["dimensions"].values():
        item["earned"] = 1
        item["possible"] = 1
    data["score"]["history"] = [
        {"iteration": 0, "total": 0, "source_hash": "sha256:base"},
        {"iteration": 1, "total": 100, "source_hash": "sha256:one"},
        {"iteration": 2, "total": 100, "source_hash": "sha256:two"},
    ]
    data["gates"] = [
        {
            "id": "G-001",
            "command": "test",
            "required": True,
            "status": "PASS",
            "checkpoint_id": "cp-2",
            "evidence": ["evidence/gate.txt"],
        }
    ]
    data["audits"] = [
        {
            "id": "A-001",
            "iteration": 1,
            "reviewer_id": "reviewer-one",
            "independent": True,
            "risk": "R2",
            "checkpoint_id": "cp-1",
            "coverage": ["DIFF_CORRECTNESS"],
            "new_p0": 0,
            "new_p1": 0,
            "report": "audits/A-001.md",
        },
        {
            "id": "A-002",
            "iteration": 2,
            "reviewer_id": "reviewer-two",
            "independent": True,
            "risk": "R2",
            "checkpoint_id": "cp-2",
            "coverage": ["DIFF_CORRECTNESS", "RESILIENCE"],
            "new_p0": 0,
            "new_p1": 0,
            "report": "audits/A-002.md",
        },
    ]
    data["candidates"] = []
    data["blockers"] = []
    for artifact in data["artifacts"]:
        artifact["revision"] = 2
        artifact["evidence"] = [f"{artifact['path']}.sha256"]
    data["hygiene"] = {
        "unresolved_placeholders": 0,
        "secret_scan": "PASS",
        "secret_scan_evidence": ["evidence/secret-scan.txt"],
    }
    data["resume"]["next_action"] = "No action; verified terminal state."
    derived = iteration_state.analyze(data, check_claims=False)
    data["status"] = derived["derived_status"]
    data["termination"]["claim"] = derived["derived_status"]
    data["termination"]["checks"] = derived["checks"]
    data["termination"]["reason"] = "All current-checkpoint checks passed."
    return data


class IterationStateTests(unittest.TestCase):
    def test_template_is_valid_continue(self) -> None:
        result = iteration_state.analyze(load_template())
        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(result["derived_status"], "CONTINUE")
        self.assertTrue(all(value == "OPEN" for value in result["checks"].values()))

    def test_terminal_fixture(self) -> None:
        result = iteration_state.analyze(make_terminated())
        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(result["derived_status"], "TERMINATED")
        self.assertEqual(set(result["checks"].values()), {"DONE"})

    def test_blocked_cannot_be_terminated(self) -> None:
        data = load_template()
        data["acceptance"]["OPEN"] = 0
        data["acceptance"]["BLOCKED"] = 1
        data["candidates"][0].update({"status": "BLOCKED", "blocker_id": "B-001"})
        data["blockers"] = [
            {
                "id": "B-001",
                "type": "USER",
                "required_for_target": True,
                "status": "OPEN",
                "recommended_option": "Approve the safe option.",
                "unlock_condition": "User chooses an option.",
                "evidence": ["DECISIONS.md#b-001"],
                "blocks": ["T1", "T2", "T7"],
            }
        ]
        result = iteration_state.analyze(data, check_claims=False)
        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(result["derived_status"], "BLOCKED")
        self.assertEqual(result["checks"]["T2"], "BLOCKED")
        self.assertEqual(result["checks"]["T7"], "BLOCKED")

    def test_budget_precedes_continue(self) -> None:
        data = load_template()
        data["budget"] = {"kind": "rounds", "limit": 1, "used": 1}
        result = iteration_state.analyze(data, check_claims=False)
        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(result["derived_status"], "BUDGET")

    def test_p1_cannot_be_deferred(self) -> None:
        data = load_template()
        data["audits"] = [
            {
                "id": "A-001",
                "iteration": 0,
                "reviewer_id": "reviewer",
                "independent": True,
                "risk": "R1",
                "checkpoint_id": "baseline-unverified",
                "coverage": ["DIFF_CORRECTNESS"],
                "new_p0": 0,
                "new_p1": 0,
                "report": "audits/A-001.md",
            }
        ]
        data["candidates"][0].update(
            {
                "required_for_target": False,
                "status": "DEFERRED",
                "defer_reason": "Attempted shortcut",
                "review_id": "A-001",
            }
        )
        result = iteration_state.analyze(data, check_claims=False)
        self.assertFalse(result["valid"])
        self.assertTrue(any("deferral rules" in error for error in result["errors"]))

    def test_old_gate_checkpoint_blocks_t5(self) -> None:
        data = make_terminated()
        data["gates"][0]["checkpoint_id"] = "cp-1"
        result = iteration_state.analyze(data, check_claims=False)
        self.assertEqual(result["checks"]["T5"], "OPEN")
        self.assertEqual(result["derived_status"], "CONTINUE")

    def test_same_reviewer_cannot_form_clean_streak(self) -> None:
        data = make_terminated()
        data["audits"][1]["reviewer_id"] = data["audits"][0]["reviewer_id"]
        result = iteration_state.analyze(data, check_claims=False)
        self.assertEqual(result["checks"]["T3"], "OPEN")
        self.assertEqual(result["derived_status"], "CONTINUE")


class RequireTrackedChecks(unittest.TestCase):
    """W-015: validate --require-tracked gates referenced paths on git tracking.

    Uses a throwaway git repository (index staged, nothing committed, so no
    git identity is needed) to exercise real `git ls-files --error-unmatch`
    semantics against the temp directory only.
    """

    SEED = (
        "docs/DEFECTS.md",
        "docs/ACCEPTANCE_MATRIX.md",
        "docs/EVIDENCE.md",
        "docs/DECISIONS.md",
        "docs/audits/r1.md",
    )
    UNTRACKED_GATE = "docs/evidence/gate.log"

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.git("init")
        for rel in self.SEED:
            self.write(rel, "ok\n")
        self.git("add", "docs")
        # Written after `git add` on purpose: on disk, absent from the index.
        self.write(self.UNTRACKED_GATE, "ok\n")
        self.data = {
            "source_map": {
                "defects": "docs/DEFECTS.md",
                "acceptance": "docs/ACCEPTANCE_MATRIX.md",
                "evidence": "docs/EVIDENCE.md",
                "decisions": "docs/DECISIONS.md",
                "audits": "docs/audits/",
            },
            "gates": [{"id": "G-1", "evidence": [self.UNTRACKED_GATE]}],
            "audits": [{"id": "A-1", "report": "docs/audits/r1.md"}],
        }

    def write(self, rel: str, text: str, root: Path | None = None) -> None:
        base = self.root if root is None else root
        path = base / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, text=True)

    def tracked_errors(self) -> list[str]:
        errors, _warnings = iteration_state.check_tracked_files(self.data, self.root)
        return errors

    def test_untracked_gate_evidence_fails(self) -> None:
        errors = self.tracked_errors()
        self.assertTrue(any(self.UNTRACKED_GATE in error for error in errors), errors)
        # The `all` half proves source_map targets (incl. the trailing-slash
        # audits directory) and the audit report do not raise extra errors.
        self.assertTrue(all(self.UNTRACKED_GATE in error for error in errors), errors)

    def test_tracked_references_pass(self) -> None:
        self.data["gates"][0]["evidence"] = ["docs/EVIDENCE.md"]
        self.assertEqual(self.tracked_errors(), [])

    def test_default_off_ignores_untracked(self) -> None:
        result = {"valid": True, "errors": [], "warnings": []}
        iteration_state.apply_repo_checks(result, self.data, self.root)
        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(result["errors"], [])

    def test_flag_makes_untracked_fatal(self) -> None:
        result = {"valid": True, "errors": [], "warnings": []}
        iteration_state.apply_repo_checks(result, self.data, self.root, require_tracked=True)
        self.assertFalse(result["valid"])
        self.assertTrue(any(self.UNTRACKED_GATE in error for error in result["errors"]), result["errors"])

    def test_non_git_root_degrades_to_warning(self) -> None:
        # Fallback口径: git failure must degrade, not error — the repo's shell
        # gates treat git output as best-effort (`2>/dev/null` in gates.sh /
        # clean_start.sh); here the skipped verification is recorded as one
        # warning and never flips validity.
        with tempfile.TemporaryDirectory() as plain:
            plain_root = Path(plain)
            for rel in (*self.SEED, self.UNTRACKED_GATE):
                self.write(rel, "ok\n", root=plain_root)
            errors, warnings = iteration_state.check_tracked_files(self.data, plain_root)
            self.assertEqual(errors, [])
            self.assertEqual(len(warnings), 1)
            result = {"valid": True, "errors": [], "warnings": []}
            iteration_state.apply_repo_checks(result, self.data, plain_root, require_tracked=True)
            self.assertTrue(result["valid"])
            self.assertEqual(len(result["warnings"]), 1)

    def test_test_py_fixtures_are_exempt(self) -> None:
        self.write("tools/test_fixture.py", "ids = []\n")
        self.data["gates"][0]["evidence"] = ["tools/test_fixture.py"]
        self.assertEqual(self.tracked_errors(), [])

    def test_only_in_repo_relative_paths_validated(self) -> None:
        self.data["gates"][0]["evidence"] = [
            "https://example.test/gate.log",
            "../outside/gate.log",
            "C:\\escape\\gate.log",
            "E-1",
            "DEC-1",
        ]
        self.assertEqual(self.tracked_errors(), [])

    def test_annotated_reference_resolves_before_tracking(self) -> None:
        self.data["gates"][0]["evidence"] = ["docs/audits/r1.md（A-01）"]
        self.assertEqual(self.tracked_errors(), [])
        self.data["gates"][0]["evidence"] = ["docs/evidence/gate.log（A-01）"]
        errors = self.tracked_errors()
        self.assertTrue(any("docs/evidence/gate.log" in error for error in errors), errors)

    def test_untracked_source_map_entry_fails(self) -> None:
        self.git("rm", "--cached", "docs/DECISIONS.md")
        self.assertTrue(any("docs/DECISIONS.md" in error for error in self.tracked_errors()))

    def test_validate_cli_wiring(self) -> None:
        state = self.root / "state.json"
        state.write_text(json.dumps(self.data), encoding="utf-8")
        parser = iteration_state.build_parser()
        with_flag = parser.parse_args(
            ["validate", str(state), "--repo-root", str(self.root), "--require-tracked"]
        )
        self.assertTrue(with_flag.require_tracked)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            self.assertEqual(iteration_state.command_validate(with_flag), 1)
        self.assertIn(self.UNTRACKED_GATE, buffer.getvalue())
        without_flag = parser.parse_args(["validate", str(state), "--repo-root", str(self.root)])
        self.assertFalse(without_flag.require_tracked)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            iteration_state.command_validate(without_flag)
        self.assertNotIn(self.UNTRACKED_GATE, buffer.getvalue())
        self.assertNotIn("git-tracked", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
