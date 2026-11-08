#!/usr/bin/env python3
"""Generates web/js/shell/help-catalog.js from the help catalogue of Domenia 1 (dev/wad/modules/Domenia-UX.help.json).

The 820 topics of Domenia 1 (Name, Title, Text, Kind) become a frozen ES module read by the help of the shell
(web/js/shell/help.js): tooltips, accessible descriptions, the help panel (F1) and the search of the palette.

Rules of Domenia 1 kept (Import-DomeniaUxHelpCatalogue): a topic without name, title or text, or a name present twice,
rejects the whole catalogue (exit code 2, nothing written). Texts are static labels only, never a control value.

French typography is applied to the texts (decision of 21/10, docs/KIT.md § 1.2): typographic apostrophe, no-break space
before « : ; ! ? % » and inside « ». Each topic also gets the screen of Domenia 2 it belongs to (« area »), deduced from
its name, for the help browser of the shell.

Usage (from the root of the repository or from v2/):
    python3 v2/tools/gen_help.py [--check]
--check compares the generated text with the file on disk and exits 1 when they differ (nothing is written).
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
V2 = HERE.parent
REPO = V2.parent
SOURCE = REPO / "dev" / "wad" / "modules" / "Domenia-UX.help.json"
TARGET = V2 / "web" / "js" / "shell" / "help-catalog.js"

NBSP = "\u00a0"

# Screens of Domenia 2 (ids of web/js/app.js) and their labels, in the order of the help browser.
AREAS = [
    ("interface", "Interface et navigation"),
    ("connexion", "Connexion et comptes de la session"),
    ("accueil", "Accueil et tableaux de bord"),
    ("rechercher", "Rechercher et parcourir"),
    ("fiche", "Fiche d’un objet"),
    ("comptes", "Comptes et accès"),
    ("relations", "Utilisateurs et postes"),
    ("poste", "Poste et assistance au poste"),
    ("assistance", "Assistance et dossiers"),
    ("requetes", "Atelier de requêtes"),
    ("audit", "Audit AD"),
    ("schema", "Schéma de l’annuaire"),
    ("synchro", "Synchronisation"),
    ("operations", "Opérations, reçus et journal"),
    ("parametres", "Paramètres, base locale et stockage"),
]

# Ordered rules: the first pattern found in the control name gives its screen.
AREA_RULES = [
    ("connexion", r"Login|Logon(?!Activity)|Reveal|Credential(?!Vault)|AltCred|Auth"),
    ("schema", r"Schema"),
    ("synchro", r"Sync|Replicat|Dc(Compare|Repl)"),
    ("audit", r"Audit|Security(?!Group)|Delegat|Gpo|Krbtgt|Privileg"),
    ("requetes", r"QueryLib|Recipe|Workshop|Probe|Wql|Template|Cmdlet|Query(?!Options|Result|ClearSearch|Favorite|Header|Details|Bar)"),
    ("assistance", r"Support|Ticket|Dossier|Assistance|Incident"),
    ("operations", r"Guard|Receipt|Journal|Log(?!o)|Experience|Activity|Operation|Task|Observab|Diag(?!nostic)"),
    ("relations", r"Relation|Assoc|Link(?!ed)|Orphan|Pair"),
    ("comptes", r"Account|Vault|Secret|Identity|Laps(?!e)|BitLocker"),
    ("rechercher", r"DgObjects|ObjectFilter|GlobalSearch|SearchBar"),
    ("poste", r"Comp(?!are|act|any)|Computer|Machine|Wmi|Inventory|Software|Session|Remote|Rimotte|Assist|Ping|Wake|Service|Restart|Console"),
    ("fiche", r"User|Object|Obj[A-Z]|Smartcard|DesOnly|TabGeneric|TabContainer|Attr|Member|Group|Permission|Raw|Detail|Manager|Expir|Pwd|Password|Unlock|Enable|Disable|Move"),
    ("accueil", r"Fleet|Dash|Board|Widget|Kpi|Health|Collect|Refresh(?!Base)"),
    ("rechercher", r"Search|Global|Tv|Directory|Park|Presence|Selection|Live|Branch|Objects|WorkView|Filter|Ou(?![a-z])|Tree|Preview|Result"),
    ("parametres", r"Index|Storage|Store|Settings|Config|Backup|Migration|Purge|Cache|Data|Base(?!line)"),
    ("interface", r"Ux|Help|Nav|Palette|Theme|Profile|Shell|Header|Banner|Inline|About|Tab"),
]

# Kinds of Domenia 1 controls → kind of the help (tooltip role and icon in the help browser).
KINDS = {
    "Button": "button", "ToggleButton": "button",
    "TextBox": "input", "ComboBox": "input", "DatePicker": "input",
    "PasswordBox": "secret",
    "CheckBox": "choice", "RadioButton": "choice",
    "TextBlock": "status", "ProgressBar": "status",
    "TabItem": "tab", "TabControl": "zone",
    "DataGrid": "list", "ListBox": "list", "ListBoxItem": "list", "TreeView": "list",
}

# A few words of Domenia 1 written without their accents.
FIXES = [
    (r"\bRecus\b", "Reçus"),
    (r"\bpreconditions\b", "préconditions"),
    (r"\bDeverrouill", "Déverrouill"),
    (r"\bdeverrouill", "déverrouill"),
    (r"\bDesactiv", "Désactiv"),
    (r"\bdesactiv", "désactiv"),
    (r"\bcontroleur", "contrôleur"),
]


def typography(text: str) -> str:
    """French typography of a help text: apostrophe, no-break spaces, collapsed blanks."""
    t = text.replace("\r\n", "\n").replace("\r", "\n")
    t = re.sub(r"[ \t]+", " ", t).strip()
    t = t.replace("\u02bc", "\u2019")
    t = re.sub(r"(?<=[A-Za-zÀ-ÿ])'(?=[A-Za-zÀ-ÿ])", "\u2019", t)
    for pattern, replacement in FIXES:
        t = re.sub(pattern, replacement, t)
    t = re.sub(r"«\s*", "«" + NBSP, t)
    t = re.sub(r"\s*»", NBSP + "»", t)
    # No-break space before high punctuation, not inside paths, URLs or times (« C:\ », « https: », « 10:30 »).
    t = re.sub(r"(?<=[^\s\\/:]) ?([;!?])(?=\s|$)", NBSP + r"\1", t)
    t = re.sub(r"(?<=\S) :(?=\s|$)", NBSP + ":", t)
    t = re.sub(r"(?<=[^\s:\\/\d]):(?=\s)", NBSP + ":", t)
    t = re.sub(r"(?<=\d) ?%", NBSP + "%", t)
    return t


def area_of(name: str) -> str:
    for area, pattern in AREA_RULES:
        if re.search(pattern, name):
            return area
    return "interface"


def kind_of(raw: str | None) -> str:
    return KINDS.get(raw or "", "zone")


def load(path: Path) -> list[dict]:
    items = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(items, list):
        raise SystemExit("gen_help.py : le catalogue doit être une liste.")
    seen: set[str] = set()
    topics = []
    for n, item in enumerate(items):
        name = str(item.get("Name") or "").strip()
        title = str(item.get("Title") or "").strip()
        text = str(item.get("Text") or "").strip()
        if not name or not title or not text:
            print(f"gen_help.py : catalogue d’aide incomplet (entrée {n + 1}) : rien n’est écrit.", file=sys.stderr)
            raise SystemExit(2)
        if name in seen:
            print(f"gen_help.py : nom dupliqué dans le catalogue d’aide ({name}) : rien n’est écrit.", file=sys.stderr)
            raise SystemExit(2)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,79}", name):
            print(f"gen_help.py : nom de contrôle invalide ({name!r}) : rien n’est écrit.", file=sys.stderr)
            raise SystemExit(2)
        seen.add(name)
        topics.append({
            "name": name,
            "title": typography(title),
            "text": typography(text),
            "kind": kind_of(item.get("Kind")),
            "area": area_of(name),
        })
    return topics


def render(topics: list[dict], digest: str) -> str:
    def js(value: str) -> str:
        return json.dumps(value, ensure_ascii=False)

    lines = [
        "// Generated by v2/tools/gen_help.py from dev/wad/modules/Domenia-UX.help.json: do not edit by hand.",
        "// Help catalogue of Domenia 1 (TRV-004): [name, title, text, kind, area] per control, French typography applied.",
        "// Static labels only: no control value ever goes into a help text.",
        f"export const HELP_SOURCE = Object.freeze({{ file: 'Domenia-UX.help.json', count: {len(topics)}, sha256: '{digest}' }});",
        "",
        "/** Screens of Domenia 2 used to group the topics: [id, label]. */",
        "export const HELP_AREAS = Object.freeze([",
    ]
    lines += [f"  [{js(a)}, {js(label)}]," for a, label in AREAS]
    lines += [
        "]);",
        "",
        "/** Topics: [name, title, text, kind, area]; kind is button, input, secret, choice, status, tab, list or zone. */",
        "export const HELP_TOPICS = Object.freeze([",
    ]
    for t in topics:
        lines.append(f"  [{js(t['name'])}, {js(t['title'])}, {js(t['text'])}, {js(t['kind'])}, {js(t['area'])}],")
    lines += ["]);", ""]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    check = "--check" in argv
    if not SOURCE.is_file():
        print(f"gen_help.py : catalogue introuvable : {SOURCE}", file=sys.stderr)
        return 2
    digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    topics = load(SOURCE)
    text = render(topics, digest)
    if check:
        current = TARGET.read_text(encoding="utf-8") if TARGET.is_file() else ""
        if current != text:
            print("gen_help.py : web/js/shell/help-catalog.js n’est pas à jour (relancer sans --check).", file=sys.stderr)
            return 1
        print("gen_help.py : catalogue à jour.")
        return 0
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(text, encoding="utf-8")
    areas = Counter(t["area"] for t in topics)
    kinds = Counter(t["kind"] for t in topics)
    print(f"gen_help.py : {len(topics)} sujets écrits dans {TARGET.relative_to(REPO)} ({len(text.encode('utf-8'))} octets).")
    print("  écrans : " + ", ".join(f"{a} {areas[a]}" for a, _ in AREAS if areas[a]))
    print("  natures : " + ", ".join(f"{k} {n}" for k, n in kinds.most_common()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
