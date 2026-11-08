"""Version sites in the core and in the external main view stay one release."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

DEV=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(DEV/'tools'))
import release_contract as release

class StampingTests(unittest.TestCase):
    def test_external_view_stamped_without_bom_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            core=root/'Domenia-Core.ps1';view=root/'Domenia-Main.xaml';runtime=root/'Domenia.release.json'
            core.write_bytes((DEV/'wad/Domenia-Core.ps1').read_bytes())
            view.write_bytes((DEV/'wad/Domenia-Main.xaml').read_bytes())
            contract=dict(release.load_contract(), Version='1.0', Release='RC1.99.0')
            with patch.object(release,'CORE',core),patch.object(release,'RUNTIME_FILE',runtime):
                release.stamp(contract)
            self.assertIn('DOMENIA 1.0 · RC1.99.0',view.read_text())
            self.assertTrue(core.read_bytes().startswith(b'\xef\xbb\xbf'))
            self.assertFalse(view.read_bytes().startswith(b'\xef\xbb\xbf'))

    def test_missing_or_duplicate_footer_does_not_stamp_core(self):
        for content in ['', (DEV/'wad/Domenia-Main.xaml').read_text()*2]:
            with self.subTest(duplicate=bool(content)),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);core=root/'Domenia-Core.ps1';runtime=root/'Domenia.release.json'
                original=(DEV/'wad/Domenia-Core.ps1').read_bytes();core.write_bytes(original)
                (root/'Domenia-Main.xaml').write_text(content)
                with patch.object(release,'CORE',core),patch.object(release,'RUNTIME_FILE',runtime):
                    with self.assertRaises(ValueError):release.stamp(release.load_contract())
                self.assertEqual(original,core.read_bytes());self.assertFalse(runtime.exists())
