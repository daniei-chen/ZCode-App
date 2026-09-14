#!/usr/bin/env python3
"""依赖漏洞门禁（v1.1.0 / PR19，F22）：用 OSV 查 SBOM 里每个随包发布的组件。

为什么自建而不是只靠 GitHub dependency-review：
  1. dependency-review 依赖仓库 Dependency Graph 的数据；本项目实测在数据就绪前
     它直接报 "not supported"，只能 continue-on-error，等于没有门禁；
  2. 我们要的是"随 APK 发布的依赖"这一确定集合——SBOM 里 scope != excluded 的
     组件，而不是 PR 里改动了哪些清单文件；
  3. 结论需要可复核：哪条 advisory、哪个版本、什么严重度、例外还是阻断。

规则：
  * 默认阻断 high 及以上（`--fail-on high`）；
  * 例外必须写在 scripts/security-exceptions.json 里，带 reason 与 expires
    （UTC 日期）；过期的例外本身算错误，避免"临时豁免"永久留存；
  * OSV 不可达时默认**失败**（发布不允许在未知依赖状态下进行）；
    只有显式 `--soft-fail-if-unreachable` 才降级为告警（PR 侧使用）。

网络面：只允许 https://api.osv.dev，且解析后的 IP 不能是环回/私网/链路本地地址，
重定向一律拒绝——门禁脚本自己不能成为 SSRF 出口。

用法：
  python3 scripts/check-dependency-advisories.py --sbom sbom.json
  python3 scripts/check-dependency-advisories.py --sbom sbom.json --offline-fixture fixture.json
  python3 scripts/check-dependency-advisories.py --self-test
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OSV_HOST = "api.osv.dev"
OSV_BATCH_URL = f"https://{OSV_HOST}/v1/querybatch"
OSV_VULN_URL = f"https://{OSV_HOST}/v1/vulns/{{id}}"
DEFAULT_EXCEPTIONS = ROOT / "scripts" / "security-exceptions.json"
DEFAULT_THRESHOLD = "high"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_DETAIL_FETCHES = 50

SEVERITY_RANK = {"low": 1, "moderate": 2, "medium": 2, "high": 3, "critical": 4}

# CVSS 分数 → 等级（OSV 只给分数时用它换算）。
CVSS_BANDS = ((9.0, "critical"), (7.0, "high"), (4.0, "moderate"), (0.1, "low"))


# --------------------------------------------------------- CVSS vector parsing
#
# 审计 R-08：OSV schema 允许 severity[].score 是 **CVSS 向量字符串**（如
# `CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H`），旧实现只看纯数字、见到
# `CVSS:` 前缀就 continue，向量一律落进 unknown → rank 0 → "低于阈值"桶，
# 高危向量在 `--fail-on high` 下静默放行（合成夹具已复现）。
#
# 这里实现 CVSS v2 / v3.x / v4.0 的基础分（base score）解析：
#   * v3.x：标准公式（ISS/Impact/Exploitability，Scope 变更时改权重）；
#   * v2：Impact/Exploitability 公式；
#   * v4：评分需要 MacroVector 查表，实现成本高且易错——按"显式 unknown"
#     处理（进入 unassessed），绝不当成低危。
# 解析失败一律 None（→ unassessed），不猜。

_CVSS_V3_AV = {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2}
_CVSS_V3_AC = {"L": 0.77, "H": 0.44}
_CVSS_V3_PR_U = {"N": 0.85, "L": 0.62, "H": 0.27}
_CVSS_V3_PR_C = {"N": 0.85, "L": 0.68, "H": 0.5}
_CVSS_V3_UI = {"N": 0.85, "R": 0.62}
_CVSS_V3_CIA = {"H": 0.56, "L": 0.22, "N": 0.0}

_CVSS_V2_AV = {"L": 0.395, "A": 0.646, "N": 1.0}
_CVSS_V2_AC = {"H": 0.35, "M": 0.61, "L": 0.71}
_CVSS_V2_AU = {"M": 0.45, "S": 0.56, "N": 0.704}
_CVSS_V2_CIA = {"N": 0.0, "P": 0.275, "C": 0.660}


def _round_up(value: float) -> float:
    """CVSS v3 的 roundup（一位小数，向上取整到 0.1）。"""
    import math

    integer = int(value * 100000)
    return math.ceil(integer / 10000.0) / 10.0


def _cvss_v3_score(parts: dict[str, str]) -> float | None:
    try:
        scope_changed = parts["S"] == "C"
        av = _CVSS_V3_AV[parts["AV"]]
        ac = _CVSS_V3_AC[parts["AC"]]
        pr = (_CVSS_V3_PR_C if scope_changed else _CVSS_V3_PR_U)[parts["PR"]]
        ui = _CVSS_V3_UI[parts["UI"]]
        c = _CVSS_V3_CIA[parts["C"]]
        i = _CVSS_V3_CIA[parts["I"]]
        a = _CVSS_V3_CIA[parts["A"]]
    except KeyError:
        return None
    iss = 1 - ((1 - c) * (1 - i) * (1 - a))
    if scope_changed:
        impact = 7.52 * (iss - 0.029) - 3.25 * ((iss - 0.02) ** 15)
    else:
        impact = 6.42 * iss
    exploitability = 8.22 * av * ac * pr * ui
    if impact <= 0:
        return 0.0
    raw = min((1.08 if scope_changed else 1.0) * (impact + exploitability), 10.0)
    return _round_up(raw)


def _cvss_v2_score(parts: dict[str, str]) -> float | None:
    try:
        av = _CVSS_V2_AV[parts["AV"]]
        ac = _CVSS_V2_AC[parts["AC"]]
        au = _CVSS_V2_AU[parts["Au"]]
        c = _CVSS_V2_CIA[parts["C"]]
        i = _CVSS_V2_CIA[parts["I"]]
        a = _CVSS_V2_CIA[parts["A"]]
    except KeyError:
        return None
    impact = 10.41 * (1 - (1 - c) * (1 - i) * (1 - a))
    exploitability = 20 * av * ac * au
    if impact == 0:
        return 0.0
    f_impact = 1.176 if impact > 0 else 1.0
    # v2 没有 S 维度；环境分不参与（只用 base）。
    return round(min(impact * f_impact + exploitability, 10.0) * 10) / 10.0


def parse_cvss_score(raw: str) -> float | None:
    """把 OSV 的 severity[].score 解析成基础分；无法可靠解析时返回 None。"""
    text = raw.strip()
    # 纯数字（OSV 的旧式写法）。
    try:
        number = float(text)
        return number if 0.0 <= number <= 10.0 else None
    except ValueError:
        pass
    if not text.upper().startswith("CVSS:"):
        # OSV 的 CVSS_V2 条目是**裸向量**（无 `CVSS:2.0/` 前缀），例如
        # `AV:N/AC:L/Au:N/C:C/I:C/A:C`。按特征识别为 v2，而不是回落成
        # 未评估（会把已知 10.0 的高危当成 unknown）。
        if text.upper().startswith("AV:"):
            return _cvss_v2_score(_cvss_parts(text))
        return None
    body = text.split(":", 1)[1]
    if not body:
        return None
    version_part, _, metrics = body.partition("/")
    version = version_part.strip().upper()
    if version.startswith("4"):
        # v4 需要 MacroVector 查表；按 unassessed 处理（不猜低危）。
        return None
    parts = _cvss_parts(metrics)
    if version.startswith("3"):
        return _cvss_v3_score(parts)
    if version.startswith("2"):
        return _cvss_v2_score(parts)
    return None


def _cvss_parts(metrics: str) -> dict[str, str]:
    parts: dict[str, str] = {}
    for segment in metrics.split("/"):
        key, _, value = segment.partition(":")
        if key and value:
            parts[key.strip()] = value.strip()
    return parts


def severity_from_score(score: float | None) -> str | None:
    if score is None:
        return None
    for threshold, label in CVSS_BANDS:
        if score >= threshold:
            return label
    return None


# ---------------------------------------------------------------- network guard


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """OSV 不需要重定向；重定向意味着目标可能已经离开白名单主机。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        raise urllib.error.HTTPError(
            req.full_url, code, f"redirect blocked: {newurl}", headers, fp
        )


