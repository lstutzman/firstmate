#!/usr/bin/env python3
"""Split docs/configuration.md into docs/configuration/<file>.md by a section map.

Usage: fm-config-split.py (--check | --forkonly | --full | --conserve REF) [options]

  --check          assert every h2 is assigned to a file and every heading anchor is unique
                   (fence aware, file titles included); changes nothing.
  --forkonly       move only the sections the fork-local map assigns (sections absent upstream);
                   docs/configuration.md keeps a pointer line, with hidden anchors, in each place.
  --full           move every mapped section; docs/configuration.md becomes a short index with
                   a file table whose hidden anchors keep old links landing.
  --conserve REF   rebuild the single-file document from the current tree and require it to equal
                   REF byte for byte, apart from the documented fix-ups below; changes nothing.

Options: --root DIR (default: the repository holding this script), --shared-map FILE and
--fork-map FILE (default docs/config-split/shared-map.tsv and fork-local-map.tsv),
--anchors-of REF (with --check: every h2-h6 anchor of REF must still resolve in
docs/configuration.md as a heading or a hidden <a id>), --no-rewrite (skip the
repository-wide citation rewrite and the audience-inventory update).

Map files are tab separated; '#' starts a comment:
  file<TAB>NAME.md<TAB>Title              h1 of docs/configuration/NAME.md
  h2<TAB>NAME.md|index<TAB>h2 title       the h2 text before its first '('
  h3<TAB>NAME.md<TAB>h2 title<TAB>h3      an h3 that is the tail of its h2 and goes to its own file
The shared map lists sections upstream has; the fork-local map lists the sections it lacks.
--forkonly moves exactly the units the fork-local map assigns, so it needs no network.

Re-running is safe on a partly split tree: every pointer line is resolved back to its
section first, the whole document is laid out again, and an unchanged layout writes nothing.
A tree made by --full has no pointers, so --forkonly refuses it; --full accepts any layout.

Documented fix-ups (everything else moves byte for byte, heading levels included):
  * a moved file starts with '# Title' and a link back to the index;
  * relative link and src/href targets inside a moved unit gain one '../', except targets
    under configuration/, which lose that prefix;
  * '](#anchor)' links that cross a file boundary point at the file holding the anchor;
  * docs/configuration.md "Name" citations anywhere in the repository except AGENTS.md
    name the file that now holds Name (an ambiguous name is skipped and listed);
  * docs/configuration.md#anchor links outside the doc point at the file holding the anchor;
  * docs/documentation-audiences.json gains one operator-current entry per new file.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

DOC_REL = "docs/configuration.md"
DIR_REL = "docs/configuration"
INDEX = "index"
TABLE_HEADING = "Configuration files"
PART_OF = "Part of the [configuration reference](../configuration.md)."
INVENTORY_REL = "docs/documentation-audiences.json"
SKIP_REWRITE = {"AGENTS.md", "CLAUDE.md"}
SKIP_PREFIXES = ("docs/config-split/", ".git/")

FENCE_OPEN = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$")
POINTER = re.compile(
    r'^((?:<a id="[^"]+"></a>)+)Moved to \[(.+)\]\(configuration/([\w-]+\.md)#([^)\s]+)\)\.$'
)


class Fail(Exception):
    pass


def slug(value):
    # Same rule as github_heading_slug in bin/fm-doc-audience-check.sh.
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("`", "").strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return re.sub(r"\s", "-", value)


def short(title):
    return re.sub(r"\s*\(.*", "", title).strip()


def fence_states(lines):
    """Yield (line, in_fence) where in_fence is True for fence lines and their content."""
    mark = None
    for line in lines:
        m = FENCE_OPEN.match(line)
        if mark is None:
            if m:
                mark = (m.group(1)[0], len(m.group(1)))
                yield line, True
                continue
            yield line, False
        else:
            yield line, True
            if m and m.group(1)[0] == mark[0] and len(m.group(1)) >= mark[1] and not line.strip(" \t`~"):
                mark = None


def headings(lines):
    out = []
    for line, fenced in fence_states(lines):
        m = None if fenced else HEADING.match(line)
        if m:
            out.append((len(m.group(1)), m.group(2).strip()))
    return out


# ---------------------------------------------------------------- maps


class Maps:
    def __init__(self, shared, fork):
        self.titles = {}
        self.h2 = {}  # short title -> (file, source)
        self.h3 = {}  # (h2 short, h3 title) -> (file, source)
        self.dupes = []
        for source, path in (("shared", shared), ("fork", fork)):
            for n, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
                if not raw.strip() or raw.lstrip().startswith("#"):
                    continue
                cols = raw.split("\t")
                where = f"{path}:{n}"
                if cols[0] == "file" and len(cols) == 3:
                    if cols[1] in self.titles:
                        self.dupes.append(f"{where}: title for {cols[1]} defined twice")
                    self.titles[cols[1]] = cols[2]
                elif cols[0] == "h2" and len(cols) == 3:
                    if cols[2] in self.h2:
                        self.dupes.append(f"{where}: h2 '{cols[2]}' assigned twice")
                    self.h2[cols[2]] = (cols[1], source)
                elif cols[0] == "h3" and len(cols) == 4:
                    key = (cols[2], cols[3])
                    if key in self.h3:
                        self.dupes.append(f"{where}: h3 {key} assigned twice")
                    self.h3[key] = (cols[1], source)
                else:
                    raise Fail(f"{where}: unreadable map row")
        for name in {f for f, _ in self.h2.values() if f != INDEX} | {f for f, _ in self.h3.values()}:
            if name not in self.titles:
                self.dupes.append(f"file {name} has no title row")

    def order(self):
        names = []
        for f, _ in list(self.h2.values()) + list(self.h3.values()):
            if f != INDEX and f not in names:
                names.append(f)
        return names


# ---------------------------------------------------------------- parsing


class Unit:
    """One h2 section (kind h2) or one extracted tail h3 (kind h3).

    gap is the number of blank lines that followed it in the index text, kept so a layout change
    reproduces the original bytes even where a heading follows text with no blank line.
    """

    def __init__(self, kind, h2, h3, lines, origin=INDEX):
        self.kind, self.h2, self.h3, self.lines, self.origin = kind, h2, h3, lines, origin
        self.gap = 1

    @property
    def title(self):
        m = HEADING.match(self.lines[0])
        return m.group(2).strip() if m else ""


class Ptr:
    def __init__(self, title, fname):
        self.title, self.fname, self.gap = title, fname, 0


def parse_items(text, where, maps, origin=INDEX):
    """Parse one markdown file into (preamble lines, preamble gap, [Unit | Ptr])."""
    if not text.endswith("\n"):
        raise Fail(f"{where}: no trailing newline")
    lines = text.split("\n")[:-1]
    subs = set(maps.h3)
    pre, items, cur = [], [], None
    cur_h2 = None
    for line, fenced in fence_states(lines):
        m = None if fenced else HEADING.match(line)
        p = None if fenced else POINTER.match(line)
        if p:
            cur = None
            items.append(Ptr(p.group(2), p.group(3)))
            continue
        if m and m.group(1) == "##":
            cur_h2 = short(m.group(2))
            cur = Unit("h2", cur_h2, None, [line], origin)
            items.append(cur)
            continue
        h3 = m.group(2).strip() if m and m.group(1) == "###" else None
        if h3 and (cur_h2, h3) not in subs and cur_h2 is None and not any(t == h3 for _h, t in subs):
            h3 = None
        if h3 and (cur_h2 is None or (cur_h2, h3) in subs):
            # a moved file may start at an extracted h3 (its h2 lives in another file)
            owner = cur_h2 if cur_h2 is not None else next((h for h, t in sorted(subs) if t == h3), None)
            cur = Unit("h3", owner, h3, [line], origin)
            items.append(cur)
            continue
        if m and m.group(1) == "###" and cur is not None and cur.kind == "h3":
            raise Fail(f"{where}: h3 '{m.group(2)}' follows extracted h3 '{cur.h3}' under '{cur_h2}'")
        if cur is None:
            if not items:
                pre.append(line)
            elif line.strip():
                raise Fail(f"{where}: text after a pointer line: {line[:60]}")
            else:
                items[-1].gap += 1
        else:
            cur.lines.append(line)
    if not items:
        raise Fail(f"{where}: no sections")
    pre_gap = 0
    while pre and not pre[-1].strip():
        pre.pop()
        pre_gap += 1
    keep = []
    for i, it in enumerate(items):
        if isinstance(it, Unit):
            k = 0
            while it.lines and not it.lines[-1].strip():
                it.lines.pop()
                k += 1
            it.gap = k
            if it.kind == "h2" and short(it.title) == TABLE_HEADING:
                if i != len(items) - 1:
                    raise Fail(f"{where}: generated '{TABLE_HEADING}' table is not last")
                continue
        keep.append(it)
    return pre, pre_gap, keep


def read_tree(root, maps):
    """Gather the whole document: (preamble, preamble gap, units in document order, strays, file names)."""
    doc = (root / DOC_REL).read_text(encoding="utf-8")
    pre, pre_gap, items = parse_items(doc, DOC_REL, maps)
    queues, filenames = {}, []
    d = root / DIR_REL
    for p in sorted(d.glob("*.md")) if d.is_dir() else []:
        _pre, _gap, fitems = parse_items(p.read_text(encoding="utf-8"), str(p.relative_to(root)), maps, p.name)
        queues[p.name] = [x for x in fitems if isinstance(x, Unit)]
        filenames.append(p.name)
    used = {n: 0 for n in queues}
    out = []
    for it in items:
        if isinstance(it, Unit):
            out.append(it)
            continue
        q = queues.get(it.fname)
        if q is None or used[it.fname] >= len(q):
            raise Fail(f"pointer to {it.fname} for '{it.title}' has no section in that file")
        u = q[used[it.fname]]
        used[it.fname] += 1
        got = u.title if u.kind == "h2" else u.h3
        if got != it.title and short(got) != short(it.title):
            raise Fail(f"pointer '{it.title}' does not match next section '{got}' in {it.fname}")
        u.gap = it.gap
        out.append(u)
    stray = []
    for n in filenames:
        for u in queues[n][used[n]:]:
            u.gap = 1
            stray.append(u)
    everything = out + stray
    anchors = {a for u in everything for a in unit_slugs(u)}
    for u in everything:
        u.lines = canonical(u, sorted(filenames), anchors).split("\n")
        u.origin = INDEX
    return pre, pre_gap, out, stray, set(filenames)


def join_lines(chunks):
    """chunks: [(lines, gap)] -> text with one newline per line."""
    out = []
    for lines, gap in chunks:
        out += lines + [""] * gap
    return "".join(x + "\n" for x in out)


# ---------------------------------------------------------------- layout


def unit_target(u, maps, mode):
    if u.kind == "h3":
        row = maps.h3.get((u.h2, u.h3))
    else:
        row = maps.h2.get(u.h2)
    if row is None:
        return None
    f, source = row
    if mode == "forkonly" and source != "fork":
        return INDEX
    return f


def collect_slugs(units):
    seen, dup = {}, []
    for u in units:
        for _lvl, text in headings(u.lines):
            s = slug(text)
            if not s:
                continue
            if s in seen:
                dup.append(s)
            seen[s] = u
    return seen, dup


def canonical(u, fnames, anchors):
    """Undo the frame rewriting so a unit is the original index-frame text."""
    text = "\n".join(u.lines)
    if u.origin == INDEX:
        names = "|".join(map(re.escape, fnames or ["\0"]))
        pat = rf"\]\((?:configuration/(?:{names}))#([^)\s]+)\)"
        text = re.sub(pat, lambda m: f"](#{m.group(1)})" if m.group(1) in anchors else m.group(0), text)
        return text
    names = "|".join(map(re.escape, fnames or ["\0"]))
    pat = rf"\]\((?:\.\./configuration\.md|{names})#([^)\s]+)\)"
    text = re.sub(pat, lambda m: f"](#{m.group(1)})" if m.group(1) in anchors else m.group(0), text)
    text = re.sub(rf"\]\(((?:{names})(?:#[^)\s]*)?)\)", r"](configuration/\1)", text)
    text = re.sub(rf"""\b(href|src)=(["'])((?:{names})(?:#[^"']*)?)\2""", r"\1=\2configuration/\3\2", text)
    text = re.sub(r"\]\(\.\./([^)\s]+)\)", lambda m: f"]({m.group(1)})", text)
    text = re.sub(r"""\b(href|src)=(["'])\.\./([^"']+)\2""", lambda m: f'{m.group(1)}={m.group(2)}{m.group(3)}{m.group(2)}', text)
    return text


def down(target):
    return target[len("configuration/"):] if target.startswith("configuration/") else "../" + target


def to_file_frame(text, here, anchor_file):
    text = re.sub(r"\]\((?!https?:|mailto:|#|/)([^)\s]+)\)", lambda m: f"]({down(m.group(1))})", text)
    text = re.sub(
        r"""\b(href|src)=(["'])(?!https?:|#|/|mailto:)([^"']+)\2""",
        lambda m: f'{m.group(1)}={m.group(2)}{down(m.group(3))}{m.group(2)}',
        text,
    )

    def anc(m):
        a = m.group(1)
        t = anchor_file.get(a)
        if t is None or t == here:
            return m.group(0)
        return f"](../configuration.md#{a})" if t == INDEX else f"]({t}#{a})"

    return re.sub(r"\]\(#([^)\s]+)\)", anc, text)


def to_index_frame(text, anchor_file):
    def anc(m):
        t = anchor_file.get(m.group(1))
        if t is None or t == INDEX:
            return m.group(0)
        return f"](configuration/{t}#{m.group(1)})"

    return re.sub(r"\]\(#([^)\s]+)\)", anc, text)


def unit_slugs(u):
    return [s for s in (slug(t) for _l, t in headings(u.lines)) if s]


def render(root, mode, maps, pre, pre_gap, units):
    """Return ({relative path: text}, targets, anchor -> file) for the requested layout."""
    targets = {}
    for u in units:
        t = unit_target(u, maps, mode)
        if t is None:
            raise Fail(f"section '{u.h3 or u.h2}' has no map row")
        targets[id(u)] = t
    anchor_file = {}
    for u in units:
        for s in unit_slugs(u):
            anchor_file[s] = targets[id(u)]
    files = {}
    for u in units:
        if targets[id(u)] != INDEX:
            files.setdefault(targets[id(u)], []).append(u)
    out = {}
    for name, us in files.items():
        chunks = [([f"# {maps.titles[name]}", "", PART_OF], 1)]
        for i, u in enumerate(us):
            body = to_file_frame("\n".join(u.lines), name, anchor_file).split("\n")
            chunks.append((body, 1 if i < len(us) - 1 else 0))
        out[f"{DIR_REL}/{name}"] = join_lines(chunks)
    chunks = [(pre, pre_gap)]
    for u in units:
        if targets[id(u)] == INDEX:
            chunks.append((to_index_frame("\n".join(u.lines), anchor_file).split("\n"), u.gap))
        elif mode == "forkonly":
            tags = "".join(f'<a id="{s}"></a>' for s in unit_slugs(u))
            ttl = u.title if u.kind == "h2" else u.h3
            first = slug(HEADING.match(u.lines[0]).group(2))
            chunks.append(([f"{tags}Moved to [{ttl}](configuration/{targets[id(u)]}#{first})."], u.gap))
    if mode == "full" and files:
        chunks[-1] = (chunks[-1][0], 1)
        rows = [f"## {TABLE_HEADING}", "", "Each file lists its own settings; a new setting changes only its file.", "", "| File | Covers |", "| --- | --- |"]
        for name in maps.order():
            if name not in files:
                continue
            tags = "".join(f'<a id="{s}"></a>' for u in files[name] for s in unit_slugs(u))
            covers = ", ".join((u.h3 if u.kind == "h3" else short(u.title)) for u in files[name])
            rows.append(f"| {tags}[{maps.titles[name]}](configuration/{name}) | {covers} |")
        chunks.append((rows, 0))
    out[DOC_REL] = join_lines(chunks)
    return out, targets, anchor_file


# ---------------------------------------------------------------- check


def run_check(root, maps, anchors_of):
    problems = list(maps.dupes)
    _pre, _pg, units, stray, fnames = read_tree(root, maps)
    units = units + stray
    h2s = [u for u in units if u.kind == "h2"]
    unassigned = [u.title for u in units if unit_target(u, maps, "full") is None]
    if unassigned:
        problems.append("unassigned: " + "; ".join(unassigned))
    present = {u.h2 for u in h2s}
    stale = sorted(k for k in maps.h2 if k not in present)
    names = [u.h2 for u in h2s]
    dups = sorted({n for n in names if names.count(n) > 1})
    if dups:
        problems.append("h2 title used twice: " + "; ".join(dups))
    seen, dup = collect_slugs(units)
    if dup:
        problems.append("duplicate heading anchors: " + ", ".join(sorted(set(dup))))
    for name, title in maps.titles.items():
        s = slug(title)
        if s in seen:
            problems.append(f"file title '{title}' ({name}) collides with a heading anchor '{s}'")
    # independent h2 count: a single-toggle scan that must agree with the fence-aware parse
    flat, toggle = 0, False
    texts = [(root / DOC_REL)] + sorted((root / DIR_REL).glob("*.md"))
    for p in texts:
        for line in p.read_text(encoding="utf-8").split("\n"):
            if line.lstrip().startswith(("```", "~~~")):
                toggle = not toggle
            elif not toggle and line.startswith("## ") and short(line[3:]) != TABLE_HEADING:
                flat += 1
    if flat != len(h2s):
        problems.append(f"h2 count disagrees: parser {len(h2s)}, line scan {flat}")
    if anchors_of:
        idx_lines = (root / DOC_REL).read_text(encoding="utf-8").split("\n")
        have = {slug(t) for _l, t in headings(idx_lines)}
        for line in idx_lines:
            have.update(re.findall(r"<(?:a|span)\s+(?:name|id)=[\"']([^\"']+)[\"']", line, re.IGNORECASE))
        ref = Path(anchors_of).read_text(encoding="utf-8").split("\n")
        missing = sorted({slug(t) for l, t in headings(ref) if l >= 2} - have)
        if missing:
            problems.append(f"{len(missing)} anchors of {anchors_of} no longer resolve in {DOC_REL}: " + ", ".join(missing[:10]))
    if problems:
        raise Fail("check failed:\n  " + "\n  ".join(problems))
    fork_units = sum(1 for u in units if unit_target(u, maps, "forkonly") not in (INDEX, None))
    extra = f" stale_map_rows={len(stale)}" if stale else ""
    anchor_note = " anchors_of=ok" if anchors_of else ""
    print(f"fm-config-split check ok: h2={len(h2s)} assigned={len(h2s)} anchors={len(seen)} unique=yes "
          f"files_now={len(fnames)} forkonly_units={fork_units}{extra}{anchor_note}")


# ---------------------------------------------------------------- conserve


def norm_cites(text):
    return re.sub(r"configuration/[\w-]+\.md(?!#)", "configuration.md", text)


def unsplit_text(root, maps):
    pre, pre_gap, units, stray, _fnames = read_tree(root, maps)
    if stray:
        raise Fail("files hold sections with no pointer in the index, so document order is unknown")
    return join_lines([(pre, pre_gap)] + [(u.lines, u.gap) for u in units])


def run_conserve(root, maps, ref):
    got = norm_cites(unsplit_text(root, maps))
    want = norm_cites(Path(ref).read_text(encoding="utf-8"))
    if got != want:
        a, b = got.split("\n"), want.split("\n")
        n = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
        raise Fail(f"conservation failed at line {n + 1}:\n  tree: {a[n] if n < len(a) else '<eof>'}\n  ref:  {b[n] if n < len(b) else '<eof>'}")
    print(f"fm-config-split conserve ok: lines={len(want.split(chr(10))) - 1} lost=0 changed=0 (byte equal after citation path normalisation)")


# ---------------------------------------------------------------- split


def tracked_files(root):
    r = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True, check=False)
    if r.returncode == 0 and r.stdout:
        return [x for x in r.stdout.decode().split("\0") if x]
    return [str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() and ".git" not in p.parts]


NAME_WRAP = r"\n[ \t]*(?:#|//|\*|;|--)?[ \t]*"
QUOTE = re.compile(
    r"(?P<path>(?:\.\./)*(?:docs/)?configuration(?:/(?P<cur>[\w-]+))?\.md)"
    r"(?P<mid>(?:`|\]\((?P<href>[^)\s]*configuration(?:/[\w-]+)?\.md)\)|'s|\)|\(|[ \t]|" + NAME_WRAP + r")*?"
    r"(?:(?:the|section|in|see)\s+)?)"
    r"(?P<q>\\?\")(?P<name>[A-Za-z][^\"\\\n]{1,80}?(?:" + NAME_WRAP + r"[^\"\\\n]{1,60}?)?)(?P=q)"
)
PAREN = re.compile(
    r"(?P<path>(?:\.\./)*(?:docs/)?configuration(?:/(?P<cur>[\w-]+))?\.md)[ \t]*\((?P<name>[A-Z][^()\"\n]{2,60})\)"
)
ANCHOR_LINK = re.compile(r"((?:\.\./)*(?:docs/)?)configuration(?:/[\w-]+)?\.md#([A-Za-z0-9_\-]+)")


def rewrite_repo(root, titles, anchor_file, skipped, stats):
    """titles: normalised heading name -> list of distinct targets."""
    def resolve(name):
        key = re.sub(NAME_WRAP, " ", name).strip()
        key = re.sub(r"\s+", " ", key)
        hit = titles.get(key)
        if hit is None:
            heads = {short(k) for k in titles if k.startswith(key) and len(key) > 5 and k[len(key):len(key) + 1] in (" ", "(", "")}
            if len(heads) > 1:
                return False, key
            hit = [t for k in titles if k.startswith(key) and len(key) > 5 and k[len(key):len(key) + 1] in (" ", "(", "") for t in titles[k]] or None
        if hit is None:
            return None, key
        hit = sorted(set(hit))
        return (hit[0] if len(hit) == 1 else False), key

    def fix_quote(m, rel):
        t, key = resolve(m.group("name"))
        if t is None:
            return m.group(0)
        if t is False:
            skipped.append(f"{rel}: ambiguous name \"{key}\"")
            return m.group(0)
        want = "configuration.md" if t == INDEX else f"configuration/{t}"
        cur = m.group("cur")
        have = f"configuration/{cur}.md" if cur else "configuration.md"
        if want == have or (cur and f"{cur}.md" == t):
            return m.group(0)
        path = m.group("path")
        newpath = path[: path.rindex("configuration")] + (want if want.endswith(".md") else want + ".md")
        tail = m.group(0)[len(path):]
        h = m.groupdict().get("href")
        if h:
            nh = h[: h.rindex("configuration")] + (want if want.endswith(".md") else want + ".md")
            tail = tail.replace(f"]({h})", f"]({nh})", 1)
        stats["quoted"] += 1
        return newpath + tail

    def fix_anchor(m):
        t = anchor_file.get(m.group(2))
        if t is None:
            return m.group(0)
        new = f"{m.group(1)}configuration.md#{m.group(2)}" if t == INDEX else f"{m.group(1)}configuration/{t}#{m.group(2)}"
        stats["anchor"] += new != m.group(0)
        return new

    def inside(rel):
        return rel == DOC_REL or rel.startswith(DIR_REL + "/")

    for rel in tracked_files(root):
        if rel in SKIP_REWRITE or rel.startswith(SKIP_PREFIXES):
            continue
        p = root / rel
        if not p.is_file() or p.is_symlink():
            continue
        try:
            s = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if "configuration" not in s:
            continue
        o = s
        s = QUOTE.sub(lambda m, rel=rel: fix_quote(m, rel), s)
        s = PAREN.sub(lambda m, rel=rel: fix_quote(m, rel), s)
        if not inside(rel):
            s = ANCHOR_LINK.sub(fix_anchor, s)
        if s != o:
            p.write_text(s, encoding="utf-8")
            stats["files"] += 1


def add_inventory(root, names, stats):
    p = root / INVENTORY_REL
    if not p.is_file():
        return
    text = p.read_text(encoding="utf-8")
    have = set(re.findall(r'"path":\s*"([^"]+)"', text))
    anchor = '    {\n      "path": "docs/configuration.md",\n      "audience": "operator-current"\n    },\n'
    if anchor not in text:
        raise Fail(f"{INVENTORY_REL}: cannot find the docs/configuration.md surface entry to extend")
    add = ""
    for n in sorted(names):
        rel = f"{DIR_REL}/{n}"
        if rel not in have:
            add += f'    {{\n      "path": "{rel}",\n      "audience": "operator-current"\n    }},\n'
            stats["inventory"] += 1
    if add:
        p.write_text(text.replace(anchor, anchor + add, 1), encoding="utf-8")
    json.loads(p.read_text(encoding="utf-8"))


def run_split(root, maps, mode, rewrite):
    pre, pre_gap, units, stray, fnames = read_tree(root, maps)
    if stray and mode == "forkonly":
        raise Fail("--forkonly needs the pointer lines of a --forkonly tree; this tree holds sections with no pointer (a --full tree?)")
    units = units + stray
    require_mapped(maps, units)
    out, targets, anchor_file = render(root, mode, maps, pre, pre_gap, units)
    live = {rel.split("/")[-1] for rel in out if rel != DOC_REL}
    for name in sorted(fnames - live):
        raise Fail(f"{DIR_REL}/{name} would be left empty by this layout; nothing was written")
    changed = 0
    for rel, text in out.items():
        p = root / rel
        if not p.exists() or p.read_text(encoding="utf-8") != text:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8")
            changed += 1
    stats = {"quoted": 0, "anchor": 0, "files": 0, "inventory": 0}
    skipped = []
    if rewrite:
        titles = {}
        for u in units:
            for lvl, text in headings(u.lines):
                if lvl in (2, 3):
                    t = targets[id(u)]
                    for key in {text, short(text)}:
                        titles.setdefault(key, []).append(t)
        add_inventory(root, live, stats)
        rewrite_repo(root, titles, anchor_file, skipped, stats)
    moved = sum(1 for u in units if targets[id(u)] != INDEX)
    print(f"fm-config-split {mode}: sections_moved={moved} files={len(live)} written={changed} "
          f"index_bytes={len(out[DOC_REL].encode())} anchor_links_rewritten={stats['anchor']} "
          f"citations_rewritten={stats['quoted']} files_touched={stats['files']} inventory_added={stats['inventory']}")
    for s in sorted(set(skipped)):
        print("skipped " + s)


def require_mapped(maps, units):
    bad = [u.h3 or u.h2 for u in units if unit_target(u, maps, "full") is None]
    if bad:
        raise Fail("unassigned sections (run --check): " + "; ".join(bad))
    seen, dup = collect_slugs(units)
    if dup:
        raise Fail("duplicate heading anchors (run --check): " + ", ".join(sorted(set(dup))))
    for title in maps.titles.values():
        if slug(title) in seen:
            raise Fail(f"file title '{title}' collides with a heading anchor (run --check)")
    if maps.dupes:
        raise Fail("; ".join(maps.dupes))


def main():
    here = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description="Split docs/configuration.md by a section map.")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--forkonly", action="store_true")
    g.add_argument("--full", action="store_true")
    g.add_argument("--conserve", metavar="REF")
    ap.add_argument("--root", default=str(here))
    ap.add_argument("--shared-map")
    ap.add_argument("--fork-map")
    ap.add_argument("--anchors-of", metavar="REF")
    ap.add_argument("--no-rewrite", action="store_true")
    a = ap.parse_args()
    root = Path(a.root).resolve()
    shared = a.shared_map or root / "docs/config-split/shared-map.tsv"
    fork = a.fork_map or root / "docs/config-split/fork-local-map.tsv"
    try:
        maps = Maps(shared, fork)
        if a.check:
            run_check(root, maps, a.anchors_of)
        elif a.conserve:
            run_conserve(root, maps, a.conserve)
        else:
            run_split(root, maps, "forkonly" if a.forkonly else "full", not a.no_rewrite)
    except Fail as e:
        print(f"fm-config-split: {e}", file=sys.stderr)
        return 1
    except (OSError, UnicodeDecodeError) as e:
        print(f"fm-config-split: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
