#!/usr/bin/env python3
"""Visual review, evaluate slice (PC-4453, slice 2 of PC-4451).

Reads the manifest the nightly staging E2E run writes with VISUAL_CAPTURE=1 (PC-4452), picks the
screenshots that are new or changed since the previous night (by key, compared by SHA-256), asks one
vision model to check each against a fixed rubric, and writes a findings file for the filing slice
(PC-4454). The findings file is the handoff to the officer that files Linear items; its contract
is in scripts/visual-review/README.md.

Only staging screenshots go to the model: the capture runs as the canonical test users on staging,
and this script refuses any other origin. Standard library only. Run it under `op-agent run --` so
OPENROUTER_API_KEY resolves; the key is never printed.

    op-agent run -- python3 scripts/visual-review/evaluate.py \\
        --capture-dir src/PropertyCompass.Web/client/test-results/visual-capture \\
        --origin https://pc-staging-web.azurewebsites.net \\
        --state visual-review-state.json --out visual-review-findings.json
"""

import argparse
import base64
import datetime
import hashlib
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

SCHEMA_VERSION = 2  # the findings file
STATE_VERSION = 1  # the hash state file
FINGERPRINT_PREFIX = "visual-review-fp-v1"
CLASS_DEFECT = "defect"
CLASS_HELD = "held-for-lee"
STAGING_HOST = "pc-staging-web.azurewebsites.net"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
# Cheapest model that reads small UI text well enough to catch the rubric (see the PR for the bake-off).
DEFAULT_MODEL = "anthropic/claude-haiku-5.5"
DEFAULT_MAX_IMAGES = 150
MAX_IMAGE_BYTES = 8 * 1024 * 1024
SEVERITIES = ("high", "medium", "low")
MAX_EVIDENCE_CHARS = 240
MAX_REGION_CHARS = 120


@dataclass(frozen=True)
class RubricItem:
    id: str
    title: str
    description: str


# The fixed rubric, built from the 2026-11-07 manual findings (PC-4426 to PC-4435 and the Strategy finder).
RUBRIC: tuple[RubricItem, ...] = (
    RubricItem(
        "contradictory-numbers",
        "Contradictory numbers",
        "The same thing shows two different numbers on one screen (a total that differs from its parts, "
        "a count that differs from the list under it, two prices for one property).",
    ),
    RubricItem(
        "impossible-values",
        "Impossible values",
        "A figure no real case could produce: a return of 1220% on cash, a negative area, a year in the "
        "future, a percentage over 100 where only a share makes sense, or a date that is not a date.",
    ),
    RubricItem(
        "raw-internal-names",
        "Raw enum or internal names",
        "A code identifier shown as member text: SemiDetached, score.1, snake_case_key, a translation key, "
        "undefined, null, NaN or [object Object].",
    ),
    RubricItem(
        "missing-core-data",
        "Dashes or 'Data unavailable' on core fields",
        "A dash, 'N/A', 'Data unavailable' or an empty cell where the screen's main figure or a whole "
        "column should be. A dash on one optional field is fine; a whole column of dashes is not.",
    ),
    RubricItem(
        "truncated-or-overflowing",
        "Truncated headers or overflowing tables",
        "Text cut off mid-word or mid-number, a heading that runs under another element, a table wider "
        "than its container, controls drawn on top of each other, or content clipped by the screen edge.",
    ),
    RubricItem(
        "tie-or-zero-best",
        "Ties or zeros highlighted as best",
        "A comparison highlights a winner when the values are tied or are all zero or empty.",
    ),
    RubricItem(
        "repeated-or-developer-copy",
        "Repeated or developer-note copy",
        "The same sentence or block shown twice, placeholder text, TODO or lorem ipsum, or wording that "
        "reads as a note to developers (flags, endpoints, ticket numbers, 'this will be replaced').",
    ),
    RubricItem(
        "empty-state-clutter",
        "Empty-state clutter",
        "An empty state that still shows many empty panels, zero-value tiles or headings with nothing "
        "under them, instead of one clear message.",
    ),
    RubricItem(
        "source-text-outside-sources",
        "Source text outside the Data sources section",
        "Data-provider names, licences or attribution lines placed in the body of the page rather than "
        "in its Data sources section.",
    ),
    RubricItem(
        "jargon",
        "Jargon",
        "Terms a property investor would not know, or abbreviations never explained on the screen.",
    ),
)
RUBRIC_IDS = frozenset(item.id for item in RUBRIC)

