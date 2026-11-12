"""Remote hardware helper: argument validation and status parsing, without SSH or a build."""

import argparse
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
            patch("subprocess.run") as run,
        ):
            remote_hardware.listen(None)
            self.assertEqual(run.call_args.args[0], ["/bin/XTouchRemoteMIDI", "listen"])
            remote_hardware.listen("mini")
            command = run.call_args.args[0]
            self.assertEqual(command[0], "ssh")
            self.assertIn("BatchMode=yes", command)
            self.assertEqual(command[command.index("--") + 1 :], ["mini", ".xtouch-remote/XTouchRemoteMIDI", "listen"])

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
