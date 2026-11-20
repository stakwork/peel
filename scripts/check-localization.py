#!/usr/bin/env python3
"""Validate Peel's String Catalogs and find user-facing literals that lack a key.

  scripts/check-localization.py            validate catalogs + scan sources (exit 1 on a problem)
  scripts/check-localization.py --hunt F.. list string literals in the given files/dirs that look
                                           user-facing but are not in a localized call (triage aid)

Catalog routing (see README "Localization"): Apps/Mac -> Apps/Mac/Peel/Localizable.xcstrings,
Apps/iOS -> Apps/iOS/Peel/Localizable.xcstrings, Apps/Shared and Sources/** -> table "Shared"
(Apps/Shared/Shared.xcstrings), read with tableName: "Shared" / table: "Shared".
SWIFT_EMIT_LOC_STRINGS is NO, so building does not add keys: this script is the check.
"""
import json, re, sys, os, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = {
    "mac": "Apps/Mac/Peel/Localizable.xcstrings",
    "ios": "Apps/iOS/Peel/Localizable.xcstrings",
    "Shared": "Apps/Shared/Shared.xcstrings",
}
INFOPLIST = ["Apps/Mac/Peel/InfoPlist.xcstrings", "Apps/iOS/Peel/InfoPlist.xcstrings"]
# Spanish may equal English for these (names, brands, units, loanwords).
SAME_OK = re.compile(r"^(%[@\w$]*|[\W\d_]*|OK|Peel|Sphinx|Strut|Jamie|Bitcoin|Lightning|Nostr|Email|Hub|Chat|Chats|Total|Error|Sats?|Bots?|Apps?|Web|Video|Audio|Hash|QR|URL|API|SSH|AI|MCP|Wi-?Fi|Hola|Online|Offline|Boost|Tribes?|Chat|Admin|Menú|Token|Tokens|Modo|Final|Local|General|Normal|Ping|Beta|Logs?|Debug|Server|Pro|Plan|Base|Nombre|Color|Tema)$", re.I)

SPEC = re.compile(r"%(?:(\d+)\$)?(?:l{0,2}|h{0,2}|q|z|t|j)?([@dDiuUfFeEgGsScCxXoOp])")

def specs(s):
    s = s.replace("%%", "")
    out = []
    for m in SPEC.finditer(s):
        t = m.group(2).lower()
        t = {"d": "i", "u": "i", "i": "i", "s": "@", "f": "f", "e": "f", "g": "f"}.get(t, t)
        out.append((m.group(1), t))
    return out

def sig(s):
    """Placeholder signature by position: [types]."""
    sp = specs(s)
    if any(p for p, _ in sp):
        if not all(p for p, _ in sp):
            return None  # mixed positional / plain
        d = {}
        for p, t in sp:
            d[int(p)] = t
        return [d.get(i) for i in range(1, max(d) + 1)]
    return [t for _, t in sp]

def norm(key):
    key = key.replace("%%", "\0")
    key = SPEC.sub("%§", key)
    return key.replace("\0", "%")

def load(path):
    return json.load(open(os.path.join(ROOT, path), encoding="utf-8"))

def values(entry):
    """(label, string) for every string unit of a catalog entry, per locale."""
    for loc, l in (entry.get("localizations") or {}).items():
        if "stringUnit" in l:
            yield loc, "", l["stringUnit"]
        for kind, forms in (l.get("variations") or {}).items():
            for cat, v in forms.items():
                if "stringUnit" in v:
                    yield loc, f"{kind}.{cat}", v["stringUnit"]

