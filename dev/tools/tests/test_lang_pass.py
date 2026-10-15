"""Offline tests of tools/lang_pass.py (P-UI-04). Temporary trees only; the real tree is read, never written.

Usage (from dev/): python3 -m unittest discover -s tools/tests -q
"""
from collections import Counter
from pathlib import Path
import contextlib
import io
import json
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
TOOLS = DEV / 'tools'
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))
import audit_wording as aw  # noqa: E402
import lang_pass as lp  # noqa: E402

CORE = '''$xaml = @'
<Window>
  <Button x:Name="BtnA" Content="Detecter l utilisateur" ToolTip="Ouvre l objet selectionne." AutomationProperties.Name="Detecter l utilisateur" AutomationProperties.HelpText="Ouvre l objet selectionne."/>
  <TextBlock Text="Resultats &amp; etat   du  poste"/>
</Window>
'@
Set-Status 'Recherche terminee.' 'INFO'
$label.Text = "Erreur : $detail`r`nVerifie le reseau."
$h.Header = 'Etat'
if ($h.Header -eq 'Etat') { }
[Windows.Automation.AutomationProperties]::SetName($panel,'Chargement de l arbre')
'''
HELP = [{'Name': 'BtnA', 'Title': 'Detecter l utilisateur', 'Text': 'Ouvre l objet selectionne.'}]
SURE = {
    'Detecter l utilisateur': 'Détecter lʼutilisateur',
    'Ouvre l objet selectionne.': 'Ouvre lʼobjet sélectionné.',
    'Resultats & etat du poste': 'Résultats & état du poste',
    'Recherche terminee.': 'Recherche terminée.',
    'Etat': 'État',
    'Chargement de l arbre': 'Chargement de lʼarbre',
}
REVIEW = {'Erreur : $detailrnVerifie le reseau.': 'Erreur : $detailrnVérifiez le réseau.'}
TEST = "Assert-Equal 'Recherche terminee.' $status\nAssert-True ($hint -like '*reseau*')\n"


