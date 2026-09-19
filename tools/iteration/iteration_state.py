#!/usr/bin/env python3
"""Validate, derive, synchronize, and render continuous-iteration state.

Standard-library only. This validates the control-plane contract; it cannot prove
that referenced evidence is truthful. ZCode's Goal verifier and independent
audits must still inspect the underlying files and command results.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "3.0"
PHASES = {
    "RECOVER",
    "PLAN",
    "IMPLEMENT",
    "GATE",
    "AUDIT",
    "REPAIR",
    "CHECKPOINT",
    "DECIDE",
}
STATUSES = {"CONTINUE", "TERMINATED", "BLOCKED", "BUDGET"}
CHECK_STATUSES = {"DONE", "OPEN", "BLOCKED"}
CHECK_IDS = [f"T{i}" for i in range(1, 8)]
SEVERITIES = {"P0", "P1", "P2", "P3"}
ACCEPTANCE_STATES = {"OPEN", "PARTIAL", "FAIL", "BLOCKED", "PASS", "DEFERRED", "NA"}
GATE_STATES = {"PASS", "FAIL", "BLOCKED", "NOT_RUN"}
CANDIDATE_STATES = {"LOCAL", "BLOCKED", "DEFERRED", "DONE"}
ARTIFACT_STATES = {"CURRENT", "STALE", "MISSING"}
SECRET_SCAN_STATES = {"PASS", "FAIL", "BLOCKED", "NOT_RUN"}
RISK_LEVELS = {"R0", "R1", "R2", "R3"}
COVERAGE_TAGS = {
    "DIFF_CORRECTNESS",
    "BOUNDARY_CONTRACT",
    "ADVERSARIAL",
    "RESILIENCE",
    "SCALE_DATA",
    "CLEAN_START_RELEASE",
}
DIMENSION_WEIGHTS = {
    "core": 30,
    "security": 25,
    "tests": 20,
    "operations": 15,
    "docs": 10,
}
TARGETS = {
    "prototype": {
        "score": 55,
        "floors": {"core": 0.50, "security": 0.40, "tests": 0.40, "operations": 0.25, "docs": 0.25},
    },
    "internal_beta": {
        "score": 70,
        "floors": {"core": 0.65, "security": 0.60, "tests": 0.60, "operations": 0.50, "docs": 0.50},
    },
    "release_candidate": {
        "score": 85,
        "floors": {"core": 0.80, "security": 0.80, "tests": 0.75, "operations": 0.70, "docs": 0.70},
    },
    "production_improvement": {
        "score": 95,
        "floors": {"core": 0.90, "security": 0.90, "tests": 0.85, "operations": 0.85, "docs": 0.80},
    },
}


def load_state(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError as exc:
        raise ValueError(f"state file does not exist: {path}") from exc
    except UnicodeDecodeError as exc:
        raise ValueError("state file must be UTF-8") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ValueError("state root must be a JSON object")
    return data


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def add_error(errors: list[str], condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def mapping(data: dict[str, Any], key: str, errors: list[str]) -> dict[str, Any]:
    value = data.get(key)
    if not isinstance(value, dict):
        errors.append(f"{key} must be an object")
        return {}
    return value


def list_value(data: dict[str, Any], key: str, errors: list[str]) -> list[Any]:
    value = data.get(key)
    if not isinstance(value, list):
        errors.append(f"{key} must be an array")
        return []
    return value


def round_score(value: float) -> int:
    return int(value + 0.5)


def analyze(data: dict[str, Any], check_claims: bool = True) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    add_error(errors, data.get("schema_version") == SCHEMA_VERSION, f"schema_version must be {SCHEMA_VERSION}")
    add_error(errors, nonempty_string(data.get("run_id")), "run_id must be a non-empty string")
    add_error(errors, nonnegative_int(data.get("revision")), "revision must be a non-negative integer")
    add_error(errors, nonnegative_int(data.get("iteration")), "iteration must be a non-negative integer")
    add_error(errors, data.get("phase") in PHASES, f"phase must be one of {sorted(PHASES)}")
    add_error(errors, data.get("status") in STATUSES, f"status must be one of {sorted(STATUSES)}")

    iteration = data.get("iteration") if nonnegative_int(data.get("iteration")) else 0
    revision = data.get("revision") if nonnegative_int(data.get("revision")) else 0

    target = mapping(data, "target", errors)
    level = target.get("level")
    add_error(errors, level in TARGETS, f"target.level must be one of {sorted(TARGETS)}")
    expected_target = TARGETS.get(level, TARGETS["release_candidate"])
    add_error(errors, target.get("score") == expected_target["score"], f"target.score must be {expected_target['score']} for {level!r}")

    budget = mapping(data, "budget", errors)
    budget_kind = budget.get("kind")
    add_error(errors, budget_kind in {"none", "rounds", "hours", "cost"}, "budget.kind must be none, rounds, hours, or cost")
    budget_limit = budget.get("limit")
    budget_used = budget.get("used")
    add_error(errors, is_number(budget_used) and budget_used >= 0, "budget.used must be a non-negative number")
    if budget_kind == "none":
        add_error(errors, budget_limit is None, "budget.limit must be null when budget.kind is none")
    else:
        add_error(errors, is_number(budget_limit) and budget_limit > 0, "budget.limit must be a positive number for a bounded budget")
    budget_exhausted = bool(
        budget_kind != "none"
        and is_number(budget_limit)
        and is_number(budget_used)
        and budget_used >= budget_limit
    )

    checkpoint = mapping(data, "checkpoint", errors)
    for field in ("id", "git_head", "diff_fingerprint", "recorded_at"):
        add_error(errors, nonempty_string(checkpoint.get(field)), f"checkpoint.{field} must be a non-empty string")
    checkpoint_id = checkpoint.get("id") if nonempty_string(checkpoint.get("id")) else ""

    source_map = mapping(data, "source_map", errors)
    for field in ("defects", "acceptance", "evidence", "decisions", "audits"):
        add_error(errors, nonempty_string(source_map.get(field)), f"source_map.{field} must be a non-empty path")

    defects = mapping(data, "defects", errors)
    for severity in SEVERITIES:
        add_error(errors, nonnegative_int(defects.get(severity)), f"defects.{severity} must be a non-negative integer")
    open_p0 = defects.get("P0") if nonnegative_int(defects.get("P0")) else 0
    open_p1 = defects.get("P1") if nonnegative_int(defects.get("P1")) else 0

    acceptance = mapping(data, "acceptance", errors)
    for state in ACCEPTANCE_STATES:
        add_error(errors, nonnegative_int(acceptance.get(state)), f"acceptance.{state} must be a non-negative integer")
    acceptance_pending = sum(
        acceptance.get(state, 0) if nonnegative_int(acceptance.get(state)) else 0
        for state in ("OPEN", "PARTIAL", "FAIL", "BLOCKED")
    )
    acceptance_blocked = acceptance.get("BLOCKED") if nonnegative_int(acceptance.get("BLOCKED")) else 0

    score = mapping(data, "score", errors)
    dimensions = mapping(score, "dimensions", errors)
    dimension_ratios: dict[str, float] = {}
    dimension_contributions: dict[str, float] = {}
    for name, weight in DIMENSION_WEIGHTS.items():
        item = dimensions.get(name)
        if not isinstance(item, dict):
            errors.append(f"score.dimensions.{name} must be an object")
            item = {}
        earned = item.get("earned")
        possible = item.get("possible")
        valid_numbers = is_number(earned) and is_number(possible)
        add_error(errors, valid_numbers, f"score.dimensions.{name}.earned/possible must be numbers")
        if valid_numbers:
            add_error(errors, possible > 0, f"score.dimensions.{name}.possible must be > 0")
            add_error(errors, 0 <= earned <= possible, f"score.dimensions.{name}.earned must be between 0 and possible")
            ratio = earned / possible if possible > 0 else 0.0
        else:
            ratio = 0.0
        dimension_ratios[name] = ratio
        dimension_contributions[name] = weight * ratio
    computed_score = round_score(sum(dimension_contributions.values()))

    history = list_value(score, "history", errors)
    history_rows: list[dict[str, Any]] = []
    previous_iteration = -1
    for index, row in enumerate(history):
        if not isinstance(row, dict):
            errors.append(f"score.history[{index}] must be an object")
            continue
        row_iteration = row.get("iteration")
        row_total = row.get("total")
        add_error(errors, nonnegative_int(row_iteration), f"score.history[{index}].iteration must be a non-negative integer")
        add_error(errors, nonnegative_int(row_total) and row_total <= 100, f"score.history[{index}].total must be an integer from 0 to 100")
        add_error(errors, nonempty_string(row.get("source_hash")), f"score.history[{index}].source_hash must be non-empty")
        if nonnegative_int(row_iteration):
            add_error(errors, row_iteration > previous_iteration, "score.history iterations must be strictly increasing")
            previous_iteration = row_iteration
        history_rows.append(row)
    add_error(errors, bool(history_rows), "score.history must contain at least the baseline row")
    if history_rows:
        last = history_rows[-1]
        add_error(errors, last.get("iteration") == iteration, "last score.history iteration must equal state iteration")
        add_error(errors, last.get("total") == computed_score, f"last score.history total must equal computed score {computed_score}")

    target_score = expected_target["score"]
    floors_met = all(dimension_ratios[name] >= expected_target["floors"][name] for name in DIMENSION_WEIGHTS)
    score_stable = False
    if len(history_rows) >= 3:
        previous = history_rows[-2].get("total")
        current = history_rows[-1].get("total")
        score_stable = (
            nonnegative_int(previous)
            and nonnegative_int(current)
            and previous >= target_score
            and current >= target_score
            and current >= previous
        )

    gates = list_value(data, "gates", errors)
    gate_ids: set[str] = set()
    required_gate_count = 0
    required_gate_blocked = 0
    required_gates_pass = True
    for index, gate in enumerate(gates):
        if not isinstance(gate, dict):
            errors.append(f"gates[{index}] must be an object")
            required_gates_pass = False
            continue
        gate_id = gate.get("id")
        add_error(errors, nonempty_string(gate_id), f"gates[{index}].id must be non-empty")
        if nonempty_string(gate_id):
            add_error(errors, gate_id not in gate_ids, f"duplicate gate id: {gate_id}")
            gate_ids.add(gate_id)
        add_error(errors, nonempty_string(gate.get("command")), f"gates[{index}].command must be non-empty")
        add_error(errors, isinstance(gate.get("required"), bool), f"gates[{index}].required must be boolean")
        add_error(errors, gate.get("status") in GATE_STATES, f"gates[{index}].status is invalid")
        add_error(errors, nonempty_string(gate.get("checkpoint_id")), f"gates[{index}].checkpoint_id must be non-empty")
        evidence = gate.get("evidence")
        add_error(errors, isinstance(evidence, list), f"gates[{index}].evidence must be an array")
        if gate.get("status") == "PASS":
            add_error(errors, isinstance(evidence, list) and any(nonempty_string(item) for item in evidence), f"gates[{index}] PASS requires evidence")
        if gate.get("required") is True:
            required_gate_count += 1
            if gate.get("status") == "BLOCKED":
                required_gate_blocked += 1
            if gate.get("status") != "PASS" or gate.get("checkpoint_id") != checkpoint_id:
                required_gates_pass = False
    add_error(errors, required_gate_count > 0, "at least one gate must be required")

    audits = list_value(data, "audits", errors)
    audit_ids: set[str] = set()
    current_independent_audit_ids: set[str] = set()
    audit_rounds: dict[int, list[dict[str, Any]]] = {}
    for index, audit in enumerate(audits):
        if not isinstance(audit, dict):
            errors.append(f"audits[{index}] must be an object")
            continue
        audit_id = audit.get("id")
        add_error(errors, nonempty_string(audit_id), f"audits[{index}].id must be non-empty")
        if nonempty_string(audit_id):
            add_error(errors, audit_id not in audit_ids, f"duplicate audit id: {audit_id}")
            audit_ids.add(audit_id)
        audit_iteration = audit.get("iteration")
        add_error(errors, nonnegative_int(audit_iteration) and audit_iteration <= iteration, f"audits[{index}].iteration is invalid")
        add_error(errors, nonempty_string(audit.get("reviewer_id")), f"audits[{index}].reviewer_id must be non-empty")
        add_error(errors, isinstance(audit.get("independent"), bool), f"audits[{index}].independent must be boolean")
        add_error(errors, audit.get("risk") in RISK_LEVELS, f"audits[{index}].risk is invalid")
        add_error(errors, nonempty_string(audit.get("checkpoint_id")), f"audits[{index}].checkpoint_id must be non-empty")
        coverage = audit.get("coverage")
        add_error(errors, isinstance(coverage, list) and bool(coverage), f"audits[{index}].coverage must be a non-empty array")
        if isinstance(coverage, list):
            unknown = {item for item in coverage if item not in COVERAGE_TAGS}
            add_error(errors, not unknown, f"audits[{index}] has unknown coverage tags: {sorted(unknown)}")
        add_error(errors, nonnegative_int(audit.get("new_p0")), f"audits[{index}].new_p0 must be a non-negative integer")
        add_error(errors, nonnegative_int(audit.get("new_p1")), f"audits[{index}].new_p1 must be a non-negative integer")
        add_error(errors, nonempty_string(audit.get("report")), f"audits[{index}].report must be non-empty")
        if nonnegative_int(audit_iteration):
            audit_rounds.setdefault(audit_iteration, []).append(audit)
        if (
            nonempty_string(audit_id)
            and audit.get("independent") is True
            and audit_iteration == iteration
            and audit.get("checkpoint_id") == checkpoint_id
        ):
            current_independent_audit_ids.add(audit_id)

    qualifying_rounds: list[dict[str, Any]] = []
    for audit_iteration in sorted(audit_rounds):
        clean = [
            audit
            for audit in audit_rounds[audit_iteration]
            if audit.get("independent") is True
            and audit.get("new_p0") == 0
            and audit.get("new_p1") == 0
            and nonempty_string(audit.get("report"))
        ]
        if not clean:
            continue
        risks = {audit.get("risk") for audit in clean}
        reviewers = {audit.get("reviewer_id") for audit in clean if nonempty_string(audit.get("reviewer_id"))}
        if "R3" in risks and len(reviewers) < 2:
            continue
        coverage_union: set[str] = set()
        for audit in clean:
            if isinstance(audit.get("coverage"), list):
                coverage_union.update(item for item in audit["coverage"] if item in COVERAGE_TAGS)
        qualifying_rounds.append(
            {
                "iteration": audit_iteration,
                "audits": clean,
                "reviewers": reviewers,
                "coverage": coverage_union,
            }
        )

    audit_done = False
    if len(qualifying_rounds) >= 2:
        previous_round, latest_round = qualifying_rounds[-2], qualifying_rounds[-1]
        latest_covers_checkpoint = any(audit.get("checkpoint_id") == checkpoint_id for audit in latest_round["audits"])
        audit_done = (
            latest_round["iteration"] == iteration
            and latest_covers_checkpoint
            and previous_round["reviewers"].isdisjoint(latest_round["reviewers"])
            and bool(latest_round["coverage"] - previous_round["coverage"])
        )

    blockers = list_value(data, "blockers", errors)
    blocker_ids: set[str] = set()
    open_blocker_ids: set[str] = set()
    open_required_blockers = 0
    blockers_by_check: dict[str, int] = {check_id: 0 for check_id in CHECK_IDS}
    for index, blocker in enumerate(blockers):
        if not isinstance(blocker, dict):
            errors.append(f"blockers[{index}] must be an object")
            continue
        blocker_id = blocker.get("id")
        add_error(errors, nonempty_string(blocker_id), f"blockers[{index}].id must be non-empty")
        if nonempty_string(blocker_id):
            add_error(errors, blocker_id not in blocker_ids, f"duplicate blocker id: {blocker_id}")
            blocker_ids.add(blocker_id)
        add_error(errors, blocker.get("type") in {"USER", "EXTERNAL"}, f"blockers[{index}].type must be USER or EXTERNAL")
        add_error(errors, isinstance(blocker.get("required_for_target"), bool), f"blockers[{index}].required_for_target must be boolean")
        add_error(errors, blocker.get("status") in {"OPEN", "RESOLVED"}, f"blockers[{index}].status must be OPEN or RESOLVED")
        add_error(errors, nonempty_string(blocker.get("recommended_option")), f"blockers[{index}].recommended_option must be non-empty")
        add_error(errors, nonempty_string(blocker.get("unlock_condition")), f"blockers[{index}].unlock_condition must be non-empty")
        evidence = blocker.get("evidence")
        add_error(errors, isinstance(evidence, list), f"blockers[{index}].evidence must be an array")
        blocks = blocker.get("blocks")
        add_error(errors, isinstance(blocks, list) and bool(blocks), f"blockers[{index}].blocks must be a non-empty array")
        if isinstance(blocks, list):
            unknown = {item for item in blocks if item not in CHECK_IDS}
            add_error(errors, not unknown, f"blockers[{index}] has unknown check ids: {sorted(unknown)}")
        if blocker.get("status") == "OPEN" and nonempty_string(blocker_id):
            open_blocker_ids.add(blocker_id)
            if blocker.get("required_for_target") is True:
                open_required_blockers += 1
                if isinstance(blocks, list):
                    for check_id in blocks:
                        if check_id in blockers_by_check:
                            blockers_by_check[check_id] += 1

    candidates = list_value(data, "candidates", errors)
    candidate_ids: set[str] = set()
    local_candidates = 0
    blocked_candidates = 0
    deferred_candidates = 0
    invalid_deferrals = 0
    open_candidates_by_severity = {severity: 0 for severity in SEVERITIES}
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            errors.append(f"candidates[{index}] must be an object")
            continue
        candidate_id = candidate.get("id")
        add_error(errors, nonempty_string(candidate_id), f"candidates[{index}].id must be non-empty")
        if nonempty_string(candidate_id):
            add_error(errors, candidate_id not in candidate_ids, f"duplicate candidate id: {candidate_id}")
            candidate_ids.add(candidate_id)
        severity = candidate.get("severity")
        status = candidate.get("status")
        add_error(errors, severity in SEVERITIES, f"candidates[{index}].severity is invalid")
        add_error(errors, isinstance(candidate.get("required_for_target"), bool), f"candidates[{index}].required_for_target must be boolean")
        add_error(errors, status in CANDIDATE_STATES, f"candidates[{index}].status is invalid")
        if status == "LOCAL":
            local_candidates += 1
            if severity in SEVERITIES:
                open_candidates_by_severity[severity] += 1
        elif status == "BLOCKED":
            blocked_candidates += 1
            if severity in SEVERITIES:
                open_candidates_by_severity[severity] += 1
            blocker_id = candidate.get("blocker_id")
            add_error(errors, blocker_id in open_blocker_ids, f"candidates[{index}] BLOCKED must reference an OPEN blocker")
        elif status == "DEFERRED":
            deferred_candidates += 1
            valid = True
            if candidate.get("required_for_target") is not False:
                valid = False
            if severity in {"P0", "P1"}:
                valid = False
            if not nonempty_string(candidate.get("defer_reason")):
                valid = False
            if candidate.get("review_id") not in current_independent_audit_ids:
                valid = False
            if severity == "P2" and not nonempty_string(candidate.get("approval_ref")):
                valid = False
            add_error(errors, valid, f"candidates[{index}] does not satisfy deferral rules")
            if not valid:
                invalid_deferrals += 1

    for severity in SEVERITIES:
        open_count = defects.get(severity) if nonnegative_int(defects.get(severity)) else 0
        add_error(
            errors,
            open_candidates_by_severity[severity] >= open_count,
            f"open defects.{severity} must be represented by LOCAL/BLOCKED candidates",
        )
    deferred_acceptance = acceptance.get("DEFERRED") if nonnegative_int(acceptance.get("DEFERRED")) else 0
    add_error(errors, deferred_candidates >= deferred_acceptance, "DEFERRED acceptance items must be represented by deferred candidates")
    add_error(errors, blocked_candidates >= acceptance_blocked, "BLOCKED acceptance items must be represented by blocked candidates")

    artifacts = list_value(data, "artifacts", errors)
    artifact_paths: set[str] = set()
    artifacts_current = True
    required_artifact_count = 0
    for index, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            errors.append(f"artifacts[{index}] must be an object")
            artifacts_current = False
            continue
        path = artifact.get("path")
        add_error(errors, nonempty_string(path), f"artifacts[{index}].path must be non-empty")
        if nonempty_string(path):
            add_error(errors, path not in artifact_paths, f"duplicate artifact path: {path}")
            artifact_paths.add(path)
        add_error(errors, isinstance(artifact.get("required"), bool), f"artifacts[{index}].required must be boolean")
        add_error(errors, nonnegative_int(artifact.get("revision")), f"artifacts[{index}].revision must be a non-negative integer")
        add_error(errors, artifact.get("status") in ARTIFACT_STATES, f"artifacts[{index}].status is invalid")
        add_error(errors, isinstance(artifact.get("evidence"), list), f"artifacts[{index}].evidence must be an array")
        if artifact.get("required") is True and (artifact.get("status") != "CURRENT" or artifact.get("revision") != revision):
            artifacts_current = False
        if artifact.get("required") is True:
            required_artifact_count += 1
            evidence = artifact.get("evidence")
            if not isinstance(evidence, list) or not any(nonempty_string(item) for item in evidence):
                artifacts_current = False
    add_error(errors, required_artifact_count > 0, "at least one artifact must be required")

    hygiene = mapping(data, "hygiene", errors)
    add_error(errors, nonnegative_int(hygiene.get("unresolved_placeholders")), "hygiene.unresolved_placeholders must be a non-negative integer")
    add_error(errors, hygiene.get("secret_scan") in SECRET_SCAN_STATES, "hygiene.secret_scan is invalid")
    secret_evidence = hygiene.get("secret_scan_evidence")
    add_error(errors, isinstance(secret_evidence, list), "hygiene.secret_scan_evidence must be an array")
    if hygiene.get("secret_scan") == "PASS":
        add_error(errors, isinstance(secret_evidence, list) and any(nonempty_string(item) for item in secret_evidence), "secret scan PASS requires evidence")
    serialized = json.dumps(data, ensure_ascii=False)
    template_markers_present = "REPLACE_WITH" in serialized or "sha256:UNSET" in serialized
    hygiene_done = (
        hygiene.get("unresolved_placeholders") == 0
        and hygiene.get("secret_scan") == "PASS"
        and isinstance(secret_evidence, list)
        and any(nonempty_string(item) for item in secret_evidence)
        and not template_markers_present
    )

    change_log = data.get("change_log")
    add_error(errors, isinstance(change_log, list), "change_log must be an array")

    no_local = local_candidates == 0

    def check_state(done: bool, check_id: str, inherently_blocked: bool = False) -> str:
        if done:
            return "DONE"
        if no_local and (inherently_blocked or blockers_by_check.get(check_id, 0) > 0):
            return "BLOCKED"
        return "OPEN"

    checks = {
        "T1": check_state(open_p0 == 0 and open_p1 == 0, "T1"),
        "T2": check_state(acceptance_pending == 0, "T2", acceptance_blocked > 0),
        "T3": check_state(audit_done, "T3"),
        "T4": check_state(score_stable and floors_met, "T4"),
        "T5": check_state(required_gate_count > 0 and required_gates_pass, "T5", required_gate_blocked > 0),
        "T6": check_state(artifacts_current and hygiene_done, "T6", hygiene.get("secret_scan") == "BLOCKED"),
        "T7": check_state(no_local and blocked_candidates == 0 and open_required_blockers == 0 and invalid_deferrals == 0, "T7", blocked_candidates > 0 or open_required_blockers > 0),
    }

    all_done = all(value == "DONE" for value in checks.values())
    has_blocking_work = (
        open_required_blockers > 0
        or blocked_candidates > 0
        or acceptance_blocked > 0
        or required_gate_blocked > 0
        or hygiene.get("secret_scan") == "BLOCKED"
    )
    if all_done:
        derived_status = "TERMINATED"
    elif budget_exhausted:
        derived_status = "BUDGET"
    elif no_local and has_blocking_work:
        derived_status = "BLOCKED"
    else:
        derived_status = "CONTINUE"

    termination = mapping(data, "termination", errors)
    declared_checks = termination.get("checks")
    if not isinstance(declared_checks, dict):
        errors.append("termination.checks must be an object")
        declared_checks = {}
    else:
        add_error(errors, set(declared_checks) == set(CHECK_IDS), "termination.checks must contain exactly T1 through T7")
        for check_id in CHECK_IDS:
            add_error(errors, declared_checks.get(check_id) in CHECK_STATUSES, f"termination.checks.{check_id} is invalid")
    add_error(errors, termination.get("claim") in STATUSES, "termination.claim is invalid")
    add_error(errors, nonempty_string(termination.get("reason")), "termination.reason must be non-empty")

    resume = mapping(data, "resume", errors)
    add_error(errors, nonempty_string(resume.get("next_action")), "resume.next_action must contain exactly one actionable step")
    if isinstance(resume.get("next_action"), str) and "\n" in resume["next_action"].strip():
        warnings.append("resume.next_action contains multiple lines; keep one actionable step")

    if check_claims:
        add_error(errors, data.get("status") == derived_status, f"status must equal derived status {derived_status}")
        add_error(errors, termination.get("claim") == derived_status, f"termination.claim must equal derived status {derived_status}")
        for check_id in CHECK_IDS:
            add_error(errors, declared_checks.get(check_id) == checks[check_id], f"termination.checks.{check_id} must be {checks[check_id]}")

    if template_markers_present:
        warnings.append("template markers remain; T6 must stay OPEN until they are replaced and evidenced")

    return {
        "valid": not errors,
        "errors": errors,
        "warnings": warnings,
        "derived_status": derived_status,
        "checks": checks,
        "computed_score": computed_score,
        "dimension_ratios": dimension_ratios,
        "budget_exhausted": budget_exhausted,
        "local_candidates": local_candidates,
        "blocked_candidates": blocked_candidates,
        "open_required_blockers": open_required_blockers,
        "qualifying_audit_rounds": [item["iteration"] for item in qualifying_rounds],
    }


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        delete=False,
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    temp_path = Path(handle.name)
    try:
        with handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def escape_cell(value: Any) -> str:
    if value is None:
        return "—"
    return str(value).replace("|", "\\|").replace("\n", " ")


def render_markdown(data: dict[str, Any], result: dict[str, Any]) -> str:
    target = data["target"]
    budget = data["budget"]
    checkpoint = data["checkpoint"]
    defects = data["defects"]
    acceptance = data["acceptance"]
    dimensions = data["score"]["dimensions"]
    lines = [
        "# EXECUTION_STATE — ZCode 持续迭代控制视图",
        "",
        "> 本文件由 `ITERATION_STATE.json` 渲染；JSON 是唯一机器权威。",
        "",
        f"- Run: `{escape_cell(data['run_id'])}`",
        f"- Revision / iteration / phase: `{data['revision']}` / `{data['iteration']}` / `{data['phase']}`",
        f"- Status: **{result['derived_status']}**",
        f"- Target: `{target['level']}` / {target['score']}；当前 {result['computed_score']}",
        f"- Checkpoint: `{escape_cell(checkpoint['id'])}` · Git `{escape_cell(checkpoint['git_head'])}` · `{escape_cell(checkpoint['diff_fingerprint'])}`",
        f"- Budget: `{budget['kind']}` · used `{budget['used']}` / limit `{escape_cell(budget['limit'])}`",
        "",
        "## TERMINATION_CHECKLIST",
        "",
        "| Check | Derived |",
        "|---|---|",
    ]
    for check_id in CHECK_IDS:
        lines.append(f"| {check_id} | {result['checks'][check_id]} |")

    lines.extend(
        [
            "",
            "## Defects and acceptance",
            "",
            f"- Open defects P0/P1/P2/P3: `{defects['P0']}/{defects['P1']}/{defects['P2']}/{defects['P3']}`",
            "- Acceptance: " + ", ".join(f"{state}={acceptance[state]}" for state in sorted(ACCEPTANCE_STATES)),
            "",
            "## Score",
            "",
            "| Dimension | Earned / possible | Ratio | Contribution |",
            "|---|---:|---:|---:|",
        ]
    )
    for name, weight in DIMENSION_WEIGHTS.items():
        item = dimensions[name]
        ratio = result["dimension_ratios"][name]
        lines.append(f"| {name} ({weight}) | {item['earned']} / {item['possible']} | {ratio:.1%} | {weight * ratio:.2f} |")
    lines.append(f"| **Total** |  |  | **{result['computed_score']}** |")

    lines.extend(["", "## Gates", "", "| ID | Required | Status | Checkpoint | Evidence |", "|---|---|---|---|---|"])
    for gate in data["gates"]:
        evidence = ", ".join(map(str, gate.get("evidence", []))) or "—"
        lines.append(f"| {escape_cell(gate.get('id'))} | {gate.get('required')} | {escape_cell(gate.get('status'))} | {escape_cell(gate.get('checkpoint_id'))} | {escape_cell(evidence)} |")

    lines.extend(["", "## Audits", "", "| ID | Iteration | Reviewer | Risk | Checkpoint | Coverage | New P0/P1 |", "|---|---:|---|---|---|---|---:|"])
    if data["audits"]:
        for audit in data["audits"]:
            lines.append(
                f"| {escape_cell(audit.get('id'))} | {escape_cell(audit.get('iteration'))} | {escape_cell(audit.get('reviewer_id'))} | "
                f"{escape_cell(audit.get('risk'))} | {escape_cell(audit.get('checkpoint_id'))} | {escape_cell(', '.join(audit.get('coverage', [])))} | "
                f"{escape_cell(audit.get('new_p0'))}/{escape_cell(audit.get('new_p1'))} |"
            )
    else:
        lines.append("| — | — | — | — | — | — | — |")

    lines.extend(["", "## Candidates", "", "| ID | Severity | Required | Status | Blocker / defer reason |", "|---|---|---|---|---|"])
    if data["candidates"]:
        for candidate in data["candidates"]:
            detail = candidate.get("blocker_id") or candidate.get("defer_reason") or "—"
            lines.append(f"| {escape_cell(candidate.get('id'))} | {escape_cell(candidate.get('severity'))} | {candidate.get('required_for_target')} | {escape_cell(candidate.get('status'))} | {escape_cell(detail)} |")
    else:
        lines.append("| — | — | — | — | — |")

    lines.extend(["", "## Blockers", "", "| ID | Type | Required | Status | Recommendation | Unlock |", "|---|---|---|---|---|---|"])
    if data["blockers"]:
        for blocker in data["blockers"]:
            lines.append(f"| {escape_cell(blocker.get('id'))} | {escape_cell(blocker.get('type'))} | {blocker.get('required_for_target')} | {escape_cell(blocker.get('status'))} | {escape_cell(blocker.get('recommended_option'))} | {escape_cell(blocker.get('unlock_condition'))} |")
    else:
        lines.append("| — | — | — | — | — | — |")

    lines.extend(
        [
            "",
            "## Resume",
            "",
            f"**Next action:** {escape_cell(data['resume']['next_action'])}",
            "",
            f"Validation: `valid={str(result['valid']).lower()}` · derived `{result['derived_status']}` · qualifying audit rounds `{result['qualifying_audit_rounds']}`.",
            "",
        ]
    )
    return "\n".join(lines)


DEFECT_REF = re.compile(r"\bD-\d{8}-\d{2}\b")
EVIDENCE_REF = re.compile(r"^E-\d+$")
DECISION_REF = re.compile(r"^DEC-\d+$")
CODE_DIRS = ("lib", "test", "tools", "scripts")
CODE_SUFFIXES = (".dart", ".py", ".sh", ".mjs", ".js", ".kt", ".java")


def _strip_annotation(value: str) -> str:
    """`docs/X.md（A-01）` -> `docs/X.md`; evidence entries may carry a locator suffix."""
    for sep in ("（", "("):
        if sep in value:
            return value.split(sep, 1)[0].strip()
    return value.strip()


def _sha256_file(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def _artifact_path(data: dict[str, Any], suffix: str, default: str) -> str:
    for artifact in data.get("artifacts", []) or []:
        path = artifact.get("path") if isinstance(artifact, dict) else None
        if isinstance(path, str) and path.endswith(suffix):
            return path
    return default


def check_repo_links(data: dict[str, Any], repo_root: Path) -> tuple[list[str], list[str]]:
    """Cross-check the state file against the repository it describes.

    The structural validator proves the contract; this proves the *references*:
    every evidence log, audit report and artifact the state claims must exist,
    ledger ids must resolve, the acceptance matrix must match the latest score
    history hash, defect ids cited in code must be registered, and DONE
    candidates must point at a real audit. Returns (errors, warnings).
    """
    errors: list[str] = []
    warnings: list[str] = []
    root = repo_root.resolve()

    def exists(rel: str) -> bool:
        return (root / rel).exists()

    def read_doc(rel: str) -> str:
        path = root / rel
        return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""

    evidence_doc = read_doc(_artifact_path(data, "EVIDENCE.md", "docs/EVIDENCE.md"))
    decisions_doc = read_doc(_artifact_path(data, "DECISIONS.md", "docs/DECISIONS.md"))
    defects_doc = read_doc(_artifact_path(data, "DEFECTS.md", "docs/DEFECTS.md"))
    matrix_rel = _artifact_path(data, "ACCEPTANCE_MATRIX.md", "docs/ACCEPTANCE_MATRIX.md")

    def check_ref(owner: str, ref: Any) -> None:
        if not isinstance(ref, str) or not ref:
            errors.append(f"{owner}: evidence entry must be a non-empty string")
            return
        if EVIDENCE_REF.match(ref):
            if f"| {ref} |" not in evidence_doc:
                errors.append(f"{owner}: evidence id {ref} not found in EVIDENCE ledger")
            return
        if DECISION_REF.match(ref):
            if not re.search(r"(?<![A-Za-z0-9-])" + re.escape(ref) + r"(?![0-9])", decisions_doc):
                errors.append(f"{owner}: decision id {ref} not found in DECISIONS ledger")
            return
        rel = ref.strip() if exists(ref.strip()) else _strip_annotation(ref)
        if "/" in rel or rel.endswith((".md", ".log", ".json", ".txt")):
            if not exists(rel):
                errors.append(f"{owner}: referenced file missing: {rel}")
            return
        warnings.append(f"{owner}: unrecognised evidence reference {ref!r} (not a file, E-id or DEC-id)")

    for gate in data.get("gates", []) or []:
        if not isinstance(gate, dict):
            continue
        gate_id = gate.get("id", "?")
        status = gate.get("status")
        evidence = gate.get("evidence") or []
        if gate.get("required") and status in ("PASS", "FAIL", "BLOCKED") and not evidence:
            errors.append(f"gate {gate_id}: status {status} but no evidence recorded")
        for ref in evidence:
            check_ref(f"gate {gate_id}", ref)

    audit_ids: set[str] = set()
    for audit in data.get("audits", []) or []:
        if not isinstance(audit, dict):
            continue
        audit_ids.add(str(audit.get("id")))
        report = audit.get("report")
        if not isinstance(report, str) or not exists(report):
            errors.append(f"audit {audit.get('id', '?')}: report missing on disk: {report!r}")

    for artifact in data.get("artifacts", []) or []:
        if not isinstance(artifact, dict):
            continue
        path = artifact.get("path", "?")
        if not isinstance(path, str) or not exists(path):
            errors.append(f"artifact missing on disk: {path!r}")
        for ref in artifact.get("evidence") or []:
            check_ref(f"artifact {path}", ref)

    hygiene = data.get("hygiene") or {}
    for ref in hygiene.get("secret_scan_evidence") or []:
        check_ref("hygiene.secret_scan_evidence", ref)

    for blocker in data.get("blockers", []) or []:
        if not isinstance(blocker, dict):
            continue
        for ref in blocker.get("evidence") or []:
            check_ref(f"blocker {blocker.get('id', '?')}", ref)

    history = ((data.get("score") or {}).get("history")) or []
    if history and exists(matrix_rel):
        latest = history[-1]
        declared = latest.get("source_hash") if isinstance(latest, dict) else None
        actual = _sha256_file(root / matrix_rel)
        if declared != actual:
            errors.append(
                f"acceptance matrix {matrix_rel} changed since score.history[-1] "
                f"(declared {str(declared)[:19]}…, actual {actual[:19]}…): record a new history entry"
            )
    elif history:
        errors.append(f"acceptance matrix missing on disk: {matrix_rel}")

    cited: dict[str, str] = {}
    for directory in CODE_DIRS:
        base = root / directory
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or path.suffix not in CODE_SUFFIXES:
                continue
            # Python self-tests carry synthetic defect ids as fixtures (iter3 F-1).
            if path.suffix == ".py" and path.name.startswith("test_"):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for match in DEFECT_REF.findall(text):
                cited.setdefault(match, path.relative_to(root).as_posix())
    for defect_id, where in sorted(cited.items()):
        if defect_id not in defects_doc:
            errors.append(f"defect {defect_id} cited in {where} is not registered in DEFECTS ledger")

    for candidate in data.get("candidates", []) or []:
        if not isinstance(candidate, dict) or candidate.get("status") != "DONE":
            continue
        review_id = candidate.get("review_id")
        if not review_id:
            errors.append(f"candidate {candidate.get('id', '?')}: DONE without review_id")
        elif str(review_id) not in audit_ids:
            errors.append(f"candidate {candidate.get('id', '?')}: review_id {review_id} is not a recorded audit")

    return errors, warnings


def _tracked_reference_paths(data: dict[str, Any], root: Path) -> list[str]:
    """Repo-relative paths --require-tracked must find in the git index.

    Scope (W-015): source_map targets, gate evidence and audit reports.
    Ledger ids (E-/DEC-) and unrecognised references are not file paths, only
    in-repo relative paths are validated, and test_*.py fixtures are exempt
    (iter3 F-1).
    """
    refs: list[str] = []
    source_map = data.get("source_map")
    if isinstance(source_map, dict):
        refs.extend(value for value in source_map.values() if isinstance(value, str))
    for gate in data.get("gates", []) or []:
        if isinstance(gate, dict):
            refs.extend(item for item in gate.get("evidence", []) or [] if isinstance(item, str))
    for audit in data.get("audits", []) or []:
        if isinstance(audit, dict) and isinstance(audit.get("report"), str):
            refs.append(audit["report"])

    targets: list[str] = []
    for ref in refs:
        value = ref.strip()
        if not value or "://" in value:
            continue
        if EVIDENCE_REF.match(value) or DECISION_REF.match(value):
            continue
        # A real path containing "(" wins over the annotation split (iter3 F-7).
        candidate = value if (root / value).exists() else _strip_annotation(value)
        candidate = candidate.replace("\\", "/")
        if candidate.startswith("/") or ":" in candidate.split("/", 1)[0]:
            continue  # outside the repository: absolute path or scheme/drive prefix
        candidate = candidate.strip("/")
        segments = candidate.split("/")
        if not candidate or ".." in segments:
            continue
        if candidate.endswith(".py") and segments[-1].startswith("test_"):
            continue  # python self-tests carry synthetic ids as fixtures (iter3 F-1)
        if ("/" in candidate or candidate.endswith((".md", ".log", ".json", ".txt"))) and candidate not in targets:
            targets.append(candidate)
    return targets


def check_tracked_files(data: dict[str, Any], repo_root: Path) -> tuple[list[str], list[str]]:
    """Require referenced evidence/report/source_map paths to be git-tracked.

    Runs `git ls-files --error-unmatch` against repo_root for every path
    _tracked_reference_paths collects. When repo_root is not inside a git work
    tree, or git is unavailable, tracking cannot be proven: degrade to one
    warning and no errors — the same silent fallback the repo's shell gates
    use for git failures (gates.sh/clean_start.sh `2>/dev/null`).
    Returns (errors, warnings).
    """
    errors: list[str] = []
    warnings: list[str] = []
    root = repo_root.resolve()
    targets = _tracked_reference_paths(data, root)
    if not targets:
        return errors, warnings
    try:
        probe = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        warnings.append("git tracking not verified: git command unavailable")
        return errors, warnings
    if probe.returncode != 0 or probe.stdout.strip() != "true":
        warnings.append("git tracking not verified: repo_root is not a git work tree")
        return errors, warnings
    for target in targets:
        try:
            completed = subprocess.run(
                ["git", "ls-files", "--error-unmatch", "--", target],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            warnings.append("git tracking not verified: git command unavailable")
            break
        if completed.returncode != 0:
            errors.append(f"referenced file not git-tracked: {target}")
    return errors, warnings


def apply_repo_checks(
    result: dict[str, Any],
    data: dict[str, Any],
    repo_root: Path | None,
    require_tracked: bool = False,
) -> None:
    if repo_root is None:
        if require_tracked:
            result["warnings"].append("require-tracked ignored: --repo-root not provided")
        return
    errors, warnings = check_repo_links(data, repo_root)
    if require_tracked:
        tracked_errors, tracked_warnings = check_tracked_files(data, repo_root)
        errors.extend(tracked_errors)
        warnings.extend(tracked_warnings)
    result["errors"].extend(errors)
    result["warnings"].extend(warnings)
    if errors:
        result["valid"] = False


def print_result(result: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    print(f"valid={str(result['valid']).lower()}")
    print(f"derived_status={result['derived_status']}")
    print(f"computed_score={result['computed_score']}")
    print("checks=" + ",".join(f"{key}:{result['checks'][key]}" for key in CHECK_IDS))
    for warning in result["warnings"]:
        print(f"WARNING: {warning}")
    for error in result["errors"]:
        print(f"ERROR: {error}")


def command_validate(args: argparse.Namespace) -> int:
    try:
        data = load_state(args.state)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    result = analyze(data, check_claims=True)
    apply_repo_checks(result, data, args.repo_root, require_tracked=args.require_tracked)
    print_result(result, args.json)
    return 0 if result["valid"] else 1


def command_derive(args: argparse.Namespace) -> int:
    try:
        data = load_state(args.state)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    result = analyze(data, check_claims=False)
    print_result(result, True)
    return 0 if result["valid"] else 1


def command_sync(args: argparse.Namespace) -> int:
    try:
        data = load_state(args.state)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    result = analyze(data, check_claims=False)
    if not result["valid"]:
        print_result(result, False)
        print("ERROR: refusing to sync structurally invalid state", file=sys.stderr)
        return 1
    data["status"] = result["derived_status"]
    data["termination"]["claim"] = result["derived_status"]
    data["termination"]["checks"] = result["checks"]
    if args.reason:
        data["termination"]["reason"] = args.reason
    atomic_write_json(args.state, data)
    verified = analyze(data, check_claims=True)
    apply_repo_checks(verified, data, args.repo_root)
    print_result(verified, args.json)
    return 0 if verified["valid"] else 1


def command_render(args: argparse.Namespace) -> int:
    try:
        data = load_state(args.state)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    result = analyze(data, check_claims=True)
    apply_repo_checks(result, data, args.repo_root)
    if not result["valid"]:
        print_result(result, False)
        print("ERROR: refusing to render invalid or inconsistent state", file=sys.stderr)
        return 1
    markdown = render_markdown(data, result)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(markdown, encoding="utf-8", newline="\n")
        print(str(args.output))
    else:
        print(markdown)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate", help="validate structure and declared derived state")
    validate_parser.add_argument("state", type=Path)
    validate_parser.add_argument("--json", action="store_true", help="emit JSON diagnostics")
    validate_parser.add_argument("--repo-root", type=Path, default=None, help="also verify evidence/report/artifact paths, ledger ids, matrix hash, defect refs and review ids against this repository")
    validate_parser.add_argument(
        "--require-tracked",
        action="store_true",
        help="additionally require source_map targets, gate evidence and audit reports to be git-tracked (git ls-files --error-unmatch)",
    )
    validate_parser.set_defaults(func=command_validate)

    derive_parser = subparsers.add_parser("derive", help="derive checks/status without modifying the file")
    derive_parser.add_argument("state", type=Path)
    derive_parser.set_defaults(func=command_derive)

    sync_parser = subparsers.add_parser("sync", help="atomically synchronize status and T1-T7 from facts")
    sync_parser.add_argument("state", type=Path)
    sync_parser.add_argument("--reason", help="replace termination.reason")
    sync_parser.add_argument("--json", action="store_true", help="emit JSON diagnostics")
    sync_parser.add_argument("--repo-root", type=Path, default=None, help="also verify evidence/report/artifact paths, ledger ids, matrix hash, defect refs and review ids against this repository")
    sync_parser.set_defaults(func=command_sync)

    render_parser = subparsers.add_parser("render", help="render a validated human-readable Markdown view")
    render_parser.add_argument("state", type=Path)
    render_parser.add_argument("--output", type=Path)
    render_parser.add_argument("--repo-root", type=Path, default=None, help="also verify evidence/report/artifact paths, ledger ids, matrix hash, defect refs and review ids against this repository")
    render_parser.set_defaults(func=command_render)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