def validate():
    errs, warns = [], []
    for path in list(CATALOGS.values()) + INFOPLIST:
        try:
            cat = load(path)
        except Exception as e:
            errs.append(f"{path}: invalid JSON: {e}")
            continue
        info = path.endswith("InfoPlist.xcstrings")
        for key, entry in cat["strings"].items():
            where = f"{path}: {key!r}"
            if key != key.strip() or not key:
                errs.append(f"{where}: key has leading/trailing whitespace")
            if not info and any(p for p, _ in specs(key)):
                # Text("\(a) \(b)") and String(localized:) look up "%@ %@": positions go in the values only.
                errs.append(f"{where}: key has positional specifiers (%1$@ ...), so it never matches; use %@ / %lld in the key")
            if entry.get("shouldTranslate") is False:
                continue
            locs = entry.get("localizations") or {}
            if "es" not in locs:
                errs.append(f"{where}: no es")
                continue
            ks = sig(key) if not info else []
            es = locs["es"]
            if "stringUnit" not in es and "variations" not in es:
                errs.append(f"{where}: es has no value")
            forms = list(values(entry))
            for loc, form, u in forms:
                v = u.get("value", "")
                if loc == "es" and (not v.strip() or u.get("state") not in ("translated", None)):
                    errs.append(f"{where}: es{'.' + form if form else ''} not translated")
                if v != v.strip() and v.strip() and key == key.strip() and v.strip() != v and loc == "es" and key.strip() == key and (key.endswith(" ") == v.endswith(" ")) is False:
                    warns.append(f"{where}: {loc} value differs in edge whitespace from key")
                if not info:
                    s2 = sig(v)
                    if s2 is None:
                        errs.append(f"{where}: {loc} mixes positional and plain specifiers: {v!r}")
                    elif ks is not None and not form.startswith("plural") and s2 != ks:
                        errs.append(f"{where}: {loc} placeholders {s2} != key's {ks}: {v!r}")
                    elif form.startswith("plural") and ks is not None and len(s2) > len(ks):
                        errs.append(f"{where}: {loc}.{form} has more placeholders than the key: {v!r}")
                    if len(s2 or []) > 1 and not all(p for p, _ in specs(v)):
                        errs.append(f"{where}: {loc} has several placeholders but not positional (%1$@ ...): {v!r}")
            for loc in ("es", "en"):
                l = locs.get(loc) or {}
                pl = (l.get("variations") or {}).get("plural")
                if pl:
                    need = {"one", "other"}
                    if not need <= set(pl):
                        errs.append(f"{where}: {loc} plural needs one and other, has {sorted(pl)}")
                    bad = set(pl) - {"zero", "one", "two", "few", "many", "other"}
                    if bad:
                        errs.append(f"{where}: {loc} plural has unknown categories {bad}")
                    if ks is not None and len(ks) < 1:
                        errs.append(f"{where}: {loc} plural variation but the key has no number placeholder")
            # es identical to en/key
            if "stringUnit" in es and not info:
                v = es["stringUnit"].get("value", "")
                en = (locs.get("en") or {}).get("stringUnit", {}).get("value", key)
                if v == en and not SAME_OK.match(re.sub(r"%[\w$@]+", "%", key.strip())) and len(key) > 3:
                    warns.append(f"{where}: es identical to en")
    return errs, warns

# ---- Swift source scan -----------------------------------------------------

def mask(src):
    """Return (masked, lits): comments and string bodies blanked (positions kept);
    lits maps the offset of an opening quote to (end_offset, raw_body, kind)."""
    out = list(src)
    lits = {}
    n = len(src)
    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "
    def string(i):
        """i at an opening quote; returns index after the closing quote."""
        hashes = 0
        j = i
        while j > 0 and src[j - 1] == "#":
            j -= 1; hashes += 1
        multi = src.startswith('"""', i)
        q = 3 if multi else 1
        k = i + q
        close = '"' * q + "#" * hashes
        esc = "\\" + "#" * hashes
        while k < n:
            if src.startswith(esc + "(", k):
                k = skip_interp(k + len(esc) + 1)
                continue
            if src[k] == "\\" and not hashes:
                k += 2
                continue
            if src.startswith(close, k):
                lits[i] = (k, src[i + q:k], "multi" if multi else ("raw" if hashes else "str"))
                blank(i + q, k)
                return k + len(close)
            if not multi and src[k] == "\n":
                return k
            k += 1
        return n
    def skip_interp(k):
        depth = 1
        while k < n and depth:
            c = src[k]
            if c == '"':
                k = string(k)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            k += 1
        return k
    i = 0
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j); i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j); i = j
        elif c == '"':
            i = string(i)
        else:
            i += 1
    # interpolation bodies of simple strings were blanked with the string; fine.
    return "".join(out), lits

def key_of(body):
    """Catalog key a Swift string literal makes: interpolations become %@ (type unknown, normalized)."""
    out, i = [], 0
    while i < len(body):
        if body.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(body) and depth:
                depth += (body[j] == "(") - (body[j] == ")")
                j += 1
            out.append("%@"); i = j
        elif body.startswith("\\u{", i):
            j = body.index("}", i)
            out.append(chr(int(body[i + 3:j], 16))); i = j + 1
        elif body[i] == "\\" and i + 1 < len(body):
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(body[i + 1], body[i + 1])); i += 2
        else:
            out.append(body[i]); i += 1
    return "".join(out)