class Tree:
    """A minimal dev tree: core, help, one test suite and both maps."""

    def __init__(self, core=CORE, help_entries=HELP, sure=SURE, review=REVIEW, test=TEST):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'wad/modules').mkdir(parents=True)
        (self.root / 'wad/tests').mkdir(parents=True)
        (self.root / lp.MAP_DIR).mkdir(parents=True)
        self.core = self.root / 'wad/Domenia-Core.ps1'
        self.core.write_bytes(b'\xef\xbb\xbf' + core.encode('utf-8'))
        self.help = self.root / aw.HELP_JSON
        self.help.write_text(json.dumps(help_entries, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        (self.root / 'wad/tests/Test-Sample.ps1').write_bytes(b'\xef\xbb\xbf' + test.encode('utf-8'))
        lp.write_map(self.root / lp.SURE_MAP, sure)
        lp.write_map(self.root / lp.REVIEW_MAP, review)

    def maps(self):
        return lp.load_maps(self.root)

    def cleanup(self):
        self.tmp.cleanup()


class CheckPairTests(unittest.TestCase):
    def test_typographic_correction_is_safe(self):
        self.assertEqual(lp.check_pair('Ouvre l objet selectionne.', 'Ouvre lʼobjet sélectionné.'), ([], []))

    def test_refusals(self):
        cases = {
            "Ouvre l'objet sélectionné.": "apostrophe ' (utiliser U+02BC)",
            'Ouvre l’objet sélectionné.': 'guillemet typographique (délimiteur PowerShell)',
            'Ouvre lʼobjet selectionne.': 'audit accent : selectionne',
            'Ouvre lʼobjet  sélectionné.': 'espaces non normalisés',
            'Ouvre l objet selectionne.': 'aucun changement',
        }
        for new, error in cases.items():
            errors, _ = lp.check_pair('Ouvre l objet selectionne.', new)
            self.assertIn(error, errors, new)

    def test_placeholders_are_kept(self):
        errors, _ = lp.check_pair('Erreur : $detail ($($r.Count) elements, {0})', 'Erreur : $détail ($($r.Count) éléments, {0})')
        self.assertIn('variables ou paramètres modifiés', errors)
        errors, _ = lp.check_pair('Total {0} elements', 'Total éléments')
        self.assertIn('variables ou paramètres modifiés', errors)
        errors, _ = lp.check_pair('Cout 5 $ par poste', 'Coût 5 par poste')
        self.assertIn('caractère $ ou ` ajouté ou retiré', errors)

    def test_word_swallowed_by_an_escaped_line_break_is_text(self):
        # "$message`r`n`r`nVerifie" is read by the audit as $messagernrnVerifie.
        errors, warnings = lp.check_pair('$messagernrnVerifie les etapes', '$messagernrnVérifiez les étapes')
        self.assertEqual(errors, [])
        self.assertEqual(warnings, ['reformulation (pas seulement accents et apostrophes)'])

    def test_change_of_person_goes_to_review(self):
        errors, warnings = lp.check_pair('Selectionne un poste.', 'Sélectionnez un poste.')
        self.assertEqual(errors, [])
        self.assertIn('reformulation (pas seulement accents et apostrophes)', warnings)


class MapTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()

    def tearDown(self):
        self.tree.cleanup()

    def test_read_map_normalizes_and_refuses_contradictions(self):
        path = self.tree.root / 'map.json'
        lp.write_map(path, {' : lisez l  aide': ' : lisez lʼaide'})
        self.assertEqual(lp.read_map(path), {': lisez l aide': ': lisez lʼaide'})
        lp.write_map(path, {'a  b c': 'x', 'a b c': 'y'})
        with self.assertRaises(ValueError):
            lp.read_map(path)

    def test_safe_map_wins_over_review_map(self):
        lp.write_map(self.tree.root / lp.REVIEW_MAP, {'Etat': 'Statut'})
        self.assertEqual(self.tree.maps()['Etat'], ('État', lp.SURE))

    def test_merge_routes_pairs_and_keeps_the_format(self):
        sure_path = self.tree.root / lp.SURE_MAP
        report = lp.merge(self.tree.root, {'Etat du poste': 'État du poste', 'Selectionne un poste.': 'Sélectionnez un poste.',
                                           'Etat': 'État'})
        self.assertEqual((report[lp.SURE], report[lp.REVIEW], report['Unchanged']),
                         (['Etat du poste'], ['Selectionne un poste.'], ['Etat']))
        raw = sure_path.read_text(encoding='utf-8')
        self.assertTrue(raw.startswith('{\n"Detecter l utilisateur": "Détecter lʼutilisateur",\n'))
        self.assertTrue(raw.endswith('"Etat du poste": "État du poste"\n}'))
        self.assertEqual(list(json.loads(raw))[:len(SURE)], list(SURE))
        self.assertEqual(lp.read_map(self.tree.root / lp.REVIEW_MAP)['Selectionne un poste.'], 'Sélectionnez un poste.')

    def test_merge_refuses_conflicts_and_bad_pairs_without_writing(self):
        before = (self.tree.root / lp.SURE_MAP).read_bytes()
        report = lp.merge(self.tree.root, {'Etat': 'Statut', 'Etat du parc': "Etat du parc", 'Ouvre  l OU': 'Ouvre lʼOU',
                                           'Detail': 'Détail'})
        self.assertEqual(sorted(r['Text'] for r in report['Refused']), ['Etat', 'Etat du parc', 'Ouvre  l OU'])
        self.assertEqual((self.tree.root / lp.SURE_MAP).read_bytes(), before, 'nothing is written when a pair is refused')

    def test_cli_merge_exit_code(self):
        pairs = self.tree.root / 'pairs.json'
        pairs.write_text(json.dumps({'Etat': 'Statut'}, ensure_ascii=False), encoding='utf-8')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lp.main(['--root', str(self.tree.root), '--merge', str(pairs)]), 1)
        pairs.write_text(json.dumps({'Derniere mesure': 'Dernière mesure'}, ensure_ascii=False), encoding='utf-8')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lp.main(['--root', str(self.tree.root), '--merge', str(pairs)]), 0)
        self.assertEqual(lp.read_map(self.tree.root / lp.SURE_MAP)['Derniere mesure'], 'Dernière mesure')