def assert_allowed_url(url: str) -> None:
    """只放行固定的 https://api.osv.dev，并阻断指向内网的解析结果。"""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https":
        raise ValueError(f"only https is allowed: {url}")
    if parsed.hostname != OSV_HOST:
        raise ValueError(f"host not allowed: {parsed.hostname}")
    if parsed.port not in (None, 443):
        raise ValueError(f"port not allowed: {parsed.port}")
    for family, _, _, _, sockaddr in socket.getaddrinfo(
        parsed.hostname, 443, proto=socket.IPPROTO_TCP
    ):
        address = ipaddress.ip_address(sockaddr[0])
        if (
            address.is_private
            or address.is_loopback
            or address.is_link_local
            or address.is_reserved
            or address.is_multicast
            or address.is_unspecified
        ):
            raise ValueError(f"resolved to a non-public address: {address}")


def http_json(url: str, payload: dict | None = None, timeout: int = 30) -> dict:
    assert_allowed_url(url)
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "User-Agent": "zcode-app-sbom-gate"},
        method="POST" if data is not None else "GET",
    )
    opener = urllib.request.build_opener(_NoRedirectHandler())
    with opener.open(request, timeout=timeout) as response:
        if response.status != 200:
            raise ValueError(f"unexpected status {response.status}")
        raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ValueError("response too large")
        return json.loads(raw.decode("utf-8"))


