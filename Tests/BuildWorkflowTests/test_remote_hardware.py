"""Remote hardware helper: argument validation and status parsing, without SSH or a build."""

import argparse
import signal
import subprocess
import unittest
from unittest.mock import patch

from tools import remote_hardware


class RemoteHardwareTests(unittest.TestCase):
    def test_hosts_reject_option_and_shell_text(self):
        for good in ["henrys-mac-mini", "100.99.104.81", "henrykang@henrys-mac-mini", "fd7a:115c::1"]:
            self.assertEqual(remote_hardware.validated_host(good), good)
        for bad in ["", "-oProxyCommand=x", "a b", "a;b", "$(id)", ".x", "@h", "a@b@c"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                remote_hardware.validated_host(bad)

    def test_status_script_interpolates_no_user_text(self):
        self.assertNotIn("{", remote_hardware._STATUS_SCRIPT)
        self.assertIn(".xtouch-remote/XTouchRemoteMIDI", remote_hardware._STATUS_SCRIPT)

    def test_parse_status_with_visible_controller_and_bridge(self):
        state = remote_hardware.parse_status(
            "sha256 abc123\nbridges 4012 4013 \n--devices\nsources:\n  X-TOUCH COMPACT  [controller]\n"
            "  IAC Bus 1\ndestinations:\n  X-TOUCH COMPACT  [controller]\n"
        )
        self.assertEqual(state["remote_sha256"], "abc123")
        self.assertEqual(state["bridges"], ["4012", "4013"])
        self.assertTrue(state["controller"])
        self.assertEqual(len(state["devices"]), 3)

    def test_parse_status_offline_controller_is_not_visible(self):
        state = remote_hardware.parse_status(
            "sha256 abc\nbridges \n--devices\nsources:\n  X-TOUCH COMPACT  [controller, offline]\n"
        )
        self.assertFalse(state["controller"])
        self.assertEqual(state["bridges"], [])

    def test_parse_status_missing_binary_leaves_controller_unknown(self):
        state = remote_hardware.parse_status("sha256 missing\nbridges \n")
        self.assertIsNone(state["remote_sha256"])
        self.assertIsNone(state["controller"])

    def test_listen_runs_locally_without_ssh_and_remotely_with_it(self):
        with (
            patch.object(remote_hardware, "build", return_value="/bin/XTouchRemoteMIDI"),
            patch("subprocess.Popen") as popen,
        ):
            popen.return_value.poll.return_value = 0
            remote_hardware.listen(None)
            self.assertEqual(popen.call_args.args[0], ["/bin/XTouchRemoteMIDI", "listen"])
            remote_hardware.listen("mini")
            command = popen.call_args.args[0]
            self.assertEqual(command[0], "ssh")
            self.assertIn("BatchMode=yes", command)
            self.assertEqual(command[command.index("--") + 1 :], ["mini", ".xtouch-remote/XTouchRemoteMIDI", "listen"])

    def test_timed_listen_interrupts_the_listener_when_time_is_up(self):
        with patch.object(remote_hardware, "build", return_value="/bin/X"), patch("subprocess.Popen") as popen:
            process = popen.return_value
            process.wait.side_effect = [subprocess.TimeoutExpired("x", 3), 0]
            process.poll.return_value = None
            remote_hardware.listen(None, 3)
            self.assertEqual(process.wait.call_args_list[0].kwargs, {"timeout": 3})
            process.send_signal.assert_called_once_with(signal.SIGINT)
            process.kill.assert_not_called()

    def test_listen_rejects_a_non_positive_duration(self):
        with patch("sys.argv", ["remote_hardware.py", "listen", "--seconds", "0"]), self.assertRaises(SystemExit):
            remote_hardware.main()

    def test_connect_passes_listen_only_through(self):
        with patch.object(remote_hardware, "build", return_value="/bin/X"), patch("subprocess.run") as run:
            remote_hardware.connect("mini", None)
            self.assertEqual(run.call_args.args[0], ["/bin/X", "client", "--ssh", "mini"])
            remote_hardware.connect("mini", "lab", listen_only=True)
            self.assertEqual(
                run.call_args.args[0], ["/bin/X", "client", "--ssh", "mini", "--listen-only", "--label", "lab"]
            )

    def test_decode_word_follows_the_factory_tx_table(self):
        decode = remote_hardware.decode_word
        self.assertEqual(decode(0x20B00140), ("a", "fader 1", 1, 0x40))
        self.assertEqual(decode(0x20B21C08), ("b", "fader 1", 3, 8))
        self.assertEqual(decode(0x20B0657F), ("a", "touch 1", 1, 127))
        self.assertEqual(decode(0x20B07700), ("b", "touch 9", 1, 0))
        self.assertEqual(decode(0x20B01A05), ("a", "expression", 1, 5))
        self.assertEqual(decode(0x20B0407F), ("b", "footswitch", 1, 127))
        self.assertEqual(decode(0x2090107F), ("a", "button 1", 1, 127))
        self.assertEqual(decode(0x2080107F), ("a", "button 1", 1, 0))  # Note Off reads as release.
        self.assertEqual(decode(0x20906D7F), ("b", "button 39", 1, 127))
        self.assertEqual(decode(0x2090377F), ("b", "push 1", 1, 127))
        for word in (0x20B07F01, 0x20C00001, 0x20906E7F, 0x30160000, 0x10F80000):
            self.assertIsNone(decode(word))

    def test_summarize_capture_aggregates_and_never_guesses(self):
        lines = [
            '{"event":"listening","t":0.1}',
            '{"event":"midi","t":1.0,"words":["20B00100","20B0017F","20B0657F"]}',
            '{"event":"midi","t":1.5,"words":["20B00140","20C00001","zz"]}',
            "not json",
            "",
        ]
        summary = remote_hardware.summarize_capture(lines)
        self.assertEqual(summary["messages"], 6)
        self.assertEqual(summary["malformed"], 1)
        self.assertEqual(summary["undecoded"], ["20C00001", "zz"])
        fader = summary["controls"][("a", "fader 1")]
        self.assertEqual((fader["count"], fader["min"], fader["max"], fader["channels"]), (3, 0, 127, {1}))
        self.assertEqual(summary["events"], [(0.1, "listening")])

    def test_only_listen_may_omit_the_host(self):
        with patch("sys.argv", ["remote_hardware.py", "status"]), self.assertRaises(SystemExit):
            remote_hardware.main()

    def test_local_clients_ignores_non_pid_lines(self):
        listing = "123 XTouchRemoteMIDI client --ssh mini\nnoise\n"
        with patch("subprocess.run") as run:
            run.return_value.stdout = listing
            self.assertEqual(remote_hardware.local_clients("mini"), ["123"])


if __name__ == "__main__":
    unittest.main()