class RewriteTests(unittest.TestCase):
    def rewrite(self, body, segments, new, encode):
        return lp.rewrite(body, lp.collapse(segments(body)), new, encode)

    def test_single_quoted_string(self):
        # An existing '' becomes the U+02BC apostrophe; the new apostrophe never closes the string.
        self.assertEqual(self.rewrite("l''objet n est pas a jour", lp.segments_single, 'lʼobjet nʼest pas à jour',
                                      lp.encode_single), 'lʼobjet nʼest pas à jour')
        self.assertEqual(lp.encode_single("l'objet"), "l''objet")
        with self.assertRaises(lp.Manual):
            lp.encode_single('l’objet')

    def test_double_quoted_string_keeps_escapes_and_variables(self):
        body = 'Erreur `"x`" : $detail`r`nVerifie le reseau.'
        self.assertEqual(lp.decode(body, '"'), 'Erreur "x" : $detailrnVerifie le reseau.')
        self.assertEqual(self.rewrite(body, lp.segments_double, 'Erreur "x" : $detailrnVérifiez le réseau.', lp.encode_double),
                         'Erreur `"x`" : $detail`r`nVérifiez le réseau.')
        with self.assertRaises(lp.Manual):
            self.rewrite(body, lp.segments_double, 'Erreur "x" : $detailRnVerifie le reseau.', lp.encode_double)
        with self.assertRaises(lp.Manual):
            self.rewrite(body, lp.segments_double, 'Erreur "x" : $detailrnVerifie le réseau $x.', lp.encode_double)
        self.assertEqual(lp.encode_double('a "b" `c'), 'a `"b`" ``c')

    def test_xaml_attribute_keeps_entities(self):
        body = 'Resultats &amp; etat &#233;crit'
        self.assertEqual(self.rewrite(body, lp.segments_xaml, 'Résultats & état écrit', lp.encode_xaml),
                         'Résultats &amp; état &#233;crit')
        with self.assertRaises(lp.Manual):
            self.rewrite(body, lp.segments_xaml, 'Résultats & état ecrit', lp.encode_xaml)
        self.assertEqual(lp.encode_xaml('"a" < b & c'), '&quot;a&quot; &lt; b &amp; c')
        with self.assertRaises(lp.Manual):
            lp.encode_xaml_ps('coût $')

    def test_whitespace_runs_are_kept(self):
        self.assertEqual(self.rewrite('  Etat  du\n poste ', lp.segments_plain, 'État du poste', lp.encode_plain),
                         '  État  du\n poste ')
        with self.assertRaises(lp.Manual):
            self.rewrite('Etat  du poste', lp.segments_plain, 'Étatdu poste', lp.encode_plain)