# ---------------------------------------------------------------- analysis


def severity_of(vuln: dict) -> tuple[str | None, str | None]:
    """从 OSV advisory 取严重度。

    返回 `(severity, reason)`：
      * severity 为 None 表示**无法判定**——调用方必须放进 unassessed 桶，
        不能当"低于阈值"（R-08：unknown 不得静默放行）。
      * reason 记录判定依据/失败原因（供审阅）。
    """
    database_specific = vuln.get("database_specific") or {}
    raw = database_specific.get("severity")
    if isinstance(raw, str) and raw.lower() in SEVERITY_RANK:
        return raw.lower(), "database_specific"
    saw_vector = False
    for entry in vuln.get("severity") or []:
        if not isinstance(entry, dict):
            continue
        score = entry.get("score")
        if not isinstance(score, str):
            continue
        if score.strip().upper().startswith("CVSS:"):
            saw_vector = True
        number = parse_cvss_score(score)
        label = severity_from_score(number)
        if label is not None:
            return label, f"cvss:{'vector' if saw_vector else 'number'}"
    if saw_vector:
        return None, "cvss_vector_unparsed"
    return None, "no_severity_data"


def load_exceptions(path: Path) -> tuple[list[dict], list[str]]:
    errors: list[str] = []
    if not path.is_file():
        return [], []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [], [f"cannot read exceptions {path}: {exc}"]
    if not isinstance(data, dict):
        return [], [f"exceptions file {path} must be an object with an 'exceptions' list"]
    entries = data.get("exceptions")
    if entries is None:
        return [], [f"exceptions file {path} has no 'exceptions' list"]
    if not isinstance(entries, list):
        return [], [f"exceptions file {path}: 'exceptions' must be a list"]
    cleaned: list[dict] = []
    today = datetime.now(timezone.utc).date()
    for entry in entries:
        if not isinstance(entry, dict):
            errors.append(f"exception entry is not an object: {entry!r}")
            continue
        if not entry.get("id") or not entry.get("reason"):
            errors.append(f"exception needs id and reason: {entry!r}")
            continue
        expires = entry.get("expires")
        if not expires:
            errors.append(f"exception {entry.get('id')} needs an expiry date")
            continue
        try:
            expiry = date.fromisoformat(str(expires))
        except ValueError:
            errors.append(f"exception {entry.get('id')}: expires must be YYYY-MM-DD")
            continue
        if expiry < today:
            errors.append(f"exception {entry.get('id')} expired on {expiry.isoformat()}")
            continue
        cleaned.append(entry)
    return cleaned, errors