# SwiftUI initialisers / modifiers whose first string literal is a LocalizedStringKey.
KEY_FUNCS = ("Text Button Label Toggle Section Picker TextField SecureField TextEditor Menu NavigationLink Link "
             "ProgressView Stepper DatePicker LabeledContent GroupBox DisclosureGroup ContentUnavailableView Tab "
             "navigationTitle navigationSubtitle help accessibilityLabel accessibilityHint accessibilityValue "
             "confirmationDialog alert LocalizedStringKey ShareLink TabItem keyboardShortcut_ Gauge "
             "accessibilityAddTraits_ badge sheetTitle_ ControlGroup SignInWithAppleButton_ Form_ "
            # The Mac's MenuEntry titles: MenuPresenter shows them with Text(LocalizedStringKey(title)).
            "button destructive submenu copy header").split()
KEY_RE = re.compile(r"(?<![\w])(" + "|".join(KEY_FUNCS) + r")\s*\(\s*(?=\")")
LOC_RE = re.compile(r"String\s*\(\s*localized\s*:\s*(?=\")|NSLocalizedString\s*\(\s*(?=\")|LocalizedStringResource\s*\(\s*(?=\")")
LABELED = re.compile(r"\b(title|message|prompt|placeholder|subtitle|label|detail|hint|header|footer|caption)\s*:\s*(?=\")")

def table_for(path):
    p = path.replace("\\", "/")
    if "/Apps/Mac/" in p or p.startswith("Apps/Mac/"): return "mac"
    if "/Apps/iOS/" in p or p.startswith("Apps/iOS/"): return "ios"
    return "Shared"

def arg_end(masked, i):
    """Index of the ')' closing the call whose '(' precedes i."""
    depth, n = 1, len(masked)
    while i < n and depth:
        depth += (masked[i] == "(") - (masked[i] == ")")
        i += 1
    return i

def swift_files(paths):
    for p in paths:
        p = os.path.join(ROOT, p) if not os.path.isabs(p) else p
        if os.path.isfile(p):
            yield p
        else:
            for dp, dn, fn in os.walk(p):
                dn[:] = [d for d in dn if d not in (".build", "Vendor", "Tests", "node_modules", "NotificationService")]
                for f in fn:
                    if f.endswith(".swift"):
                        yield os.path.join(dp, f)

def line_of(src, off):
    return src.count("\n", 0, off) + 1

