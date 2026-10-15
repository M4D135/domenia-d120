#!/usr/bin/env python3
"""Read-only source guard for composed workers; native factory checks complement this lexical audit.

The native fixture Test-DomeniaWorkerComposition.ps1 compares the actual factories with PROD.
This guard compares their closed recipes and verifies every body, registry entry and fingerprint.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import inspect
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'wad/tests')]
import update_worker_contracts as contracts
import check_sqlite_layer as sqlite
from powershell_lex import segments


def without_comments(text):
    chars = list(text)
    for kind, start, end in segments(text):
        if kind in ('line', 'block'):
            chars[start:end] = ['\n' if c == '\n' else ' ' for c in text[start:end]]
    return ''.join(chars)


def catalog_statement(value):
    return ("$script:DomeniaExtendedProbeCatalog=@((ConvertFrom-Json -InputObject "
            "([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + value + "')))).Probes)")


def check(root=ROOT):
    """Return diagnostics, preserving imported helpers' roots even on malformed or missing input."""
    root = Path(root).resolve()
    old_roots = contracts.ROOT, sqlite.ROOT
    problems = []
    def require(ok, message):
        if not ok:
            problems.append(message)
    def read(rel):
        return (root / rel).read_text('utf-8-sig')
    try:
        contracts.ROOT = sqlite.ROOT = root
        problems.extend(sqlite.check())
        runtime = without_comments(contracts.function(read('wad/modules/Domenia-QueryLibrary.Model.ps1'),
                                                      'Get-DomeniaQueryLibraryDefinitionValidationCode'))
        prod = without_comments(contracts.function(read('tools/Production.Source.ps1'), 'Get-DomeniaBuildWorkerBody'))
        names = re.search(r'foreach\s*\(\s*\$name\s+in\s+@\(([^)]*)\)\s*\)', runtime)
        actual = re.findall(r"'([^']+)'", names[1]) if names else []
        require(actual == ['Domenia-' + n + '.ps1' for n in contracts.LOCAL_STORE_MODULES],
                'Runtime : liste ou ordre des modules LocalStore different du miroir.')
        for label, code in [('Runtime', runtime), ('PROD', prod)]:
            require('.EndBlock.Statements' in code and 'FunctionDefinitionAst' in code and '.FindAll' not in code,
                    label + ' : extraction des seules fonctions de premier niveau modifiee.')
            expected = '$definitions.Add("`' + catalog_statement('$catalogBase64') + '")'
            lines = [line.strip() for line in code.splitlines()
                     if line.strip().startswith('$definitions.Add("`$script:DomeniaExtendedProbeCatalog=')]
            require(lines == [expected], label + ' : injection du catalogue absente ou modifiee.')
            require('[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($catalogJson))' in re.sub(r'\s+', '', code),
                    label + ' : encodage UTF-8/Base64 du catalogue modifie.')
        normalized = re.sub(r'\s+', '', runtime)
        require("[IO.File]::ReadAllText((Join-Path$PSScriptRoot'Domenia-ProbeCatalog.json'),[Text.Encoding]::UTF8)" in normalized,
                'Runtime : lecture du catalogue versionne modifiee.')
        require('.Replace("`r`n","`n").Replace("`r","`n")' in normalized,
                'Runtime : normalisation CRLF/CR du catalogue modifiee.')
        require('ConvertTo-Json' not in runtime, 'Runtime : serialisation JSON dependante du moteur reintroduite.')
        require("$catalogJson=Read-DomeniaBuildText(Get-DomeniaBuildChildPath$WadRoot'modules/Domenia-ProbeCatalog.json')" in re.sub(r'\s+', '', prod),
                'PROD : lecture du catalogue versionne modifiee.')
        reader = without_comments(contracts.function(read('tools/Production.Source.ps1'), 'Read-DomeniaBuildText'))
        require('.Replace("`r`n","`n").Replace("`r","`n")' in re.sub(r'\s+', '', reader),
                'PROD : normalisation des sources modifiee.')
        mirror = inspect.getsource(contracts.composed_body)
        require('top_level_functions(text)' in mirror and 'in functions(text)' not in mirror,
                'Python : extraction des fonctions de premier niveau modifiee.')
        items = json.loads(read('tools/operation-contracts.json'))
        names = [i['Operation'] for i in items]
        require(len(names) == len(set(n.lower() for n in names)), 'Contrat : operation dupliquee.')
        core = read('wad/Domenia-Core.ps1')
        getter = contracts.function(core, 'Get-DomeniaWorkerOperationHashes')
        pairs = re.findall(r'^\s*(\w+)\s*=\s*"([0-9A-F]{64})"', getter, re.M)
        registry = dict(pairs)
        require(len(pairs) == len(set(n.lower() for n, _ in pairs)), 'Registre : operation dupliquee.')
        require(set(names) == set(registry), 'Registre : ensemble des operations different du contrat.')
        encoded = base64.b64encode(read('wad/modules/Domenia-ProbeCatalog.json').encode('utf-8')).decode('ascii')
        calculated = {}
        for item in items:
            op = item['Operation']
            body = contracts.composed_body(item)
            digest = hashlib.sha256(body.encode('utf-8')).hexdigest().upper()
            calculated[op] = digest
            require(digest == item['Sha256'] == registry.get(op), op + ' : corps, contrat et registre divergent.')
            if op == 'LocalStore':
                require(body.splitlines().count(catalog_statement(encoded)) == 1,
                        'LocalStore : catalogue compose absent, duplique ou different de sa source.')
        require('LocalStore' in calculated, 'Contrat : LocalStore absent.')
        fingerprint = hashlib.sha256('\n'.join(op + '=' + calculated[op] for op in sorted(calculated)).encode()).hexdigest().upper()
        validation = contracts.function(core, 'Assert-DomeniaWorkerRegistry')
        pinned = re.findall(r'\$expectedFingerprint\s*=\s*"([0-9A-F]{64})"', validation)
        require(pinned == [fingerprint], 'Registre : empreinte globale differente des corps calcules.')
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        problems.append('Composition impossible : ' + str(exc))
    finally:
        contracts.ROOT, sqlite.ROOT = old_roots
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    problems = check(args.root)
    print('\n'.join('FAIL: ' + p for p in problems) if problems else 'PASS: recettes composees, corps, registre et empreinte globale coherents.')
    return int(bool(problems))


if __name__ == '__main__':
    sys.exit(main())