def exception_matches(entry: dict, purl: str, vuln_id: str) -> bool:
    target = entry.get("id")
    if target not in (purl, vuln_id):
        return False
    scope_purl = entry.get("purl")
    return not scope_purl or scope_purl == purl


def collect_purls(sbom: dict) -> list[str]:
    """随包发布的组件（scope != excluded）；dev 依赖不进 APK，不参与门禁。"""
    purls: list[str] = []
    for component in sbom.get("components") or []:
        if not isinstance(component, dict):
            continue
        if component.get("scope") == "excluded":
            continue
        purl = component.get("purl")
        if not isinstance(purl, str):
            continue
        # 自建原生库/根组件没有上游 advisory 数据，跳过。
        if purl.startswith(("pkg:pub/", "pkg:maven/")):
            purls.append(purl)
    return sorted(set(purls))


def analyze(
    purls: list[str],
    batch: dict,
    details: dict[str, dict],
    exceptions: list[dict],
    threshold: str,
) -> dict[str, list[dict]]:
    """把命中分成四桶：blocking / waived / below / unassessed。

    * blocking：达到阈值且未豁免；
    * waived：命中例外（带 reason + expires）；
    * below：明确判定为低于阈值；
    * unassessed（R-08）：**无法判定严重度**（CVSS 向量解析失败、详情取不到、
      缺 severity 字段等）。它不再是 below 的一部分：release 下未评估的 advisory
      必须阻断（fail-closed），PR 侧也要原样打印，不能被阈值悄悄藏起来。

    PR 侧只用 critical 阻断，但 high/moderate 仍要打印出来——"只报告不阻断"不等于
    "看不见"。
    """
    limit = SEVERITY_RANK.get(threshold.lower(), 3)
    blocking: list[dict] = []
    waived: list[dict] = []
    below: list[dict] = []
    unassessed: list[dict] = []
    results = batch.get("results") or []
    if len(results) != len(purls):
        raise SystemExit(
            f"OSV batch 返回 {len(results)} 条结果，与 {len(purls)} 个组件不匹配"
        )
    for purl, result in zip(purls, results):
        for vuln in (result or {}).get("vulns") or []:
            vuln_id = str(vuln.get("id") or "")
            if not vuln_id:
                continue
            detail = details.get(vuln_id) or vuln
            severity, basis = severity_of(detail)
            if severity is None:
                severity, basis2 = severity_of(vuln)
                basis = basis2 if severity is not None else f"{basis}+{basis2}"
            rank = SEVERITY_RANK.get((severity or "").lower(), 0)
            finding = {
                "purl": purl,
                "id": vuln_id,
                "severity": severity or "unknown",
                "basis": basis,
                "aliases": [str(a) for a in (detail.get("aliases") or [])][:6],
                "summary": str(detail.get("summary") or "")[:200],
            }
            matched = next(
                (entry for entry in exceptions if exception_matches(entry, purl, vuln_id)),
                None,
            )
            if matched is not None:
                finding["exception"] = matched.get("reason")
                waived.append(finding)
            elif severity is None:
                # 未评估：既不是 blocking（没证据说它高危），也不是 below
                # （没证据说它低危）。单独成桶，由调用方按 fail-closed 处理。
                unassessed.append(finding)
            elif rank >= limit:
                blocking.append(finding)
            else:
                below.append(finding)
    return {
        "blocking": blocking,
        "waived": waived,
        "below": below,
        "unassessed": unassessed,
    }


