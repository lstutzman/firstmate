# Visual review

Slice 2 and 3 of PC-4451. `evaluate.py` reads the nightly staging screenshots (PC-4452), asks a vision
model to check the new and changed ones against a fixed rubric, and writes the **findings file**. A
separate officer (in the firstmate repository, Ship's Surgeon contract) reads that file and files Linear
items. PropertyCompass2 never calls Linear for this.

## Handoff contract (findings file, `schema_version` 2)

Written by `--out` (the nightly wiring, PC-4455, picks the path). JSON object:

- `schema_version`: `2`. A version 1 file has no `fingerprint`, `screenshot` or `class`; derive them for each finding:
  `screenshot` = `file`, `fingerprint` and `class` by the rules below (`upgrade_document()` in `evaluate.py` does
  this). Any other version: refuse the file.
- `run`: counters (`model`, `origin`, `date`, `images_reviewed`, `cost_usd`, and so on). Informational.
- `errors`: images that could not be reviewed (`key`, `error`). Informational, never findings.
- `findings`: list. Each finding has:

| Field | Meaning |
|---|---|
| `fingerprint` | Dedupe key, lower-case hex SHA-256 (see below). One Linear item per fingerprint. |
| `class` | `defect` or `held-for-lee` (see below). |
| `screenshot` | PNG path relative to the capture directory. Same value as `file`. |
| `route`, `viewport`, `state`, `key`, `test` | Where it was seen. `key` is `route\|viewport\|state`. |
| `rubric_item` | One of the rubric ids in `evaluate.py` (`RUBRIC`). |
| `evidence` | Text the model saw on screen (max 240 characters). |
| `region`, `severity` | Where on the screen; `high`, `medium` or `low`. |
| `reason` | `new` or `changed` since the previous night. |

### Fingerprint

`sha256_hex(utf8("visual-review-fp-v1" + "\n" + route + "\n" + rubric_item))`, with `route` exactly as in
the finding and `rubric_item` its id. Viewport, state and date are not part of it: the same problem on one
route is one item, however many screenshots show it. Several findings in one file can share a fingerprint;
file one item and attach each screenshot. A re-seen fingerprint bumps the item's "Found: N times" line.
Suggested search marker: `visual-review-fp:<hex>` in the item description.

### Class

- `held-for-lee`: wording or product findings (`jargon`, `repeated-or-developer-copy`,
  `empty-state-clutter`, `source-text-outside-sources`). File them, flag them for Lee, and never start
  work on them. Member-facing copy and product choices are Lee's.
- `defect`: everything else (`contradictory-numbers`, `impossible-values`, `raw-internal-names`,
  `missing-core-data`, `truncated-or-overflowing`, `tie-or-zero-best`). The officer's normal rules for
  starting a bug apply.

The mapping is `HELD_FOR_LEE_ITEMS` in `evaluate.py`. Any rubric item not listed there is a `defect`,
so a new wording or product rubric item must be added to that set.

### Finding the screenshot

The capture directory is the one `evaluate.py` was run with (`--capture-dir`, by default
`src/PropertyCompass.Web/client/test-results/visual-capture` in the nightly workspace). Join it with
`screenshot`. The file is a PNG, at most 8 MiB, already confined to that directory. Attach it to the Linear
item. The capture directory is not in the findings file yet; the nightly wiring must hand both together
(PC-4455).

## Tests

`python3 scripts/visual-review/evaluate.test.py` (no model call).