# Wording and product calls stay with Lee: a finding in these rubric items is held, never started.
# Every other item is a defect (a wrong, impossible, missing or broken thing) the officer may queue.
HELD_FOR_LEE_ITEMS = frozenset(
    {
        "repeated-or-developer-copy",
        "empty-state-clutter",
        "source-text-outside-sources",
        "jargon",
    }
)


class ReviewError(Exception):
    """A refusal or a failure that stops the run."""


def finding_class(rubric_item: str) -> str:
    """CLASS_HELD for wording and product rubric items, CLASS_DEFECT for the rest."""
    return CLASS_HELD if rubric_item in HELD_FOR_LEE_ITEMS else CLASS_DEFECT


def fingerprint(route: str, rubric_item: str) -> str:
    """SHA-256 hex of FINGERPRINT_PREFIX, route and rubric item, joined by newlines (UTF-8).

    Viewport, state and night are left out on purpose: the same defect on the same route is one
    Linear item however many screenshots show it.
    """
    text = "\n".join((FINGERPRINT_PREFIX, route, rubric_item))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def upgrade_document(document: dict[str, Any]) -> dict[str, Any]:
    """A version 1 findings document as version 2: derive the fields version 2 added.

    A version 2 document is returned unchanged. Any other version is refused.
    """
    version = document.get("schema_version") if isinstance(document, dict) else None
    if type(version) is not int or version not in (1, SCHEMA_VERSION):
        raise ReviewError(f"unsupported findings schema_version {version!r}")
    findings = document.get("findings")
    if not isinstance(findings, list) or not all(
        isinstance(f, dict) and all(isinstance(f.get(k), str) for k in ("route", "rubric_item", "file"))
        for f in findings
    ):
        raise ReviewError("findings must be a list of objects with route, rubric_item and file")
    if version == SCHEMA_VERSION:
        return document
    upgraded = [
        {
            **finding,
            "fingerprint": fingerprint(finding["route"], finding["rubric_item"]),
            "screenshot": finding["file"],
            "class": finding_class(finding["rubric_item"]),
        }
        for finding in findings
    ]
    return {**document, "schema_version": SCHEMA_VERSION, "findings": upgraded}


@dataclass(frozen=True)
class Candidate:
    entry: dict[str, Any]
    sha256: str
    reason: str  # "new" or "changed"


@dataclass(frozen=True)
class ModelReply:
    text: str
    prompt_tokens: int
    completion_tokens: int
    cost_usd: float | None


ModelCall = Callable[[str, bytes, dict[str, Any]], ModelReply]


def require_staging_origin(origin: str) -> None:
    """Refuse any origin but staging, so production or real member screens never reach a model."""
    host = urllib.parse.urlparse(origin).hostname
    if host != STAGING_HOST:
        raise ReviewError(
            f"refusing to review screenshots from {host or origin!r}: only {STAGING_HOST} is allowed"
        )


def load_manifest(capture_dir: Path) -> list[dict[str, Any]]:
    path = capture_dir / "manifest.json"
    if not path.is_file():
        raise ReviewError(f"no manifest.json in {capture_dir}")
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise ReviewError("manifest.json has no entries list")
    return entries


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_state(path: Path | None) -> dict[str, str]:
    """The previous night's key -> SHA-256 map. A missing file means a first run: everything is new."""
    if path is None or not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    hashes = data.get("hashes", {})
    return {str(key): str(value) for key, value in hashes.items()}


def image_path(capture_dir: Path, entry: dict[str, Any]) -> Path | None:
    """The entry's PNG inside the capture directory, or None when it is missing or points outside it."""
    root = capture_dir.resolve()
    image = (root / str(entry.get("file", ""))).resolve()
    if image.suffix != ".png" or not image.is_relative_to(root) or not image.is_file():
        return None
    return image


def detect_changes(
    entries: list[dict[str, Any]], capture_dir: Path, previous: dict[str, str]
) -> tuple[list[Candidate], int]:
    """Entries that are new or whose image differs from last night's, and how many were unchanged."""
    candidates: list[Candidate] = []
    unchanged = 0
    for entry in entries:
        image = image_path(capture_dir, entry)
        if image is None:
            continue
        digest = sha256_of(image)
        before = previous.get(entry["key"])
        if before is None:
            candidates.append(Candidate(entry, digest, "new"))
        elif before != digest:
            candidates.append(Candidate(entry, digest, "changed"))
        else:
            unchanged += 1
    return candidates, unchanged