def query_osv(purls: list[str], attempts: int = 3) -> tuple[dict, dict[str, dict]]:
    """批量查询 OSV；返回 (batch 响应, 漏洞详情)。"""
    batch: dict = {"results": []}
    for start in range(0, len(purls), 100):
        chunk = purls[start : start + 100]
        payload = {"queries": [{"package": {"purl": purl}} for purl in chunk]}
        last_error: Exception | None = None
        for _ in range(attempts):
            try:
                batch["results"].extend(http_json(OSV_BATCH_URL, payload).get("results") or [])
                last_error = None
                break
            except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
                last_error = exc
        if last_error is not None:
            raise last_error
    details: dict[str, dict] = {}
    ids = sorted(
        {
            str(vuln.get("id"))
            for result in batch.get("results") or []
            for vuln in (result or {}).get("vulns") or []
            if vuln.get("id")
        }
    )
    for vuln_id in ids[:MAX_DETAIL_FETCHES]:
        try:
            details[vuln_id] = http_json(OSV_VULN_URL.format(id=urllib.parse.quote(vuln_id)))
        except (urllib.error.URLError, TimeoutError, ValueError, OSError):
            continue  # 详情取不到就用 batch 里的最小信息，严重度按 unknown 处理
    return batch, details


# ---------------------------------------------------------------- self test


