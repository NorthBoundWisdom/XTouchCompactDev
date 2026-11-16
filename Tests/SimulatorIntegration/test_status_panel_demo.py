"""Run the packaged display-only demo against real simulation and scripted-hardware hosts."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

from configs.measure_display_budget import FakeHost
from configs.package_surface_simulator import SDK_ZIP, stage_shared_files
from test_http_simulator import ROOT
from test_scoped_credentials import ScopedHost, credentials


class StatusPanelDemoTests(unittest.TestCase):
    def run_demo(self, hardware=False, stop=None):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            package = directory / 'package'
            package.mkdir()
            stage_shared_files(package)
            archive = package / SDK_ZIP
            with zipfile.ZipFile(archive) as sdk:
                self.assertIn('surface_panel_demo/reference_actual.json', sdk.namelist())
                self.assertIn('surface_panel_demo/mappings/compact.json', sdk.namelist())
            if hardware:
                binary = Path(os.environ.get('XTOUCH_HARDWARE_BINARY', ROOT / '.build/debug/XTouchSurfaceHardware')).resolve()
                host = FakeHost(binary, directory / 'host', configured=True)
                instance = 'display.budget'
                before = host.rpc('operator', 'snapshot', {'instance_id': instance})['structuredContent']
                expected = host.expected
            else:
                host_directory = directory / 'host'
                host_directory.mkdir()
                host = ScopedHost(host_directory, credentials(), extra=('--write-limits', 'input=60,feedback=300,renew=60,admin=10'))
                instance = 'scoped.test'
                before = host.clients['operator'].snapshot()
                expected = host.clients['display'].expected
            process = None
            try:
                read_fd, write_fd = os.pipe()
                os.write(write_fd, host.tokens['display'].encode())
                os.close(write_fd)
                command = [sys.executable, '-B', '-m', 'surface_panel_demo', '--url', host.ready['url'],
                           '--instance-id', instance, '--token-fd', str(read_fd), '--mapping', 'compact',
                           '--source', 'hardware' if hardware else 'simulation', '--hz', '5',
                           '--duration', '5' if stop == 'signal' else '0.4']
                if stop == 'stale':
                    command += ['--source-stops-after', '0.05', '--max-age', '0.1', '--duration', '2']
                env = {**os.environ, 'PYTHONPATH': str(archive)}
                process = subprocess.Popen(command, pass_fds=(read_fd,), cwd=directory, env=env,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                os.close(read_fd)
                if stop == 'signal':
                    deadline = time.monotonic() + 5
                    while True:
                        snapshot = (host.rpc('operator', 'snapshot', {'instance_id': instance})['structuredContent']
                                    if hardware else host.clients['operator'].snapshot())
                        if snapshot['feedback'].get('a.button.8', {}).get('indicator') == 'on':
                            break
                        if time.monotonic() >= deadline or process.poll() is not None:
                            self.fail('Demo never established fresh display state')
                        time.sleep(.01)
                    process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=8)
                report = json.loads(stdout)
                self.assertEqual(process.returncode, 1 if stop == 'stale' else 0, stderr)
                self.assertEqual(report['reason'], {'signal': 'interrupted', 'stale': 'source_stale'}.get(stop, 'complete'))
                self.assertEqual(report['cleanup_failed'], 0)
                self.assertGreater(report['cleanup_attempted'], 0)
                self.assertGreater(report['frames'], 0)
                self.assertFalse(any(token in stdout + stderr for token in host.tokens.values()))
                after = (host.rpc('operator', 'snapshot', {'instance_id': instance})['structuredContent']
                         if hardware else host.clients['operator'].snapshot())
                self.assertEqual(after['discovery']['expected'], expected)
                self.assertEqual(before['inputs'], after['inputs'])
                self.assertEqual(before.get('holds'), after.get('holds'))
                self.assertEqual(after['feedback']['a.button.8']['indicator'], 'off')
                for control, channels in after['feedback'].items():
                    self.assertNotIn('.fader.', control)
                    for kind, value in channels.items():
                        self.assertEqual(value, 0 if kind == 'value' else 'off')
                args = {'instance_id': instance, 'epoch': expected['epoch'],
                        'after_sequence': before['discovery']['latest_sequence'], 'limit': 1024}
                page = (host.rpc('operator', 'events', args)['structuredContent'] if hardware else
                        host.call('operator', 'surface_control_events', args)['structuredContent'])
                self.assertTrue(page['events'])
                self.assertTrue(all(event['kind'] == 'feedback' for event in page['events']))
                self.assertEqual(len({event['writer_id'] for event in page['events']}), 1)
                if hardware:
                    receipts = [json.loads(line) for line in host.receipts.read_text().splitlines()]
                    self.assertTrue(receipts)
                    self.assertTrue(all(row['kind'] in ('style', 'value', 'indicator') for row in receipts))
                    words = [int(row['word'], 16) for row in receipts]
                    self.assertTrue(all(((word >> 16) & 0xF0) in (0x90, 0xB0) and
                                        not (((word >> 16) & 0xF0) == 0xB0 and 1 <= ((word >> 8) & 127) <= 9)
                                        for word in words))
                events = page['events']
                fresh_off = [index for index, event in enumerate(events)
                             if event['control_id'] == 'a.button.8' and event['value'] == 'off'][-1]
                rest_values = [index for index, event in enumerate(events)
                               if event['encoding'] == 'value' and event['value'] == 0]
                self.assertTrue(rest_values)
                self.assertTrue(all(index > fresh_off for index in rest_values))
                print('status-panel-demo-result ' + json.dumps({
                    'source': 'test-only-hardware' if hardware else 'simulation', 'stop': stop,
                    'report': report, 'journal_feedback_events': len(events),
                    'inputs_unchanged': before['inputs'] == after['inputs'],
                    'fresh_indicator_final': after['feedback']['a.button.8']['indicator'],
                    'fake_messages': len(receipts) if hardware else None,
                }, sort_keys=True))
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=5)
                host.close()

    def test_zip_demo_normal_completion_only_changes_display_and_clears_it(self):
        self.run_demo()

    def test_zip_demo_sigint_clears_freshness_and_every_attempted_display(self):
        self.run_demo(stop='signal')

    def test_zip_demo_stale_source_exits_nonzero_after_clearing_displays(self):
        self.run_demo(stop='stale')

    @unittest.skipUnless(sys.platform == 'darwin', 'hardware service is macOS only')
    def test_zip_demo_works_with_scripted_hardware_without_input_or_motion(self):
        self.run_demo(hardware=True)