def build_system_prompt() -> str:
    rubric = "\n".join(f"- {item.id}: {item.title}. {item.description}" for item in RUBRIC)
    return (
        "You review one screenshot of a UK property investing web app, taken on a staging site as a "
        "test user. Find problems a person would notice that an automated test would not. Check ONLY "
        "these rubric items:\n"
        f"{rubric}\n\n"
        "Rules:\n"
        "- Report only what you can see in this image. Quote the visible text as evidence.\n"
        "- Do not report design taste, spacing, colour, or anything outside the rubric.\n"
        "- When a screen is a loading state or a blank page with no content, report nothing.\n"
        "- severity: high = a wrong or impossible figure or raw internal text in core content; "
        "medium = a visible defect that hurts trust or reading; low = minor.\n"
        '- Answer with JSON only: {"findings": [{"rubric_item": "<id>", "evidence": "<visible text>", '
        '"region": "<where on the screen>", "severity": "high|medium|low"}]}. '
        'Return {"findings": []} when nothing is wrong.'
    )


def build_user_text(entry: dict[str, Any]) -> str:
    text = (
        f"Route: {entry['route']}. Viewport: {entry['viewport']}. State: {entry['state']}."
    )
    if entry.get("fullHeight"):
        text += f" The page is {entry['fullHeight']} px tall; this image shows only the top."
    return text


def build_request(model: str, entry: dict[str, Any], image: bytes) -> dict[str, Any]:
    encoded = base64.b64encode(image).decode("ascii")
    return {
        "model": model,
        "temperature": 0,
        "max_tokens": 1500,
        "response_format": {"type": "json_object"},
        "usage": {"include": True},
        "messages": [
            {"role": "system", "content": build_system_prompt()},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": build_user_text(entry)},
                    {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{encoded}"}},
                ],
            },
        ],
    }


def parse_findings(text: str) -> tuple[list[dict[str, str]], int]:
    """Valid findings from a model reply, and how many items were dropped as malformed.

    Raises ReviewError when the reply is not the JSON object the prompt asked for.
    """
    body = text.strip()
    if body.startswith("```"):
        body = body.strip("`")
        body = body.removeprefix("json").strip()
    try:
        data = json.loads(body)
    except json.JSONDecodeError as error:
        raise ReviewError(f"reply is not JSON: {error}") from error
    items = data.get("findings") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise ReviewError("reply has no findings list")
    findings: list[dict[str, str]] = []
    dropped = 0
    for item in items:
        if not isinstance(item, dict):
            dropped += 1
            continue
        rubric_item = item.get("rubric_item")
        evidence = item.get("evidence")
        severity = str(item.get("severity", "")).lower()
        if rubric_item not in RUBRIC_IDS or not isinstance(evidence, str) or not evidence.strip():
            dropped += 1
            continue
        findings.append(
            {
                "rubric_item": rubric_item,
                "evidence": evidence.strip()[:MAX_EVIDENCE_CHARS],
                "region": str(item.get("region", "")).strip()[:MAX_REGION_CHARS],
                "severity": severity if severity in SEVERITIES else "low",
            }
        )
    return findings, dropped