def _self_test() -> int:
    cases: list[tuple[str, bool]] = []

    def expect(name: str, condition: bool) -> None:
        cases.append((name, condition))
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")

    sbom = {
        "components": [
            {"purl": "pkg:pub/alpha@1.0.0", "scope": "required"},
            {"purl": "pkg:pub/dev-only@1.0.0", "scope": "excluded"},
            {"purl": "pkg:maven/g/a@2.0.0", "scope": "required"},
            {"purl": "pkg:generic/libapp.so@1.0.0", "scope": "required"},
        ]
    }
    purls = collect_purls(sbom)
    expect(
        "只扫描随包发布的 pub/maven 组件",
        purls == ["pkg:maven/g/a@2.0.0", "pkg:pub/alpha@1.0.0"],
    )

    batch_clean = {"results": [{"vulns": []}, {"vulns": []}]}
    cvss_clean = analyze(purls, batch_clean, {}, [], DEFAULT_THRESHOLD)
    expect(
        "无 advisory 时通过",
        not cvss_clean["blocking"]
        and not cvss_clean["waived"]
        and not cvss_clean["below"]
        and not cvss_clean["unassessed"],
    )

    batch = {
        "results": [
            {"vulns": [{"id": "OSV-2026-1"}, {"id": "OSV-2026-2"}]},
            {"vulns": [{"id": "OSV-2026-3"}]},
        ]
    }
    details = {
        "OSV-2026-1": {"database_specific": {"severity": "CRITICAL"}, "aliases": ["CVE-2026-1"]},
        "OSV-2026-2": {"database_specific": {"severity": "LOW"}},
        "OSV-2026-3": {"database_specific": {"severity": "HIGH"}},
    }
    outcome = analyze(purls, batch, details, [], DEFAULT_THRESHOLD)
    expect(
        "critical/high 阻断、low 进 below（可见但不阻断）",
        [f["id"] for f in outcome["blocking"]] == ["OSV-2026-1", "OSV-2026-3"]
        and [f["id"] for f in outcome["below"]] == ["OSV-2026-2"],
    )
    expect("别名透传（便于人工核对）", outcome["blocking"][0]["aliases"] == ["CVE-2026-1"])

    outcome = analyze(
        purls,
        batch,
        details,
        [{"id": "OSV-2026-1", "reason": "不可达代码路径", "expires": "2099-01-01"}],
        DEFAULT_THRESHOLD,
    )
    expect(
        "有效例外被豁免且不阻断",
        [f["id"] for f in outcome["blocking"]] == ["OSV-2026-3"]
        and len(outcome["waived"]) == 1,
    )

    outcome = analyze(purls, batch, details, [], "critical")
    expect(
        "阈值调到 critical 后只剩 critical 阻断，high/low 落到 below",
        [f["id"] for f in outcome["blocking"]] == ["OSV-2026-1"]
        and sorted(f["id"] for f in outcome["below"]) == ["OSV-2026-2", "OSV-2026-3"],
    )

    expect(
        "CVSS 纯数字分数换算严重度",
        severity_of({"severity": [{"score": "9.8"}]}) == ("critical", "cvss:number"),
    )
    # R-08 核心回归：合法 CVSS_V3 向量必须被解析出严重度（旧实现一律 None）。
    vector_high = "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"  # 9.8
    expect(
        "CVSS:3.1 全高危向量 → critical（9.8）",
        severity_of({"severity": [{"type": "CVSS_V3", "score": vector_high}]})
        == ("critical", "cvss:vector"),
    )
    expect(
        "CVSS v3 向量算分：中等向量 → 3.7（low 带）",
        parse_cvss_score("CVSS:3.1/AV:N/AC:H/PR:L/UI:R/S:U/C:L/I:L/A:N") == 3.7
        and severity_from_score(
            parse_cvss_score("CVSS:3.1/AV:N/AC:H/PR:L/UI:R/S:U/C:L/I:L/A:N")
        )
        == "low",
    )
    expect(
        "CVSS v3 向量算分：9.8 夹具精确等于 9.8",
        parse_cvss_score(vector_high) == 9.8,
    )
    expect(
        "CVSS v2 向量可解析",
        parse_cvss_score("AV:N/AC:L/Au:N/C:C/I:C/A:C") == 10.0,
    )
    expect(
        "CVSS v4 显式 unassessed（不猜低危）",
        severity_of({"severity": [{"type": "CVSS_V4", "score": "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N"}]})
        == (None, "cvss_vector_unparsed"),
    )
    expect(
        "格式错误的向量 → unassessed 而非低危",
        severity_of({"severity": [{"score": "CVSS:3.1/AV:Z"}]}) == (None, "cvss_vector_unparsed"),
    )
    expect("无严重度信息 → unassessed", severity_of({}) == (None, "no_severity_data"))

    # R-08：无法判定严重度的命中必须进 unassessed 桶，不得混进 below。
    batch_vector = {
        "results": [
            {"vulns": [{"id": "OSV-VEC"}, {"id": "OSV-LOW"}]},
            {"vulns": []},
        ]
    }
    details_vector = {
        "OSV-VEC": {"severity": [{"type": "CVSS_V3", "score": vector_high}]},
        "OSV-LOW": {"database_specific": {"severity": "LOW"}},
    }
    outcome = analyze(purls, batch_vector, details_vector, [], DEFAULT_THRESHOLD)
    expect(
        "R-08 夹具：9.8 的 CVSS_V3 向量在 --fail-on high 下进 blocking（旧实现退出码 0）",
        [f["id"] for f in outcome["blocking"]] == ["OSV-VEC"]
        and [f["id"] for f in outcome["below"]] == ["OSV-LOW"]
        and outcome["unassessed"] == [],
    )
    outcome = analyze(
        purls,
        {"results": [{"vulns": [{"id": "OSV-UNK"}]}, {"vulns": []}]},
        {"OSV-UNK": {"summary": "no severity"}},
        [],
        DEFAULT_THRESHOLD,
    )
    expect(
        "无法判定的 advisory 进 unassessed（不是 below）",
        [f["id"] for f in outcome["unassessed"]] == ["OSV-UNK"]
        and not outcome["below"],
    )

    with tempfile.TemporaryDirectory() as raw:
        path = Path(raw) / "exc.json"
        path.write_text(
            json.dumps(
                {
                    "exceptions": [
                        {"id": "OSV-1", "reason": "ok", "expires": "2099-01-01"},
                        {"id": "OSV-2", "reason": "expired", "expires": "2000-01-01"},
                        {"id": "OSV-3", "reason": "no expiry"},
                    ]
                }
            ),
            encoding="utf-8",
        )
        cleaned, errors = load_exceptions(path)
        expect("例外表：有效项保留、过期项报错", len(cleaned) == 1 and len(errors) == 2)
        path.write_text("[]", encoding="utf-8")
        _, errors = load_exceptions(path)
        expect("例外表结构不符时报错", bool(errors))

        # CLI 端到端（离线夹具）：阻断/放行与 below 输出都真实走一遍 main()。
        sbom_path = Path(raw) / "sbom.json"
        sbom_path.write_text(
            json.dumps(
                {
                    "components": [
                        {"purl": "pkg:pub/alpha@1.0.0", "scope": "required"},
                        {"purl": "pkg:pub/beta@2.0.0", "scope": "required"},
                    ]
                }
            ),
            encoding="utf-8",
        )
        empty_exceptions = Path(raw) / "empty.json"
        empty_exceptions.write_text('{"exceptions": []}', encoding="utf-8")
        blocking_fixture = Path(raw) / "fixture-blocking.json"
        blocking_fixture.write_text(
            json.dumps(
                {
                    "batch": {"results": [{"vulns": [{"id": "OSV-A"}]}, {"vulns": []}]},
                    "details": {"OSV-A": {"database_specific": {"severity": "HIGH"}}},
                }
            ),
            encoding="utf-8",
        )
        expect(
            "CLI：high 命中在 --fail-on high 下退出码 1",
            main(
                [
                    "--sbom",
                    str(sbom_path),
                    "--offline-fixture",
                    str(blocking_fixture),
                    "--exceptions",
                    str(empty_exceptions),
                    "--fail-on",
                    "high",
                ]
            )
            == 1,
        )
        expect(
            "CLI：同一条命中在 --fail-on critical 下放行（退出码 0，只打印 below）",
            main(
                [
                    "--sbom",
                    str(sbom_path),
                    "--offline-fixture",
                    str(blocking_fixture),
                    "--exceptions",
                    str(empty_exceptions),
                    "--fail-on",
                    "critical",
                ]
            )
            == 0,
        )
        exempt_fixture = Path(raw) / "exceptions.json"
        exempt_fixture.write_text(
            json.dumps(
                {
                    "exceptions": [
                        {"id": "OSV-A", "reason": "已评估", "expires": "2099-01-01"}
                    ]
                }
            ),
            encoding="utf-8",
        )
        expect(
            "CLI：登记例外后不再阻断",
            main(
                [
                    "--sbom",
                    str(sbom_path),
                    "--offline-fixture",
                    str(blocking_fixture),
                    "--exceptions",
                    str(exempt_fixture),
                    "--fail-on",
                    "high",
                ]
            )
            == 0,
        )

    try:
        analyze(purls, {"results": [{"vulns": []}]}, {}, [], DEFAULT_THRESHOLD)
        mismatch = False
    except SystemExit:
        mismatch = True
    expect("OSV 结果数量不匹配时失败", mismatch)

    # 网络面：非白名单主机/协议/端口/内网解析都必须拒绝
    for url, label in (
        ("http://api.osv.dev/v1/querybatch", "拒绝非 https"),
        ("https://evil.invalid/v1/querybatch", "拒绝非白名单主机"),
        ("https://api.osv.dev:8443/v1/querybatch", "拒绝非 443 端口"),
    ):
        try:
            assert_allowed_url(url)
            rejected = False
        except ValueError:
            rejected = True
        expect(label, rejected)

    failed = [name for name, passed in cases if not passed]
    print(f"self-test: {len(cases) - len(failed)}/{len(cases)} passed")
    return 1 if failed else 0


