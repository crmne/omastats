#!/usr/bin/env python3
"""Verify target selection without signalling desktop processes."""

from contextlib import contextmanager, ExitStack
import json
from pathlib import Path
import re
import runpy
import signal
import tempfile
import time
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parent.parent
HELPER = runpy.run_path(str(ROOT / "process-actions.py"))
NAMESPACE = HELPER["main"].__globals__
STAT = HELPER["ProcStat"]
TARGET = HELPER["Target"]


def deadline():
    return time.monotonic() + 5


class ProcessActionsTests(unittest.TestCase):
    def test_process_name_with_parentheses_and_spaces(self):
        fields = ["S", "7", *(["0"] * 17), "12345", "0", "3"]
        with patch.dict(NAMESPACE, {"read_proc": lambda *args: ("42 (name) (x) " + " ".join(fields)).encode()}):
            stat = HELPER["proc_stat"](42)
        self.assertEqual(stat, STAT("name) (x", "S", 7, 12345, 3 * HELPER["PAGE_SIZE"]))

    def test_fallback_group_name_matches_native_byte_prefix(self):
        resolver = HELPER["display_name"]
        name = "éèêëeditor"
        with patch.dict(resolver.__globals__, {"read_text": lambda path: f"/usr/bin/{name}\0"}):
            self.assertEqual(resolver(42, "éèêëeditors"), name)

    def test_only_explicit_unique_identities_are_accepted(self):
        parse = HELPER["parse_targets"]
        self.assertEqual(parse('[[42,"123"],[43,"124","000AF"],[43,"124","b0"]]'),
                         [TARGET(43, 124, "af"), TARGET(43, 124, "b0"), TARGET(42, 123)])
        for data in ('[]', '[[1,"123"]]', '[[true,"123"]]', '[[42,123]]', '[[42,"123","1;kill"]]',
                     '[[42,"123"],[42,"123"]]', '[[42,"123"],[42,"123","ab"]]',
                     '[[42,"123","aa"],[42,"124","bb"]]'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                parse(data)

    def test_clients_with_no_close_selector_still_block_signals(self):
        records = [{"pid": 2, "mapped": True, "stableId": "A1", "title": "Title\nline"},
                   {"pid": 3, "mapped": False, "stableId": "a2"},
                   {"pid": 4, "mapped": True, "address": "0x123"}]
        read = Mock(return_value=json.dumps(records))
        end = deadline()
        with patch.dict(NAMESPACE, {"hyprctl": read}):
            self.assertEqual(HELPER["clients"](end), {2: [{"id": "a1", "title": "Title line"}], 3: [], 4: []})
        read.assert_called_once_with(["-j", "-a", "clients"], end)

    def test_invalid_or_ambiguous_window_lists_are_unavailable(self):
        first = {"pid": 4, "mapped": True, "stableId": "aa"}
        second = {"pid": 5, "mapped": True, "stableId": "00AA"}
        for data in ({}, [{"pid": "4"}], [first, second]):
            with self.subTest(data=data), patch.dict(NAMESPACE, {"hyprctl": lambda *args: json.dumps(data)}):
                with self.assertRaises(HELPER["Unavailable"]):
                    HELPER["clients"](deadline())

    def test_proc_listing_is_bounded_and_handles_missing_compositor(self):
        unavailable = Mock(side_effect=HELPER["Unavailable"])
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            for pid in range(10, 14):
                (proc / str(pid)).mkdir()
            with patch.dict(NAMESPACE, {
                "PROC": proc,
                "MAX_MEMBERS": 2,
                "ancestors": lambda: set(),
                "clients": unavailable,
                "proc_stat": lambda pid: STAT("editor" if pid < 13 else "other", "S", 1, pid, pid),
                "can_act": lambda *args: True,
            }):
                listed = HELPER["list_group"]("editor", deadline())
        self.assertTrue(listed["truncated"])
        self.assertFalse(listed["windowsAvailable"])
        self.assertEqual(len(listed["members"]), 2)
        self.assertTrue(all(not item["canTerminate"] and not item["windows"] for item in listed["members"]))

    def test_process_credentials_and_protected_executables(self):
        can_act = HELPER["can_act"]
        with patch("os.getuid", return_value=1000), patch("os.geteuid", return_value=1000), \
             patch("os.readlink", return_value="/usr/bin/editor"):
            with patch.dict(NAMESPACE, {"read_proc": lambda *args: b"Uid:\t1000\t1000\t1000\t1000\n"}):
                self.assertTrue(can_act(42, set()))
                self.assertFalse(can_act(42, {42}))
                for executable in ("Hyprland", "Xwayland"):
                    with patch("os.readlink", return_value=f"/usr/bin/{executable}"):
                        self.assertFalse(can_act(42, set()))
            with patch.dict(NAMESPACE, {"read_proc": lambda *args: b"Uid:\t1000\t0\t0\t1000\n"}):
                self.assertFalse(can_act(42, set()))

    def test_window_close_matches_pid_and_stable_id(self):
        windows = {4: [{"id": "abc", "title": "Editor"}], 5: [{"id": "def", "title": "Other"}]}
        send = Mock(return_value="ok\n")
        with self.mock_targets(clients=Mock(return_value=windows), hyprctl=send):
            result = HELPER["apply"]("editor", [TARGET(4, 100, "abc"), TARGET(4, 100, "def")], deadline())
        self.assertEqual(result, {"status": "sent", "sent": 1, "skipped": 1})
        self.assertEqual(send.call_count, 1)
        self.assertEqual(send.call_args.args[0], ["dispatch", 'hl.dsp.window.close({ window = "stableid:abc" })'])

    def test_background_targets_recheck_windows_and_pid_identity(self):
        client_list = Mock(side_effect=[{}, {5: []}])
        with self.mock_targets(clients=client_list), patch("signal.pidfd_send_signal") as send:
            result = HELPER["apply"]("editor", [TARGET(4, 100), TARGET(5, 100), TARGET(6, 99)], deadline())
        self.assertEqual(result, {"status": "sent", "sent": 1, "skipped": 2})
        self.assertEqual(client_list.call_count, 2)
        send.assert_called_once_with(4, signal.SIGTERM)

    def test_background_targets_skip_when_compositor_is_unavailable(self):
        with self.mock_targets(clients=Mock(side_effect=HELPER["Unavailable"])), patch("signal.pidfd_send_signal") as send:
            result = HELPER["apply"]("editor", [TARGET(4, 100)], deadline())
        self.assertEqual(result, {"status": "skipped", "sent": 0, "skipped": 1})
        send.assert_not_called()

    def test_background_target_skips_pidfd_for_exited_process(self):
        with self.mock_targets(clients=Mock(return_value={})), patch("signal.pidfd_send_signal") as send, \
             patch("select.poll", return_value=Mock(poll=Mock(return_value=[(4, 1)]))):
            result = HELPER["apply"]("editor", [TARGET(4, 100)], deadline())
        self.assertEqual(result, {"status": "skipped", "sent": 0, "skipped": 1})
        send.assert_not_called()

    @contextmanager
    def mock_targets(self, **overrides):
        with ExitStack() as stack:
            stack.enter_context(patch("os.pidfd_open", side_effect=lambda pid: pid))
            stack.enter_context(patch("os.close"))
            stack.enter_context(patch("select.poll", return_value=Mock(poll=Mock(return_value=[]))))
            stack.enter_context(patch.dict(NAMESPACE, {
                "ancestors": lambda: set(), "can_act": lambda *args: True,
                "proc_stat": lambda pid: STAT("editor", "S", 1, 100, 0), **overrides,
            }))
            yield

    def test_catalogs_share_keys_and_placeholders(self):
        catalogs = [json.loads((ROOT / "i18n" / f"{language}.json").read_text()) for language in ("en", "ru")]
        self.assertEqual(catalogs[0].keys(), catalogs[1].keys())
        for key, english in catalogs[0].items():
            russian = catalogs[1][key]
            if isinstance(english, dict):
                self.assertEqual(russian.keys(), {"one", "few", "many", "other"})
                expected = re.findall(r"%\d", english["other"])
                for value in russian.values():
                    self.assertEqual(re.findall(r"%\d", value), expected, key)
            else:
                self.assertEqual(re.findall(r"%\d", russian), re.findall(r"%\d", english), key)


if __name__ == "__main__":
    unittest.main()
