"""CD-13 / CO-33 / CO-34: the worker copies of the LDAP text rules match their pure source.

Offline check: reads wad/Domenia-Core.ps1 and wad/modules/Domenia-Search.Model.ps1, never runs PowerShell.
Usage: python3 -m unittest discover -s tools/tests -q   (from dev/)
"""
from pathlib import Path
import re
import sys
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
sys.path.insert(0, str(DEV / 'wad/tests'))
import sync_worker_ldap_rules as sync  # noqa: E402
from powershell_lex import functions  # noqa: E402


class WorkerLdapRulesTest(unittest.TestCase):
    def setUp(self):
        raw = (DEV / 'wad/Domenia-Core.ps1').read_bytes()
        self.core = raw[3:].decode('utf-8')
        self.common = re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@", self.core).group(1)

    def test_generated_block_matches_the_model(self):
        _pattern, block = sync.current(self.core)
        self.assertEqual(sync.render(), block, 'Relancer tools/sync_worker_ldap_rules.py --apply apres relecture.')

    def test_each_worker_rule_is_defined_once_in_the_common_text(self):
        defined = functions(self.common)
        for _source, target in sync.RULES:
            self.assertEqual(1, len(defined.get(target, [])), target)

    def test_copies_call_no_interface_module(self):
        _pattern, block = sync.current(self.core)
        self.assertIsNone(re.search(r'(?<![\w-])[A-Za-z]+-Domenia[A-Za-z0-9]+', block))

    def test_ldap_path_of_the_workers_escapes_the_slash(self):
        body = sync.source_function(self.common, 'Get-WLdapPath')
        self.assertIn('ConvertTo-WAdsPathDn', body)

    def test_interface_escape_delegates_to_the_model(self):
        body = sync.source_function(self.core, 'Escape-LdapValue')
        self.assertIn('ConvertTo-DomeniaLdapLiteral', body)
        body = sync.source_function(self.core, 'Get-LdapPath')
        self.assertIn('ConvertTo-DomeniaAdsPathDn', body)


if __name__ == '__main__':
    unittest.main()