def scan():
    cats = {}
    for t, path in CATALOGS.items():
        try:
            cats[t] = {norm(k) for k in load(path)["strings"]}
        except Exception:
            cats[t] = set()
    errs, seen = [], 0
    work = [(f, open(f, encoding="utf-8").read()) for f in swift_files(["Apps", "Sources"])]
    while work:
        f, src = work.pop()
        rel = os.path.relpath(f, ROOT)
        masked, lits = mask(src)
        # code inside "\( … )" of a literal is scanned as source of its own
        for _, (_, body, kind) in lits.items():
            if kind == "str" and "\\(" in body:
                for m in re.finditer(r"\\\(", body):
                    depth, j = 1, m.end()
                    while j < len(body) and depth:
                        depth += (body[j] == "(") - (body[j] == ")")
                        j += 1
                    inner = body[m.end():j - 1]
                    if "localized" in inner or KEY_RE.search(inner):
                        work.append((f, inner))
        default = table_for(rel)
        def check(pos, call_end, how):
            nonlocal seen
            end, body, kind = lits[pos]
            if kind != "str":
                return
            tail = masked[end + 1:call_end]
            m = re.search(r"\b(?:tableName|table)\s*:\s*\"", tail)
            table = default
            explicit = False
            if m:
                tq = end + 1 + m.end() - 1
                if tq in lits:
                    table = lits[tq][2]; explicit = True
                    table = lits[tq][1]
            key = key_of(body)
            if not re.search(r"[A-Za-z]", re.sub(r"%[@\w$]*", "", key)):
                return
            seen += 1
            if table in ("mac", "ios") and not explicit:
                pass
            elif table == "Shared" and default == "Shared" and not explicit:
                errs.append(f"{rel}:{line_of(src, pos)}: {how} {key!r}: shared code needs tableName/table: \"Shared\"")
                return
            t = table if table in cats else default
            if table in ("mac", "ios") or table == "Shared":
                pass
            if norm(key) not in cats.get(t, set()):
                errs.append(f"{rel}:{line_of(src, pos)}: {how} {key!r} has no key in {CATALOGS[t]}")
        for m in KEY_RE.finditer(masked):
            pos = m.end()
            call_end = arg_end(masked, m.end())
            check(pos, call_end, m.group(1))
            # a ternary or other expression inside the first argument: literals there are plain String
        for m in LOC_RE.finditer(masked):
            pos = m.end()
            check(pos, arg_end(masked, pos), "localized")
        # ternary literals inside Text(...) / Label(...) and friends: a String, not localized
        for m in re.finditer(r"(?<![\w])(Text|Label|Button|Toggle|navigationTitle|accessibilityLabel|help)\s*\(", masked):
            a = m.end(); b = arg_end(masked, a)
            seg = masked[a:b]
            if seg.lstrip().startswith("verbatim:"):
                continue
            if "?" not in seg or " : " not in seg and ":" not in seg:
                continue
            for q in [p for p in lits if a <= p < b]:
                if re.search(r"(systemImage|systemName|image)\s*:", masked[a:q]):
                    continue
                before = masked[max(a, q - 24):q]
                if re.search(r"(localized:\s*|LocalizedStringKey\(\s*|verbatim:\s*|Text\(\s*|table\w*:\s*)$", before):
                    continue
                if re.search(r"[?:]\s*$", before) or re.search(r"\?\?\s*$", before):
                    key = key_of(lits[q][1])
                    if re.search(r"[A-Za-z]{2}", key) and lits[q][2] == "str":
                        errs.append(f"{rel}:{line_of(src, q)}: literal {key!r} in a ternary in {m.group(1)}( is a plain String, not localized (wrap in String(localized:) or Text(...))")
    return errs, seen

# ---- hunt ------------------------------------------------------------------

SKIP_LINE = re.compile(r"(Logger|\blog\.|print\(|NSLog|fatalError|precondition|assert|systemName|systemImage|Image\(|URL\(|forKey|UserDefaults|@AppStorage|"
                       r"accessibilityIdentifier|\.id\(|Notification\.Name|import |#if|#warning|identifier|\bcase\s+\"|==\s*\"|\"\s*==|\.contains\(\"|hasPrefix|hasSuffix|"
                       r"\.font|SQL|sql|\bkey:|\.json|\.png|header\(|setValue|Bundle\.|NSImage\(named|\.symbol|Color\(\"|\bcategory:\s*\"|subsystem|Notification\.|\.name\()")

def hunt(paths):
    for f in swift_files(paths):
        rel = os.path.relpath(f, ROOT)
        src = open(f, encoding="utf-8").read()
        masked, lits = mask(src)
        lines = src.split("\n")
        covered = set()
        for rx in (KEY_RE, LOC_RE):
            for m in rx.finditer(masked):
                covered.add(m.end())
        for pos, (end, body, kind) in sorted(lits.items()):
            if pos in covered or kind == "raw":
                continue
            ln = line_of(src, pos)
            line = lines[ln - 1]
            if SKIP_LINE.search(line):
                continue
            key = key_of(body)
            plain = re.sub(r"%@", "", key).strip()
            if not re.search(r"[A-Za-z]{2}", plain):
                continue
            # an identifier-looking word is not prose: no space and no capital start or punctuation
            if " " not in plain and not (plain[0].isupper() and plain[1:].islower()) and not re.search(r"[.!?…:]$", plain):
                continue
            if re.fullmatch(r"[\w./:#@%$\-]+", plain) and " " not in plain and not plain[0].isupper():
                continue
            if "/" in plain and " " not in plain:
                continue
            print(f"{rel}:{ln}: {key!r}  | {line.strip()[:110]}")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--hunt":
        hunt(sys.argv[2:] or ["Apps", "Sources"]); sys.exit(0)
    errs, warns = validate()
    serrs, seen = scan()
    for w in warns: print("warn:", w)
    for e in errs + serrs: print("error:", e)
    print(f"{len(errs)} catalog errors, {len(serrs)} source errors ({seen} localized literals scanned), {len(warns)} warnings")
    sys.exit(1 if errs or serrs else 0)
