#!/usr/bin/env python3
"""P-CD-08: the SQLite access layer of the workers exists once and every worker that touches the local base composes it.

The layer is the here-string of Get-DomeniaSqliteWorkerCommon (wad/modules/Domenia-Storage.Worker.ps1). The checks:
  1. the layer defines its reviewed functions, once each;
  2. no other script text defines one of them again (worker here-strings included), except the interface layer of the
     core, which defines the native type and reads its lock wait from the configuration instead of a worker context;
  3. the native open, prepare and text binding calls stay in the layer, in the interface layer of the core and in the
     few reviewed exceptions below (each with its reason): a new private copy of the layer is refused;
  4. every pinned operation whose composed body (the mirror of tools/update_worker_contracts.py) calls the layer
     carries the layer exactly once, and every operation listed as composing it does;
  5. the helpers that must behave alike on both sides (UTF-8 marshalling, SQL literal rule) are byte-identical in the
     core and in the layer;
  6. the schema the layer expects (Get-DomeniaSqliteSchemaTarget) is the one the core schema script writes and the one
     the release rules accept (Test-DomeniaSchemaCompatibility, Get-DomeniaMigrationPlan), and no worker body compares
     the schema version or the domenia_schema revision with its own literal, except the reviewed functions of
     REVISION_RULES, whose literal must then be the revision of the layer;
  7. the PROD builder (Get-DomeniaBuildWorkerBody, tools/Production.Source.ps1) composes the pinned bodies from the same
     operation lists, modules, functions and markers as composed_body of tools/update_worker_contracts.py.
Exit 0 when everything holds, 1 otherwise (one line per problem). Reads files only; never runs PowerShell.
"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'wad/tests'))
from powershell_lex import functions  # noqa: E402
import update_worker_contracts as contracts  # noqa: E402

STORAGE = 'wad/modules/Domenia-Storage.Worker.ps1'
CORE = 'wad/Domenia-Core.ps1'
LAYER = ('Initialize-DomeniaWinSqliteNative', 'New-DomeniaUtf8Ptr', 'ConvertFrom-DomeniaUtf8Ptr', 'ConvertTo-DomeniaSqlLiteral',
         'Open-DomeniaDatabase', 'Close-DomeniaDatabase', 'Invoke-DomeniaDbExec', 'Set-DomeniaSqliteBindings',
         'Invoke-DomeniaSqliteRead', 'Invoke-DomeniaDbQuery', 'New-StoreWStatement', 'Set-StoreWStatementValues',
         'Invoke-StoreWStatement', 'Read-StoreWStatementRow', 'Close-StoreWStatements', 'Get-DomeniaSqliteSchemaTarget',
         'Test-DomeniaSqliteSchemaRows')
# Interface layer of the core (UI runspace): defines the native type, reads LocalStore.DatabaseBusyTimeoutMs itself.
CORE_LAYER = ('Initialize-DomeniaWinSqliteNative', 'New-DomeniaUtf8Ptr', 'ConvertFrom-DomeniaUtf8Ptr', 'Open-DomeniaDatabase',
              'Close-DomeniaDatabase', 'Invoke-DomeniaDbExec', 'Invoke-DomeniaDbQuery', 'ConvertTo-DomeniaSqlLiteral')
IDENTICAL = ('New-DomeniaUtf8Ptr', 'ConvertFrom-DomeniaUtf8Ptr', 'ConvertTo-DomeniaSqlLiteral')
# Pinned operations that compose the layer (update_worker_contracts.composed_body) and the unpinned generator that does.
COMPOSING = ('LocalStore', 'StorageUsage', 'StoragePurge', 'StorageBackup', 'StorageMaintenance', 'StorageIntegrity', 'LiveCache',
             'LegacyMigration', 'LocalIndexRead', 'RelationHistoryRead')
# Generators that receive the layer through the pinned helpers of another storage worker: generator -> that worker.
THROUGH = {'Get-DomeniaStorageIntegrityWorkerCode': 'Get-DomeniaStorageUsageWorkerCode',
           'Get-DomeniaStorageRetentionWorkerCode': 'Get-DomeniaStoragePurgeWorkerCode'}
# Native calls allowed outside the layer and the core interface layer: (file, enclosing top-level function, call) -> reason.
NATIVE = re.compile(r'\[Domenia\.WinSqliteNative\]::(sqlite3_open_v2|sqlite3_prepare_v2|sqlite3_bind_text16)\(')
NATIVE_EXCEPTIONS = {
    ('wad/modules/Domenia-StorageLease.Model.ps1', 'Read-StoreWLeaseScalar', 'sqlite3_prepare_v2'):
        'scalar reader of the lease module, composed before the layer and used by the core and the workers alike',
    ('wad/modules/Domenia-Storage.Worker.ps1', 'Get-DomeniaStorageWorkerCode', 'sqlite3_prepare_v2'):
        'Get-SnapWRowsSha256 hashes one text column straight from the UTF-8 buffer of SQLite, row after row',
    ('wad/modules/Domenia-Storage.Worker.ps1', 'Get-DomeniaStorageMaintenanceWorkerCode', 'sqlite3_open_v2'):
        'maintenance re-opens the active base read-write without its write lease to mark it redirected after a switch',
}
COMPOSE_CALL = '(Get-DomeniaSqliteWorkerCommon)'
# Comparison of the domenia_schema revision with a literal: a variable or a property named after the revision.
REVISION_COMPARE = re.compile(r"(?i)(?:revision|domenia_?schema)[\w.\])]*\s*-c?(?:eq|ne)\s*'(\d+)'")
# Reviewed functions that compare the revision with their own literal (file of the source, function) -> reason. Both
# also run in the interface runspace, where the worker layer (Get-DomeniaSqliteSchemaTarget) is absent; the migration
# worker carries them as generated by tools/update_migration_worker.py. Their literal must be the revision of the layer.
REVISION_RULES = {
    ('wad/modules/Domenia-Release.Model.ps1', 'Get-DomeniaMigrationPlan'):
        'the plan shown before any write refuses a base of an unknown revision',
    ('wad/modules/Domenia-Migration.UI.ps1', 'New-DomeniaLegacyImportPlan'):
        'the legacy import refuses a base that Domenia has not prepared (revision absent or different)',
}
BUILDER = 'tools/Production.Source.ps1'


def read(rel):
    return (ROOT / rel).read_text(encoding='utf-8-sig')


def scripts():
    return [CORE] + sorted('wad/modules/' + p.name for p in (ROOT / 'wad/modules').glob('*.ps1'))


def layer_text():
    return contracts.literal_bodies(contracts.function(read(STORAGE), 'Get-DomeniaSqliteWorkerCommon'))[0]


def enclosing(spans, position):
    best = ''
    for name, ranges in spans.items():
        for start, end in ranges:
            if start <= position < end:
                best = name
    return best


def layer_definitions(problems):
    text = layer_text()
    found = {}
    for name, ranges in functions(text).items():
        found[name] = len(ranges)
    for name in LAYER:
        if found.get(name) != 1:
            problems.append('Couche SQLite : %s defini %d fois (1 attendu).' % (name, found.get(name, 0)))
    for name in sorted(set(found) - set(LAYER)):
        problems.append('Couche SQLite : fonction non revue ' + name + ' (ajouter a LAYER apres relecture).')
    return text


def no_copies(problems, layer):
    pattern = re.compile(r'(?m)^function\s+(' + '|'.join(re.escape(n) for n in LAYER) + r')\b')
    for rel in scripts():
        text = read(rel)
        top = functions(text)
        for match in pattern.finditer(text):
            name = match.group(1)
            if (rel == STORAGE) and (text.find(layer) <= match.start() < text.find(layer) + len(layer)):
                continue
            if (rel == CORE) and (name in CORE_LAYER) and any(start == match.start() for start, _end in top.get(name, [])):
                continue
            line = text.count('\n', 0, match.start()) + 1
            problems.append('%s:%d : copie de %s hors de la couche partagee (Get-DomeniaSqliteWorkerCommon).' % (rel, line, name))


def native_calls(problems, layer):
    for rel in scripts() + ['wad/modules/Domenia-StorageLease.Model.ps1']:
        text = read(rel)
        spans = functions(text)
        start = text.find(layer) if rel == STORAGE else -1
        for match in NATIVE.finditer(text):
            if (start >= 0) and (start <= match.start() < start + len(layer)):
                continue
            owner = enclosing(spans, match.start())
            if (rel == CORE) and (owner in CORE_LAYER):
                continue
            if (rel, owner, match.group(1)) in NATIVE_EXCEPTIONS:
                continue
            line = text.count('\n', 0, match.start()) + 1
            problems.append('%s:%d : appel natif %s hors de la couche SQLite partagee (%s).' % (rel, line, match.group(1), owner or 'script'))


def composes(rel, name):
    """True when the generator composes the layer itself, or through the storage worker whose helpers it reuses."""
    text = read(rel)
    fn = contracts.function(text, name)
    if COMPOSE_CALL in fn:
        return True
    through = THROUGH.get(name)
    return bool(through) and (through in fn) and (COMPOSE_CALL in contracts.function(read(STORAGE), through))


def composition(problems, layer):
    items = json.loads((ROOT / 'tools/operation-contracts.json').read_text(encoding='utf-8'))
    uses = re.compile(r'(?<![\w-])(' + '|'.join(re.escape(n) for n in LAYER if n != 'Initialize-DomeniaWinSqliteNative') + r')(?![\w-])')
    pinned = {item['Operation'] for item in items}
    for name in COMPOSING:
        if name not in pinned:
            problems.append('Operation ' + name + ' attendue dans tools/operation-contracts.json.')
    for item in items:
        body = contracts.composed_body(item)
        count = body.count(layer)
        if item['Operation'] in COMPOSING:
            if count != 1:
                problems.append('%s : la couche SQLite partagee figure %d fois dans le corps epingle (1 attendue).' % (item['Operation'], count))
            if not composes(item['File'], item['Function']):
                problems.append('%s : %s ne compose pas Get-DomeniaSqliteWorkerCommon.' % (item['Operation'], item['Function']))
        elif count or uses.search(re.sub(r'(?m)#.*$', '', body)):
            problems.append('%s : utilise la couche SQLite sans etre declaree dans COMPOSING.' % item['Operation'])
    # StorageRetention is launched but not pinned yet (known debt): its generator must still receive the layer.
    if not composes(STORAGE, 'Get-DomeniaStorageRetentionWorkerCode'):
        problems.append('StorageRetention : la couche SQLite partagee ne lui parvient plus par le worker de purge.')


def identical(problems, layer):
    core = read(CORE)
    mine = functions(layer)
    theirs = functions(core)
    for name in IDENTICAL:
        a, b = mine[name][0]
        if len(theirs.get(name, [])) != 1:
            problems.append('Coeur : %s absent ou en double.' % name)
            continue
        c, d = theirs[name][0]
        if layer[a:b] != core[c:d]:
            problems.append('Coeur et couche partagee divergent pour %s : le meme texte est attendu des deux cotes.' % name)


def schema(problems, layer):
    target = re.search(r"SchemaVersion='(\d+)';DomeniaSchema='(\d+)';Label='(\d+)/(\d+)'", layer)
    if not target:
        problems.append('Get-DomeniaSqliteSchemaTarget illisible.')
        return
    version, revision = target.group(1), target.group(2)
    if (target.group(3), target.group(4)) != (version, revision):
        problems.append('Get-DomeniaSqliteSchemaTarget : libelle different de la version.')
    core = read(CORE)
    written = dict(re.findall(r"INSERT OR IGNORE INTO schema_info\(key,value\) VALUES\('(schema_version|domenia_schema)','(\d+)'\);", core))
    if written != {'schema_version': version, 'domenia_schema': revision}:
        problems.append('Script de schema du coeur (%s) different de la couche partagee (%s/%s).' % (written, version, revision))
    release = read('wad/modules/Domenia-Release.Model.ps1')
    compatibility = contracts.function(release, 'Test-DomeniaSchemaCompatibility')
    defaults = (re.search(r'\$ApplicationVersion=(\d+)', compatibility), re.search(r'\$ApplicationRevision=(\d+)', compatibility))
    if (not all(defaults)) or ((defaults[0].group(1), defaults[1].group(1)) != (version, revision)):
        problems.append('Test-DomeniaSchemaCompatibility (Domenia-Release.Model.ps1) : version par defaut differente de %s/%s.' % (version, revision))
    supported = re.findall(r"\[string\[\]\]\$SupportedSchemaVersions=@\('(\d+)'\)", release)
    if (not supported) or any(value != version for value in supported):
        problems.append('Get-DomeniaMigrationPlan (Domenia-Release.Model.ps1) : version de schema prise en charge differente de ' + version + '.')
    for (rel, name), _reason in sorted(REVISION_RULES.items()):
        values = REVISION_COMPARE.findall(contracts.function(read(rel), name))
        if not values:
            problems.append('%s (%s) : comparaison de revision domenia_schema introuvable (REVISION_RULES a revoir).' % (name, rel))
        for value in values:
            if value != revision:
                problems.append('%s (%s) : revision domenia_schema %s differente de la couche partagee (%s).' % (name, rel, value, revision))
    reviewed = {name for _rel, name in REVISION_RULES}
    literal = re.compile(r"-c?(?:eq|ne)\s*'" + re.escape(version) + r"'")
    for rel in scripts():
        text = read(rel)
        for match in re.finditer(r"(?ms)@'\n(.*?)\n^'@", text):
            body = match.group(1)
            if 'schema_version' in body:
                for hit in literal.finditer(body):
                    line = text.count('\n', 0, match.start(1) + hit.start()) + 1
                    problems.append('%s:%d : version de schema comparee a un litteral dans un worker (Test-DomeniaSqliteSchemaRows attendu).' % (rel, line))
            if 'domenia_schema' not in body:
                continue
            spans = functions(body)
            for hit in REVISION_COMPARE.finditer(body):
                line = text.count('\n', 0, match.start(1) + hit.start()) + 1
                if enclosing(spans, hit.start()) in reviewed:
                    if hit.group(1) != revision:
                        problems.append('%s:%d : revision domenia_schema %s differente de la couche partagee (%s).' % (rel, line, hit.group(1), revision))
                    continue
                problems.append('%s:%d : revision domenia_schema comparee a un litteral dans un worker (Test-DomeniaSqliteSchemaRows attendu).' % (rel, line))


def ps_strings(text):
    return [value.replace("''", "'") for value in re.findall(r"'((?:[^']|'')*)'", text)]


def builder(problems):
    """The PROD builder pins the composed body of every operation from the same parts as the Python mirror."""
    path = ROOT / BUILDER
    if not path.is_file():
        problems.append(BUILDER + ' absent : le constructeur PROD doit composer les corps epingles.')
        return
    text = path.read_text(encoding='utf-8-sig')
    try:
        body = contracts.function(text, 'Get-DomeniaBuildWorkerBody')
    except ValueError:
        problems.append(BUILDER + ' : Get-DomeniaBuildWorkerBody absente ou en double.')
        return
    lists = {'sqliteWithLease': contracts.SQLITE_WITH_LEASE, 'sqliteReadOnly': contracts.SQLITE_READ_ONLY,
             'localStoreModules': contracts.LOCAL_STORE_MODULES, 'probeDetailFunctions': contracts.PROBE_DETAIL_FUNCTIONS}
    for name, expected in lists.items():
        found = re.findall(r'(?m)^\s*\$' + name + r'=@\(([^)]*)\)\s*$', body)
        if (len(found) != 1) or (tuple(ps_strings(found[0])) != tuple(expected)):
            problems.append('%s : $%s differente de tools/update_worker_contracts.py (%s).' % (BUILDER, name, ', '.join(expected)))
    through = {}
    for line in re.findall(r"(?m)^\s*(?:else)?if\(\$op -ceq '\w+'\)\{\$through=@\(.*\)\}\s*$", body):
        values = ps_strings(line)
        if len(values) == 3:
            through[values[0]] = (values[1], values[2])
    if through != contracts.THROUGH_STORAGE:
        problems.append(BUILDER + ' : reutilisation des workers de stockage differente de THROUGH_STORAGE.')
    for needed in ("'LocalStore'", "'Get-DomeniaLiveProbeCode'", "'Get-DomeniaQueryLibraryDefinitionValidationCode'",
                   "'modules/Domenia-StorageLease.Model.ps1'", "'Get-DomeniaSqliteWorkerCommon'"):
        if needed not in body:
            problems.append('%s : Get-DomeniaBuildWorkerBody ne compose plus %s.' % (BUILDER, needed))
    contracts_fn = contracts.function(text, 'Update-DomeniaBuildWorkerContracts')
    if 'Get-DomeniaBuildWorkerBody' not in contracts_fn:
        problems.append(BUILDER + ' : Update-DomeniaBuildWorkerContracts epingle un litteral seul au lieu du corps compose.')


def check():
    problems = []
    layer = layer_definitions(problems)
    no_copies(problems, layer)
    native_calls(problems, layer)
    composition(problems, layer)
    identical(problems, layer)
    schema(problems, layer)
    builder(problems)
    return problems


def main():
    problems = check()
    if problems:
        print('\n'.join(problems))
        print('FAIL: %d probleme(s) dans la couche SQLite des workers.' % len(problems))
        return 1
    print('PASS: une seule couche SQLite des workers (Get-DomeniaSqliteWorkerCommon), composee par %d operations epinglees, '
          'sans copie ni appel natif hors revue ; schema attendu identique au coeur et aux regles de livraison.' % len(COMPOSING))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
