"""Critical rejection checks for the release gate, using synthetic local fixtures only.

Reserved for the final Windows validation phase. No test in this file is a native/UI
acceptance record and no synthetic result may be included in a release evidence folder.
"""
import importlib.util
import os
from pathlib import Path
import struct
import unittest
import zlib

spec = importlib.util.spec_from_file_location("domenia_release_guard", Path(__file__).resolve().parents[2] / "tools" / "release-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ReleaseGuardCriticalTests(unittest.TestCase):
    def test_duplicate_json_keys_are_refused(self):
        with self.assertRaises(guard.Refused):
            guard.parse_json(b'{"sourceCommit":"a","sourceCommit":"b"}')

    def test_paths_cannot_escape_or_alias_windows_files(self):
        for name in ("../outside.json", "/absolute.json", "raw/CON.txt", "raw/name. ", "raw\\file", "raw/file:stream", "raw//file"):
            with self.subTest(name=name), self.assertRaises(guard.Refused):
                guard.relative_name(name)

    def test_empty_or_full_csharp_suite_does_not_satisfy_critical_selection(self):
        for log in (b"", "Sélection : complète ; 1/1 tests retenus, 0 non exécutés.\nOK    OneTests.Check\n1 réussis, 0 en échec, 1 au total.\n".encode()):
            with self.assertRaises(guard.Refused):
                guard.check_csharp(log, {"OneTests"})

    def test_missing_critical_class_is_not_hidden_by_a_green_summary(self):
        log = "Sélection : critique ciblée ; 1/2 tests retenus, 1 non exécutés.\nOK    OneTests.Check\n1 réussis, 0 en échec, 1 au total.\n".encode()
        with self.assertRaises(guard.Refused):
            guard.check_csharp(log, {"OneTests", "TwoTests"})

    def test_csharp_counts_must_match_unique_results(self):
        log = "Sélection : critique ciblée ; 2/2 tests retenus, 0 non exécutés.\nOK    OneTests.Check\nOK    OneTests.Check\n2 réussis, 0 en échec, 2 au total.\n".encode()
        with self.assertRaises(guard.Refused):
            guard.check_csharp(log, {"OneTests"})

    def test_actual_critical_log_shape_is_accepted(self):
        guard.check_csharp("Sélection : critique ciblée ; 2/3 tests retenus, 1 non exécutés.\nOK    OneTests.First\nOK    TwoTests.Second\n2 réussis, 0 en échec, 2 au total.\n".encode(), {"OneTests", "TwoTests"})

    def test_windows_line_endings_do_not_invalidate_a_complete_critical_log(self):
        guard.check_csharp("Sélection : critique ciblée ; 1/1 tests retenus, 0 non exécutés.\r\nOK    OneTests.First\r\n1 réussis, 0 en échec, 1 au total.\r\n".encode(), {"OneTests"})

    def test_ui_screenshots_must_be_frozen_in_the_snapshot(self):
        with self.assertRaises(guard.Refused):
            guard.check_ui(None, [{}, {}], [], "VM", "C:\\PROD\\Domenia.exe")

    def test_web_summary_does_not_replace_per_test_results(self):
        with self.assertRaises(guard.Refused):
            guard.check_web({"status": "passed", "error": "", "report": {"selection": "critical-only", "passed": 1, "failed": 0, "results": []}})

    def test_web_boolean_count_does_not_masquerade_as_an_integer(self):
        with self.assertRaises(guard.Refused):
            guard.check_web({"status": "passed", "error": "", "report": {"selection": "critical-only", "passed": True, "failed": False, "results": [{"name": "fixture", "passed": True}]}})

    def test_web_requires_the_explicit_critical_marker(self):
        with self.assertRaises(guard.Refused):
            guard.check_web({"status": "passed", "error": "", "report": {"passed": 1, "failed": 0, "results": [{"name": "fixture", "passed": True}]}})

    def test_native_protocol_completion_alone_is_not_acceptance(self):
        raw = b'{"sequence":1,"operation":"manifest","value":{}}\n{"sequence":2,"operation":"finished","value":{"state":"ProtocolCompleted","errors":0}}\n'
        with self.assertRaises(guard.Refused):
            guard.check_native(raw, "VM", "a" * 40, "b" * 64)

    def test_torn_native_tail_is_never_repaired(self):
        with self.assertRaises(guard.Refused):
            guard.check_native(b'{"sequence":1', "VM", "a" * 40, "b" * 64)

    def test_png_must_have_checked_chunks_and_a_terminal_marker(self):
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
        raw = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        raw += chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b"")
        guard.png(raw)
        for invalid in (raw[:-1], raw[:33], raw[:40] + bytes([raw[40] ^ 1]) + raw[41:]):
            with self.assertRaises(guard.Refused):
                guard.png(invalid)

    def test_archive_inventory_rejects_case_alias_and_negative_length(self):
        for entries in ([{"path": "File.txt", "length": 0, "sha256": "a" * 64}, {"path": "file.txt", "length": 0, "sha256": "a" * 64}], [{"path": "file", "length": -1, "sha256": "a" * 64}]):
            with self.assertRaises(guard.Refused):
                guard.inventory(entries)


if __name__ == "__main__":
    if os.name != "nt":
        raise SystemExit("Tests critiques réservés à Windows, en phase finale ; aucune suite exécutée ici.")
    unittest.main()