class ComparisonTests(unittest.TestCase):
    def test_line_comparisons(self):
        cases = {
            "if ($x -eq 'Etat') { }": [('eq', '', 'Etat')],
            "if ('Etat' -ceq $x) { }": [('eq', 'c', 'Etat')],
            "$x -cnotlike 'A*'": [('notlike', 'c', 'A*')],
            "elseif($h -in @('A','Derniere connexion')){}": [('in', '', 'A'), ('in', '', 'Derniere connexion')],
            "if (@('a','b') -contains $v) {}": [('contains', '', 'a'), ('contains', '', 'b')],
            "    'Etat' { 1 }": [('case', '', 'Etat')],
            "    'Etat*' { 1 }": [('case', '', 'Etat*'), ('like', '', 'Etat*')],
            "$m['Etat'] = 1": [('key', '', 'Etat')],
            "$o = @{ 'Etat' = 1 }": [('key', '', 'Etat')],
            "$s.StartsWith('Desactive')": [('method:StartsWith', '', 'Desactive')],
            "@($l | Where-Object { $_.Contains('(Verifie)') })": [('method:Contains', '', '(Verifie)')],
            "if ($h.ContainsKey('Etat')) { }": [('method:ContainsKey', '', 'Etat')],
            "Set-Status 'Etat' 'INFO' # -eq 'x'": [],
            '$x -like "*$name*"': [],
        }
        for line, expected in cases.items():
            self.assertEqual(lp.line_comparisons(line), expected, line)

    def test_wildcards(self):
        self.assertTrue(lp.comparison('like', '', 'Desactive*')('desactive le compte'))
        self.assertFalse(lp.comparison('like', 'c', 'Desactive*')('desactive le compte'))
        self.assertTrue(lp.comparison('like', '', '[ab]?c`*')('bxc*'))
        self.assertFalse(lp.comparison('like', '', '[ab]?c`*')('bxcd'))

    def test_only_lost_matches_on_a_shared_word_are_followed(self):
        def changed(op, literal, old='Desactive le compte', new='Désactivé le compte'):
            found = lp.Comparisons()
            found.add(op, '', literal, 'x.ps1:1')
            return found.changed(old, new)
        self.assertEqual(changed('like', 'Desactive*'), ['x.ps1:1'])
        self.assertEqual(changed('match', '^(Desactive|Aucun)'), ['x.ps1:1'])
        self.assertEqual(changed('eq', 'desactive le compte'), ['x.ps1:1'])
        self.assertEqual(changed('method:StartsWith', 'Desactive'), ['x.ps1:1'])
        self.assertEqual(changed('like', 'Désactivé*'), [], 'a pattern already accented')
        self.assertEqual(changed('match', 'registre', 'Non enregistre', 'Non enregistré'), [],
                         'a word inside another word is not followed')
        self.assertEqual(changed('match', 'compte'), [], 'the match is kept')
        self.assertEqual(changed('match', r'^[A-Za-z_][A-Za-z0-9_]{0,127}$', 'Etat', 'État'), [], 'a shape check')
        self.assertEqual(lp.content_words('match', r'(?i)\bdelai\b|chemin reseau'), {'delai', 'chemin', 'reseau'})

    def test_string_methods_are_not_operators(self):
        # String.Contains is a substring check; the -contains operator compares whole items.
        def changed(op, literal, old='$message (Verifie)', new='$message (Vérifié)'):
            found = lp.Comparisons()
            found.add(op, '', literal, 'x.ps1:1')
            return found.changed(old, new)
        self.assertEqual(changed('method:Contains', '(Verifie)'), ['x.ps1:1'])
        self.assertEqual(changed('method:IndexOf', 'Verifie'), ['x.ps1:1'])
        self.assertEqual(changed('contains', '(Verifie)'), [], 'an item equal to (Verifie) is not this text')
        self.assertEqual(changed('method:Contains', 'Aucun plan confirme', 'Aucun plan confirme : rien',
                                 'Aucun plan confirmé : rien'), ['x.ps1:1'])
        self.assertEqual(changed('method:Contains', 'registre', 'Non enregistre', 'Non enregistré'), [],
                         'a word inside another word is not followed')
        # The same call on a list or a hashtable tests membership: a reworded text equal to the item is followed too.
        self.assertEqual(changed('method:Contains', 'Etat', 'Etat', 'Etat du poste'), ['x.ps1:1'])
        self.assertEqual(changed('method:Contains', '[Etat]', 'Etat [Etat]', 'État [État]'), ['x.ps1:1'],
                         'brackets are plain characters in a substring')
        self.assertTrue(lp.comparison('method:Contains', '', 'Etat')('Etat du poste'))
        self.assertFalse(lp.comparison('method:Contains', '', 'Etat')('etat du poste'), 'ordinal, with the case')
        self.assertTrue(lp.comparison('method:ContainsKey', '', 'Etat')('etat'), 'hashtable keys ignore the case')
        self.assertFalse(lp.comparison('method:Equals', '', 'Etat')('etat'))
        self.assertTrue(lp.comparison('contains', '', 'Etat')('etat'))
        self.assertFalse(lp.comparison('contains', '', 'Etat')('Etat du poste'))
        self.assertIsNone(lp.content_words('method:ContainsKey', 'Etat'))
        with self.assertRaises(ValueError):
            lp.comparison('method:Trim', '', 'x')
        with self.assertRaises(ValueError):
            lp.comparison('ge', '', 'x')

    def test_lost_reports_the_kind_and_marks_keys_as_possible(self):
        found = lp.Comparisons()
        for op, case, literal in lp.line_comparisons("if ($h.Header -ceq 'Etat' -and $m['Etat']) { }"):
            found.add(op, case, literal, 'x.ps1:7', "if ($h.Header -ceq 'Etat' -and $m['Etat']) { }")
        lost = found.lost('Etat', 'État')
        self.assertEqual([(d['Comparison'], d['Possible']) for d in lost], [('-ceq', False), ('clé', True)])
        self.assertEqual(found.changed('Etat', 'État'), ['x.ps1:7'], 'one place once')
        self.assertEqual(lp.describe(lost), 'x.ps1:7 (-ceq), x.ps1:7 (clé, possible)')
        found = lp.Comparisons()
        found.add('method:ContainsKey', '', 'Etat', 'x.ps1:8')
        self.assertEqual([(d['Comparison'], d['Possible']) for d in found.lost('Etat', 'État')], [('.ContainsKey', True)])
        self.assertEqual(lp.describe(lost * 2), 'x.ps1:7 (-ceq), x.ps1:7 (clé, possible), x.ps1:7 (-ceq), et 1 autre')


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()

    def tearDown(self):
        self.tree.cleanup()

    def plan(self, include_review=False):
        return lp.plan(self.tree.root, self.tree.maps(), include_review)

    def test_inventory_matches_the_audit_and_adds_accessibility(self):
        occ = lp.inventory(self.tree.root)
        ours = Counter((o['File'], o['Line'], o['Kind'], o['Value']) for o in occ if not o['Kind'].startswith('a11y.'))
        self.assertEqual(ours, Counter(aw.collect(self.tree.root)))
        kinds = {(o['Kind'], o['Text']) for o in occ if o['Kind'].startswith('a11y.')}
        self.assertEqual(kinds, {('a11y.Name', 'Detecter l utilisateur'), ('a11y.HelpText', 'Ouvre l objet selectionne.'),
                                 ('a11y.SetName', 'Chargement de l arbre')})
        self.assertFalse([o for o in occ if o['Manual'] and 'non localisé' in o['Manual']])

    def test_dry_run_plan(self):
        before = self.tree.core.read_bytes()
        edits, report = self.plan()
        self.assertEqual(self.tree.core.read_bytes(), before)
        planned = Counter(e['Text'] for e in edits)
        self.assertEqual(planned, Counter({'Detecter l utilisateur': 3, 'Ouvre l objet selectionne.': 3,
                                           'Resultats & etat du poste': 1, 'Recherche terminee.': 1,
                                           'Chargement de l arbre': 1}))
        self.assertEqual(report['ReviewPending'], 1)
        self.assertEqual(report['Coverage']['Uncovered'], 0)
        manual = {(m['Text'], m['Reason'].split(' :')[0]) for m in report['Manual']}
        self.assertEqual(manual, {('Etat', 'comparaison dans le code changée')})
        self.assertEqual(report['Tests'], [{'Text': 'Recherche terminee.', 'New': 'Recherche terminée.',
                                            'Literal': ['wad/tests/Test-Sample.ps1:1'], 'Pattern': []}])
        self.assertEqual(report['Planned']['AuditFindingsAfter'], 2, 'Etat (held) and the pending review pair')

    def test_uncovered_texts_are_reported(self):
        lp.write_map(self.tree.root / lp.SURE_MAP, {})
        lp.write_map(self.tree.root / lp.REVIEW_MAP, {})
        _, report = self.plan()
        texts = {u['Text']: u for u in report['Uncovered']}
        self.assertNotIn('Recherche terminee.', texts, 'not a fault of the audit: a map may still correct it')
        self.assertEqual(texts['Detecter l utilisateur']['Rules'], ['accent', 'elision'])
        self.assertEqual(texts['Detecter l utilisateur']['Places'], ['wad/Domenia-Core.ps1:3', 'wad/modules/Domenia-UX.help.json:1'])
        self.assertEqual(texts['Erreur : $detailrnVerifie le reseau.']['Words'], ['reseau'])
        self.assertTrue(texts['Chargement de l arbre']['Accessibility'])
        self.assertEqual(report['Planned']['Edits'], 0)

    def test_apply_writes_only_the_planned_spans(self):
        edits, report = self.plan(include_review=True)
        written = lp.apply(self.tree.root, edits)
        self.assertEqual(written, ['wad/Domenia-Core.ps1', 'wad/modules/Domenia-UX.help.json'])
        raw = self.tree.core.read_bytes()
        self.assertTrue(raw.startswith(b'\xef\xbb\xbf'), 'the BOM is kept')
        text = raw.decode('utf-8-sig')
        expected = (CORE.replace('Content="Detecter l utilisateur"', 'Content="Détecter lʼutilisateur"')
                    .replace('AutomationProperties.Name="Detecter l utilisateur"', 'AutomationProperties.Name="Détecter lʼutilisateur"')
                    .replace('"Ouvre l objet selectionne."', '"Ouvre lʼobjet sélectionné."')
                    .replace('Resultats &amp; etat   du  poste', 'Résultats &amp; état   du  poste')
                    .replace("'Recherche terminee.'", "'Recherche terminée.'")
                    .replace('"Erreur : $detail`r`nVerifie le reseau."', '"Erreur : $detail`r`nVérifiez le réseau."')
                    .replace("'Chargement de l arbre'", "'Chargement de lʼarbre'"))
        self.assertEqual(text, expected)
        self.assertIn("$h.Header = 'Etat'", text)
        self.assertEqual(json.loads(self.tree.help.read_text(encoding='utf-8')),
                         [{'Name': 'BtnA', 'Title': 'Détecter lʼutilisateur', 'Text': 'Ouvre lʼobjet sélectionné.'}])
        self.assertTrue(self.tree.help.read_text(encoding='utf-8').endswith('}\n]\n'))
        self.assertEqual(len(aw.findings(self.tree.root)), report['Planned']['AuditFindingsAfter'])
        self.assertEqual(lp.plan(self.tree.root, self.tree.maps(), True)[0], [], 'a second pass has nothing left to do')

    def test_apply_refuses_a_source_changed_after_the_plan(self):
        edits, _ = self.plan()
        self.tree.core.write_bytes(b'\xef\xbb\xbf' + ('# moved\n' + CORE).encode('utf-8'))
        before_help = self.tree.help.read_bytes()
        with self.assertRaises(RuntimeError):
            lp.apply(self.tree.root, edits)
        self.assertEqual(self.tree.help.read_bytes(), before_help, 'no file is written when one check fails')

    def test_crlf_files_keep_their_line_endings(self):
        self.tree.core.write_bytes(b'\xef\xbb\xbf' + CORE.replace('\n', '\r\n').encode('utf-8'))
        edits, _ = self.plan()
        lp.apply(self.tree.root, edits)
        text = self.tree.core.read_bytes().decode('utf-8-sig')
        self.assertIn("Set-Status 'Recherche terminée.' 'INFO'\r\n", text)
        self.assertNotIn('\n', text.replace('\r\n', ''))

    def test_a_held_text_is_rewritten_nowhere(self):
        core = CORE + "$tip.ToolTip = 'Ouvre l objet selectionne.'\nif ($tip.ToolTip -like 'Ouvre l objet*') { }\n"
        self.tree.core.write_bytes(b'\xef\xbb\xbf' + core.encode('utf-8'))
        edits, report = self.plan()
        self.assertNotIn('Ouvre l objet selectionne.', {e['Text'] for e in edits})
        reasons = {m['Reason'].split(' :')[0] for m in report['Manual'] if m['Text'] == 'Ouvre l objet selectionne.'}
        self.assertEqual(reasons, {'comparaison dans le code changée'})
        self.assertEqual(len([m for m in report['Manual'] if m['Text'] == 'Ouvre l objet selectionne.']), 4)

    def test_literal_operands_and_keys_inside_interface_lines_are_code(self):
        core = ("$label.Text = $(if ($mode -eq 'Recherche terminee.') { 'Recherche terminee.' } else { 'x' })\n"
                "$label.Text = $labels['Recherche terminee.']\n")
        self.tree.core.write_bytes(b'\xef\xbb\xbf' + core.encode('utf-8'))
        edits, report = self.plan()
        self.assertEqual([e for e in edits if e['File'] == 'wad/Domenia-Core.ps1'], [])
        reasons = {(m['Line'], m['Reason']) for m in report['Manual'] if m['File'] == 'wad/Domenia-Core.ps1'}
        self.assertEqual(reasons, {(1, 'littéral opérande dʼune comparaison'), (2, 'littéral utilisé comme clé'),
                                   (1, 'comparaison dans le code changée : wad/Domenia-Core.ps1:1 (-eq), '
                                       'wad/Domenia-Core.ps1:2 (clé, possible)')})

    def test_string_contains_in_code_and_tests_is_followed(self):
        core = CORE + 'Set-Status "$message (Verifie)"\nif ($s.Contains(\'Recherche terminee\')) { }\n'
        self.tree.core.write_bytes(b'\xef\xbb\xbf' + core.encode('utf-8'))
        (self.tree.root / 'wad/tests/Test-Sample.ps1').write_bytes(
            b'\xef\xbb\xbf' + "Assert-True (@($s | Where-Object { $_.Contains('(Verifie)') }).Count -ge 1)\n".encode('utf-8'))
        lp.write_map(self.tree.root / lp.SURE_MAP, dict(SURE, **{'$message (Verifie)': '$message (Vérifié)'}))
        edits, report = self.plan()
        self.assertIn('$message (Verifie)', {e['Text'] for e in edits})
        self.assertNotIn('Recherche terminee.', {e['Text'] for e in edits}, 'held by .Contains in the code')
        self.assertEqual({m['Reason'] for m in report['Manual'] if m['Text'] == 'Recherche terminee.'},
                         {'comparaison dans le code changée : wad/Domenia-Core.ps1:13 (.Contains)'})
        self.assertEqual([t['Pattern'] for t in report['Tests'] if t['Text'] == '$message (Verifie)'],
                         [['wad/tests/Test-Sample.ps1:1']])

    def test_cleared_comparisons_release_a_text_until_their_line_changes(self):
        cleared = self.tree.root / lp.CLEARED
        code = "if ($h.Header -eq 'Etat') { }"
        entry = {'Text': 'Etat', 'File': 'wad/Domenia-Core.ps1', 'Code': code, 'Reason': 'Autre donnée.'}
        cleared.write_text(json.dumps([entry], ensure_ascii=False), encoding='utf-8')
        edits, report = self.plan()
        self.assertIn('Etat', {e['Text'] for e in edits})
        self.assertEqual(report['Cleared'], [{'Text': 'Etat', 'Place': 'wad/Domenia-Core.ps1:10', 'Comparison': '-eq',
                                              'Reason': 'Autre donnée.'}])
        self.assertEqual((report['Dependencies'], report['UnusedCleared']), ([], []))
        self.tree.core.write_bytes(b'\xef\xbb\xbf' + CORE.replace(code, "if ($h.Header -ceq 'Etat') { }").encode('utf-8'))
        edits, report = self.plan()
        self.assertNotIn('Etat', {e['Text'] for e in edits}, 'a changed line holds the text again')
        self.assertEqual(report['UnusedCleared'], [{'Text': 'Etat', 'File': 'wad/Domenia-Core.ps1', 'Code': code}])
        self.assertEqual([d['Text'] for d in report['Dependencies']], ['Etat'])
        for bad in ({'Text': 'Etat', 'File': 'f'}, dict(entry, Reason=' '), dict(entry, Text='Etat  ')):
            cleared.write_text(json.dumps([bad], ensure_ascii=False), encoding='utf-8')
            with self.assertRaises(ValueError):
                lp.read_cleared(cleared)
        cleared.write_text(json.dumps([entry, entry], ensure_ascii=False), encoding='utf-8')
        with self.assertRaises(ValueError):
            lp.read_cleared(cleared)

    def test_overlapping_occurrences_are_left_manual(self):
        core = "Set-Status '<TextBlock Text=\"Etat du poste\"/>'\n"
        self.tree.core.write_bytes(b'\xef\xbb\xbf' + core.encode('utf-8'))
        lp.write_map(self.tree.root / lp.SURE_MAP, {'Etat du poste': 'État du poste',
                                                    '<TextBlock Text="Etat du poste"/>': '<TextBlock Text="État du poste"/>'})
        edits, report = self.plan()
        self.assertEqual(edits, [])
        self.assertEqual({m['Reason'] for m in report['Manual']}, {'occurrences superposées'})

    def test_cli_dry_run_writes_nothing(self):
        before = self.tree.core.read_bytes()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(lp.main(['--root', str(self.tree.root)]), 0)
        self.assertEqual(self.tree.core.read_bytes(), before)
        summary = json.loads(out.getvalue())
        self.assertEqual(summary['Status'], 'DRY-RUN')
        self.assertEqual(summary['TestsToUpdate'], ['Recherche terminee. -> Recherche terminée. : wad/tests/Test-Sample.ps1:1'])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lp.main(['--root', str(self.tree.root), '--apply', '--include-review']), 0)
        self.assertNotEqual(self.tree.core.read_bytes(), before)


class RepositoryTests(unittest.TestCase):
    """Read-only checks on the real tree: the inventory is the audit's and the maps cover every faulty text."""

    @classmethod
    def setUpClass(cls):
        cls.maps = lp.load_maps(DEV)
        cls.edits, cls.report = lp.plan(DEV, cls.maps, include_review=True)

    def test_inventory_is_the_audit_inventory(self):
        occ = lp.inventory(DEV)
        ours = Counter((o['File'], o['Line'], o['Kind'], o['Value']) for o in occ if not o['Kind'].startswith('a11y.'))
        self.assertEqual(ours, Counter(aw.collect(DEV)))

    def test_maps_cover_every_faulty_text(self):
        self.assertEqual([u['Text'] for u in self.report['Uncovered'] if not u['Accessibility']], [])
        self.assertEqual(self.report['Refused'], [])

    def test_safe_map_is_typographic_and_cleared_list_is_current(self):
        self.assertEqual(self.report['Warnings'], [])
        self.assertEqual(self.report['UnusedCleared'], [])


if __name__ == '__main__':
    unittest.main()
