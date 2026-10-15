"""P-CD-07: the declarative operation table (Get-DomeniaOperationTable) and the worker contract name the same operations.

Offline: reads wad/modules/Domenia-Engine.Model.ps1 and tools/operation-contracts.json, never runs PowerShell.
The answers of the rules that read the table are compared with the former lists by tests/rules/Engine.Tests.ps1.
Usage: python3 -m unittest discover -s tools/tests -q   (from dev/)
"""
from pathlib import Path
import json
import sys
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
sys.path.insert(0, str(DEV / 'wad/tests'))
import update_worker_contracts as contracts  # noqa: E402


class OperationTableTest(unittest.TestCase):
    def setUp(self):
        self.items = json.loads((DEV / 'tools/operation-contracts.json').read_text(encoding='utf-8'))

    def test_one_pinned_line_per_contract_operation_and_back(self):
        self.assertEqual([], contracts.operation_table_problems(self.items))

    def test_a_new_pinned_operation_without_its_line_is_reported(self):
        items = self.items + [dict(self.items[0], Operation='StorageRetention')]
        self.assertIn('Operation epinglee sans ligne Pinned : StorageRetention', contracts.operation_table_problems(items))

    def test_a_withdrawn_operation_keeping_its_pinned_line_is_reported(self):
        items = [item for item in self.items if item['Operation'] != 'ParkPing']
        self.assertIn('Ligne Pinned sans operation epinglee : ParkPing', contracts.operation_table_problems(items))


if __name__ == '__main__':
    unittest.main()