def openrouter_call(api_key: str) -> ModelCall:
    """The live model call. Unit tests pass a fake in its place."""

    def call(model: str, image: bytes, entry: dict[str, Any]) -> ModelReply:
        payload = json.dumps(build_request(model, entry, image)).encode("utf-8")
        request = urllib.request.Request(
            OPENROUTER_URL,
            data=payload,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                body = json.load(response)
        except urllib.error.HTTPError as error:
            raise ReviewError(f"model call failed: HTTP {error.code}") from error
        except (OSError, ValueError) as error:  # URLError, timeouts, dropped connections, bad JSON
            raise ReviewError(f"model call failed: {error}") from error
        try:
            text = body["choices"][0]["message"]["content"]
            usage = body.get("usage") or {}
            cost = usage.get("cost")
            reply = ModelReply(
                text=text if isinstance(text, str) else "",
                prompt_tokens=int(usage.get("prompt_tokens") or 0),
                completion_tokens=int(usage.get("completion_tokens") or 0),
                cost_usd=float(cost) if cost is not None else None,
            )
        except (KeyError, IndexError, TypeError, ValueError, AttributeError) as error:
            raise ReviewError("model reply has an unexpected shape") from error
        return reply

    return call


def review(
    capture_dir: Path,
    origin: str,
    previous: dict[str, str],
    model: str,
    call: ModelCall,
    max_images: int = DEFAULT_MAX_IMAGES,
    now: datetime.datetime | None = None,
) -> tuple[dict[str, Any], dict[str, str]]:
    """Review the new and changed screenshots. Returns the findings document and the new state.

    The new state keeps last night's hash for any image that failed or was left over the cap, so
    tomorrow's run picks it up again.
    """
    require_staging_origin(origin)
    entries = load_manifest(capture_dir)
    candidates, unchanged = detect_changes(entries, capture_dir, previous)
    selected, deferred = candidates[: max(max_images, 0)], candidates[max(max_images, 0) :]

    state = {entry["key"]: previous[entry["key"]] for entry in entries if entry["key"] in previous}
    findings: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = [
        {"key": entry["key"], "error": "image file missing or outside the capture directory"}
        for entry in entries
        if image_path(capture_dir, entry) is None
    ]
    prompt_tokens = completion_tokens = 0
    cost = 0.0
    cost_known = True
    reviewed = 0
    dropped_total = 0

    for candidate in selected:
        entry = candidate.entry
        image = (capture_dir / entry["file"]).read_bytes()
        if len(image) > MAX_IMAGE_BYTES:
            errors.append({"key": entry["key"], "error": f"image over {MAX_IMAGE_BYTES} bytes"})
            continue
        try:
            reply = call(model, image, entry)
        except ReviewError as error:
            errors.append({"key": entry["key"], "error": str(error)})
            continue
        # A reply that does not parse was still billed, so count it before parsing.
        prompt_tokens += reply.prompt_tokens
        completion_tokens += reply.completion_tokens
        if reply.cost_usd is None:
            cost_known = False
        else:
            cost += reply.cost_usd
        try:
            parsed, dropped = parse_findings(reply.text)
        except ReviewError as error:
            errors.append({"key": entry["key"], "error": str(error)})
            continue
        reviewed += 1
        dropped_total += dropped
        state[entry["key"]] = candidate.sha256
        for finding in parsed:
            findings.append(
                {
                    "key": entry["key"],
                    "route": entry["route"],
                    "viewport": entry["viewport"],
                    "state": entry["state"],
                    "test": entry["test"],
                    "file": entry["file"],
                    "screenshot": entry["file"],
                    "fingerprint": fingerprint(entry["route"], finding["rubric_item"]),
                    "class": finding_class(finding["rubric_item"]),
                    "reason": candidate.reason,
                    **finding,
                }
            )

    stamp = (now or datetime.datetime.now(datetime.timezone.utc)).isoformat(timespec="seconds")
    document = {
        "schema_version": SCHEMA_VERSION,
        "run": {
            "date": stamp,
            "origin": origin,
            "model": model,
            "rubric": [item.id for item in RUBRIC],
            "manifest_images": len(entries),
            "unchanged_skipped": unchanged,
            "images_reviewed": reviewed,
            "images_failed": len(errors),
            "images_deferred": len(deferred),
            "findings": len(findings),
            "malformed_findings_dropped": dropped_total,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "cost_usd": round(cost, 6) if cost_known else None,
        },
        "findings": findings,
        "errors": errors,
    }
    return document, state


def format_summary(document: dict[str, Any]) -> str:
    run = document["run"]
    cost = "unknown" if run["cost_usd"] is None else f"${run['cost_usd']:.4f}"
    return (
        f"Visual review: model {run['model']}, reviewed {run['images_reviewed']} of "
        f"{run['manifest_images']} images ({run['unchanged_skipped']} unchanged, "
        f"{run['images_failed']} failed, {run['images_deferred']} deferred), "
        f"{run['findings']} findings, cost {cost}"
    )


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None, call: ModelCall | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--capture-dir", type=Path, required=True)
    parser.add_argument("--origin", required=True, help="The base URL the E2E run captured from")
    parser.add_argument("--state", type=Path, help="Previous night's hash file; rewritten after the run")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--max-images", type=int, default=DEFAULT_MAX_IMAGES)
    args = parser.parse_args(argv)

    if call is None:
        import os

        key = os.environ.get("OPENROUTER_API_KEY", "")
        if not key:
            print("OPENROUTER_API_KEY is not set; run under `op-agent run --`", file=sys.stderr)
            return 2
        call = openrouter_call(key)
    try:
        document, state = review(
            args.capture_dir,
            args.origin,
            load_state(args.state),
            args.model,
            call,
            args.max_images,
        )
    except ReviewError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    write_json(args.out, document)
    if args.state:
        write_json(args.state, {"schema_version": STATE_VERSION, "hashes": state})
    print(format_summary(document))
    return 0


if __name__ == "__main__":
    sys.exit(main())