# ---------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="OSV dependency gate over an SBOM")
    parser.add_argument("--sbom", help="SBOM whose shipped components are checked")
    parser.add_argument("--exceptions", default=str(DEFAULT_EXCEPTIONS))
    parser.add_argument("--fail-on", default=DEFAULT_THRESHOLD, choices=sorted(SEVERITY_RANK))
    parser.add_argument("--offline-fixture", help="JSON with {batch, details} instead of calling OSV")
    parser.add_argument(
        "--soft-fail-if-unreachable",
        action="store_true",
        help="OSV 不可达时只告警（PR 侧）；发布侧不要用它",
    )
    parser.add_argument(
        "--allow-unassessed",
        action="store_true",
        help="允许严重度无法判定的 advisory（默认 fail-closed 阻断；仅在明确知情时使用）",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    if not args.sbom:
        parser.error("--sbom is required (or use --self-test)")
    try:
        sbom = json.loads(Path(args.sbom).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"FAIL: cannot read sbom {args.sbom}: {exc}", file=sys.stderr)
        return 1

    purls = collect_purls(sbom)
    if not purls:
        print("FAIL: SBOM 里没有可扫描的组件（scope 全为 excluded？）", file=sys.stderr)
        return 1

    exceptions, exception_errors = load_exceptions(Path(args.exceptions))
    if exception_errors:
        for message in exception_errors:
            print(f"FAIL: {message}", file=sys.stderr)
        return 1

    if args.offline_fixture:
        fixture = json.loads(Path(args.offline_fixture).read_text(encoding="utf-8"))
        batch = fixture.get("batch") or {"results": []}
        details = fixture.get("details") or {}
    else:
        try:
            batch, details = query_osv(purls)
        except Exception as exc:  # noqa: BLE001 - 网络类错误统一降级/失败
            message = f"OSV 不可达（{type(exc).__name__}: {exc}）；{len(purls)} 个组件未核查"
            if args.soft_fail_if_unreachable:
                print(f"WARNING: {message}（--soft-fail-if-unreachable，本次不阻断）")
                return 0
            print(f"FAIL: {message}", file=sys.stderr)
            return 1

    outcome = analyze(purls, batch, details, exceptions, args.fail_on)
    blocking = outcome["blocking"]
    waived = outcome["waived"]
    below = outcome["below"]
    unassessed = outcome["unassessed"]

    for entry in waived:
        print(
            f"  [waived] {entry['id']} ({entry['severity']}) {entry['purl']} — {entry['exception']}"
        )
    # 低于阈值的命中照样打印：PR 侧用 critical 阻断，但 high/moderate 必须看得见。
    for entry in below:
        aliases = f" [{', '.join(entry['aliases'])}]" if entry["aliases"] else ""
        print(
            f"  [below-{args.fail_on}] {entry['id']} ({entry['severity']}) "
            f"{entry['purl']}{aliases}: {entry['summary']}"
        )
    # 未评估（R-08）：必须显式可见，不允许混进 below 桶消失。
    for entry in unassessed:
        print(
            f"  [unassessed] {entry['id']} ({entry['basis']}) {entry['purl']}: "
            f"{entry['summary']}"
        )

    if unassessed and not args.allow_unassessed:
        # 发布默认 fail-closed：无法判定严重度的 advisory 不得放行
        # （审计 R-08：旧实现把它当 rank 0 落进 below，高危向量被静默放行）。
        print(
            f"FAIL: {len(unassessed)} 条 advisory 的严重度无法判定"
            "（CVSS 向量无法解析 / 详情缺失）；发布门禁按 fail-closed 阻断。",
            file=sys.stderr,
        )
        print(
            "  处理方式：核对 OSV 条目并补进例外（带 reason 与 expires），"
            "或用 --allow-unassessed 在明确知情的情况下放行。",
            file=sys.stderr,
        )
        return 1

    if blocking:
        print(
            f"FAIL: {len(blocking)} 条 advisory 影响随包发布的依赖（阈值 {args.fail_on}）：",
            file=sys.stderr,
        )
        for entry in blocking:
            aliases = f" [{', '.join(entry['aliases'])}]" if entry["aliases"] else ""
            print(
                f"  - {entry['id']} ({entry['severity']}) {entry['purl']}{aliases}: {entry['summary']}",
                file=sys.stderr,
            )
        print(
            "  处理方式：升级/替换依赖，或在 scripts/security-exceptions.json 里登记"
            "带 reason 与 expires 的例外。",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: {len(purls)} 个随包发布组件的 OSV 查询完成，"
        f"没有达到 {args.fail_on} 阈值的未豁免 advisory"
        f"（豁免 {len(waived)} 条，低于阈值 {len(below)} 条，未评估 {len(unassessed)} 条）"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
