#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
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


if __name__ == "__main__":
    unittest.main()
