"""Written for Windows qualification; source fixtures only, no product execution."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('operation_contracts', Path(__file__).resolve().parents[2] / 'tools/update-operation-contracts.py')
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


class OperationContractSourceTests(unittest.TestCase):
    def test_added_removed_changed_sources_and_project_inclusions_change_pins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for project in contracts.PROJECTS:
                directory = root / 'src' / project
                directory.mkdir(parents=True)
                (directory / 'Body.cs').write_text('// reviewed body', encoding='utf-8')
                (directory / (project + '.csproj')).write_text('<Project />', encoding='utf-8')
            for name in ('Directory.Build.props', 'global.json', 'NuGet.config'):
                (root / name).write_text('reviewed configuration', encoding='utf-8')
            first = contracts.make(root)
            self.assertIn(b'DomeniaCurrentSource', first[1])
            self.assertIn(b'Count()', first[1])
            extra = root / 'src/Domenia.Core/Added.cs'
            extra.write_text('// new partial body', encoding='utf-8')
            self.assertNotEqual(first, contracts.make(root))
            extra.unlink()
            self.assertEqual(first, contracts.make(root))
            body = root / 'src/Domenia.Core/Body.cs'
            body.write_text('// changed body', encoding='utf-8')
            self.assertNotEqual(first, contracts.make(root))
            body.write_text('// reviewed body', encoding='utf-8')
            project = root / 'src/Domenia.Core/Domenia.Core.csproj'
            project.write_text('<Project><Import Project="external.props" /></Project>', encoding='utf-8')
            self.assertNotEqual(first, contracts.make(root))
            project.write_text('<Project />', encoding='utf-8')
            body.unlink()
            self.assertNotEqual(first, contracts.make(root))


if __name__ == '__main__':
    unittest.main()
