"""A targeted parity update must not replay stale statuses from another lot."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

V2 = Path(__file__).resolve().parents[2]
SCRIPT = V2 / 'docs/reprise/apply_status.py'


class TargetedStatusTests(unittest.TestCase):
    def prepare(self, root):
        docs = root / 'v2/docs'
        (docs / 'status').mkdir(parents=True)
        for name in ('features.json', 'FEATURES.md'):
            shutil.copyfile(V2 / 'docs' / name, docs / name)
        return docs

    def run_update(self, root, *ids):
        return subprocess.run([sys.executable, '-I', str(SCRIPT), str(root), '--only', *ids],
                              capture_output=True, text=True, check=False)

    def test_targeted_update_preserves_unrelated_statuses_notes_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = self.prepare(root)
            before = json.loads((docs / 'features.json').read_text(encoding='utf-8'))
            old_md = (docs / 'FEATURES.md').read_text(encoding='utf-8')
            target = next(f for f in before if f['id'] == 'TRV-111')
            status = 'fait' if target['status'] != 'fait' else 'ameliore'
            (docs / 'status/accueil.json').write_text(json.dumps({status: ['TRV-111']}), encoding='utf-8')
            (docs / 'status/parametres.json').write_text(json.dumps({'partiel': [
                {'id': 'PAR-005', 'reste': 'Ancienne déclaration sans rapport avec ce lot.'}]}), encoding='utf-8')
            result = self.run_update(root, 'TRV-111')
            self.assertEqual(0, result.returncode, result.stderr)
            expected = [dict(f, status=status) if f['id'] == 'TRV-111' else f for f in before]
            self.assertEqual(expected, json.loads((docs / 'features.json').read_text(encoding='utf-8')))
            new_md = (docs / 'FEATURES.md').read_text(encoding='utf-8')
            for fid in ('PAR-005', 'PAR-046', 'TRV-190'):
                pattern = rf'^#### {fid} · .*?(?=^#### |\Z)'
                self.assertEqual(re.search(pattern, old_md, re.M | re.S).group(),
                                 re.search(pattern, new_md, re.M | re.S).group())
            self.assertRegex(new_md, rf'(?s)#### TRV-111 · .*?`{status}` · ')
            counts = [sum(f['status'] == s for f in expected)
                      for s in ('fait', 'ameliore', 'partiel', 'a-faire', 'abandonne')]
            self.assertIn('| **Total** | | **' + str(len(expected)) + '** | '
                          + ' | '.join('**' + str(n) + '**' for n in counts) + ' |', new_md)
            snapshots = {n: (docs / n).read_bytes() for n in ('features.json', 'FEATURES.md')}
            self.assertEqual(0, self.run_update(root, 'TRV-111').returncode)
            self.assertEqual(snapshots, {n: (docs / n).read_bytes() for n in snapshots})

    def test_unknown_target_refuses_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = self.prepare(root)
            before = {n: (docs / n).read_bytes() for n in ('features.json', 'FEATURES.md')}
            self.assertNotEqual(0, self.run_update(root, 'TRV-999').returncode)
            self.assertEqual(before, {n: (docs / n).read_bytes() for n in before})


if __name__ == '__main__':
    unittest.main()
