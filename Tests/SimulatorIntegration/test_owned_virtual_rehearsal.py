"""Actual CoreMIDI owned references only; never enumerate or connect a physical endpoint."""
import json
import hashlib
import os
from pathlib import Path
import secrets
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from test_hardware_service import BINARY
from surface_control import Client, SurfaceError


class RunningOwned:
    def __init__(self, directory, feedback=True, extra=()):
        self.directory = Path(directory)
        self.token = secrets.token_hex(32)
        self.rows = []
        self.commands = []
        self.exported = False
        self.raw_log = []
        self.lock = threading.Lock()
        self.ready_path = self.directory / 'owned-ready.json'
        read_fd, self.writer = os.pipe()
        args = [str(BINARY), '--owned-virtual-rehearsal', '--owned-virtual-steps-fd', str(read_fd),
                '--receive-channel', '1', '--light-protocol', 'observed114', '--token-stdin',
                '--surface-instance-id', 'owned.test', '--ready-file', str(self.ready_path), *extra]
        if feedback:
            args.append('--allow-surface-feedback')
        env = {key: value for key, value in os.environ.items() if not key.startswith('XTOUCH_HARDWARE_TEST_')}
        self.argv = args
        self.process = subprocess.Popen(args, pass_fds=(read_fd,), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, cwd=directory, env=env)
        os.close(read_fd)
        self.process.stdin.write(self.token + '\n')
        self.process.stdin.close()
        self.reader = threading.Thread(target=self.read_log, daemon=True)
        self.reader.start()
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(5):
                self.close()
                raise AssertionError('Owned ready deadline failed')
            line = self.process.stdout.readline()
        if not line:
            self.close()
            raise AssertionError('Owned startup failed: ' + ''.join(self.raw_log))
        self.ready = json.loads(line)
        self.client = Client(self.ready['url'], self.token, 'owned.test', accepted_sources=('hardware',))
        self.discover()

    def read_log(self):
        for line in self.process.stderr:
            with self.lock:
                self.raw_log.append(line)
                if len(self.raw_log) > 20000:
                    raise AssertionError('Unbounded owned test output')
                try:
                    self.rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

    def discover(self):
        return self.client.discover(versions=('1.5',), profiles=('xtouch.compact.owned-virtual-rehearsal',), profile_versions=('1.5',))

    def step(self, operation, **fields):
        request = {'operation': operation, **fields}
        body = json.dumps(request, separators=(',', ':')).encode() + b'\n'
        written = os.write(self.writer, body)
        self.commands.append({'request': request, 'written_bytes': written, 'expected_bytes': len(body)})
        if written != len(body):
            raise AssertionError('Private step was only partly delivered')

    def records(self):
        with self.lock:
            return list(self.rows)

    def wait(self, read, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            value = read()
            if predicate(value):
                return value
            if self.process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError('Owned bounded observation failed: ' + ''.join(self.raw_log)[-2000:])
            threading.Event().wait(.005)

    def input(self, control='a.encoder.1', value=47, generation=None):
        generation = generation or self.ready['owned_endpoint_origin']['connection_generation']
        self.step('input', control_id=control, value=value, connection_generation=generation)
        return self.wait(self.client.snapshot, lambda s: s['inputs'].get(control) == value)

    def finish(self):
        self.step('finish')
        self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        return self.process.returncode

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        if self.writer is not None:
            os.close(self.writer)
            self.writer = None
        self.reader.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()
        if self.token in ''.join(self.raw_log):
            raise AssertionError('Credential escaped into owned evidence')
        evidence = os.environ.get('XTOUCH_OWNED_REPORT_ROOT')
        if evidence and not self.exported:
            target = Path(evidence)
            target.mkdir(parents=True, exist_ok=True)
            report = {'binary': str(BINARY), 'binary_sha256': hashlib.sha256(BINARY.read_bytes()).hexdigest(),
                      'argv': self.argv, 'ready': getattr(self, 'ready', None), 'private_commands': self.commands,
                      'return_code': self.process.returncode, 'records': self.records(), 'raw_stderr': self.raw_log,
                      'qualification': 'owned-virtual-rehearsal; physical_evidence=false',
                      'signal_scope': 'last visible counters; no claim Swift final counters or deinit ran'}
            body = json.dumps(report, indent=2, sort_keys=True) + '\n'
            if self.token in body:
                raise AssertionError('Credential escaped into exported owned evidence')
            with (target / ('owned-' + str(self.process.pid) + '.json')).open('x') as stream:
                stream.write(body)
            self.exported = True


@unittest.skipUnless(sys.platform == 'darwin', 'CoreMIDI owned transport is macOS-only')
class OwnedVirtualHTTPTests(unittest.TestCase):
    def test_real_owned_references_unknown_start_and_display_never_becomes_input(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningOwned(directory)
            try:
                self.assertTrue(host.ready['owned_virtual_rehearsal'])
                self.assertFalse(host.ready['physical_evidence'])
                self.assertEqual(host.ready['owned_endpoint_origin']['transport_origin'], 'localVirtual')
                initial = host.client.snapshot()
                self.assertEqual(initial['inputs'], {})
                self.assertEqual(initial['link'], {'state': 'connected'})
                with self.assertRaises(SurfaceError) as caught:
                    host.client.feedback('a.encoder.1', 'value', 5)
                self.assertEqual(caught.exception.code, 'invalid_transition')
                host.input()
                before = host.client.snapshot()
                # TX and RX deliberately use the same channel. Ring CC26 overlaps the
                # expression input address: accidental destination->input routing is visible.
                shown = host.client.feedback('a.encoder.1', 'value', 5)
                self.assertEqual(shown['kind'], 'feedback')
                receipts = host.wait(host.records, lambda rows: sum(r.get('event') == 'owned_virtual_display_receipt' for r in rows) >= 2)
                after = host.client.snapshot()
                self.assertEqual(before['inputs'], after['inputs'])
                self.assertEqual(after['inputs']['a.encoder.1'], 47)
                self.assertNotIn('a.expression.1', after['inputs'])
                sends = [r for r in receipts if r.get('event') == 'owned_virtual_send_accepted']
                self.assertEqual(len(sends), 2)
                self.assertTrue(all(r['endpoint_origin'] == host.ready['owned_endpoint_origin'] for r in sends))
                self.assertTrue(all(r['owned_virtual_rehearsal'] and not r['physical_evidence'] for r in receipts))
                for r in sends:
                    word = int(r['word'], 16)
                    self.assertIn((word >> 16) & 0xf0, (0x90, 0xb0))
                    self.assertFalse(((word >> 16) & 0xf0) == 0xb0 and 1 <= ((word >> 8) & 127) <= 9)
                counters = host.records()[-1]['device_io']
                self.assertEqual(counters['coremidi_factory_calls'], 0)
                self.assertEqual(counters['scripted_factory_calls'], 0)
                self.assertEqual(counters['source_enumeration_calls'], 0)
                self.assertEqual(counters['destination_enumeration_calls'], 0)
                self.assertEqual(counters['client_create_calls'], 1)
                self.assertEqual(host.finish(), 0)
                self.assertFalse(host.ready_path.exists())
            finally:
                host.close()

    def test_remote_input_rejects_and_private_disconnect_reconnect_does_not_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningOwned(directory)
            try:
                before = host.client.snapshot()
                with self.assertRaises(SurfaceError) as caught:
                    host.client.input('a.encoder.1', 'scalar', 50)
                self.assertEqual(caught.exception.code, 'permission_denied')
                self.assertEqual(host.client.snapshot()['inputs'], before['inputs'])
                host.input()
                old = dict(host.client.expected)
                host.step('disconnect')
                host.wait(host.records, lambda rows: any(r.get('event') == 'owned_virtual_disconnected' for r in rows))
                host.client = Client(host.ready['url'], host.token, 'owned.test', accepted_sources=('hardware',))
                host.discover()
                lost = host.client.snapshot()
                self.assertEqual(lost['link']['state'], 'disconnected')
                self.assertEqual(lost['inputs'], {})
                host.step('reconnect')
                fresh_rows = host.wait(host.records, lambda rows: sum(r.get('event') == 'owned_virtual_connected' for r in rows) == 2)
                fresh = [r for r in fresh_rows if r.get('event') == 'owned_virtual_connected'][-1]['endpoint_origin']
                self.assertNotEqual(fresh, host.ready['owned_endpoint_origin'])
                host.client = Client(host.ready['url'], host.token, 'owned.test', accepted_sources=('hardware',))
                host.discover()
                snapshot = host.client.snapshot()
                self.assertEqual(snapshot['inputs'], {})
                self.assertEqual(snapshot['feedback'], {})
                self.assertNotEqual(host.client.expected['epoch'], old['epoch'])
                self.assertFalse(any(r.get('event') == 'owned_virtual_send_accepted' for r in host.records()))
                host.input(value=53, generation=fresh['connection_generation'])
                self.assertEqual(host.finish(), 0)
            finally:
                host.close()

    def test_owned_permission_bad_frame_and_signal_cleanup_are_visible_and_send_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningOwned(directory, feedback=False)
            try:
                host.input()
                with self.assertRaises(SurfaceError) as caught:
                    host.client.feedback('a.encoder.1', 'value', 5)
                self.assertEqual(caught.exception.code, 'permission_denied')
                os.write(host.writer, b'x' * 4097 + b'\n')
                host.process.wait(timeout=5)
                self.assertNotEqual(host.process.returncode, 0)
                host.reader.join(timeout=2)
                self.assertFalse(any(r.get('event') == 'owned_virtual_send_accepted' for r in host.records()))
                self.assertTrue(any(r.get('event', '').startswith('owned_virtual_fatal') for r in host.records()))
                self.assertFalse(host.ready_path.exists())
            finally:
                host.close()
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as directory:
                host = RunningOwned(directory)
                try:
                    host.process.send_signal(sig)
                    host.process.wait(timeout=5)
                    host.reader.join(timeout=2)
                    self.assertEqual(host.process.returncode, -sig)
                    self.assertFalse(host.ready_path.exists())
                    self.assertFalse(any(r.get('event') == 'owned_virtual_send_accepted' for r in host.records()))
                finally:
                    host.close()

    def test_default_bytes_and_owned_startup_conflicts_are_explicit(self):
        root = Path(__file__).resolve().parents[2]
        fixture = root / 'Tests/Fixtures/OwnedRehearsal'
        provenance = json.loads((fixture / 'provenance.json').read_text())
        env = {key: value for key, value in os.environ.items() if not key.startswith('XTOUCH_HARDWARE_TEST_')}
        for record in provenance['records']:
            completed = subprocess.run([str(BINARY), *record['argv_tail']], capture_output=True, env=env, timeout=5)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout, (fixture / record['path']).read_bytes())
        base = [str(BINARY), '--describe', '--receive-channel', '2', '--light-protocol', 'observed114']
        for options in [('--owned-virtual-rehearsal', '--owned-virtual-rehearsal'),
                        ('--owned-virtual-rehearsal', '--device-access', 'enabled'),
                        ('--owned-virtual-rehearsal', '--device-access', 'disabled'),
                        ('--owned-virtual-rehearsal', '--device', 'anything'),
                        ('--owned-virtual-steps-fd', '3')]:
            with self.subTest(options=options):
                completed = subprocess.run([*base, *options], capture_output=True, env=env, timeout=5)
                self.assertNotEqual(completed.returncode, 0)
        for name in ['XTOUCH_HARDWARE_TEST_SCRIPT', 'XTOUCH_HARDWARE_TEST_REPORT', 'XTOUCH_HARDWARE_TEST_TIMING']:
            with self.subTest(environment=name):
                completed = subprocess.run([*base, '--owned-virtual-rehearsal'], capture_output=True, env={**env, name: 'unused'}, timeout=5)
                self.assertNotEqual(completed.returncode, 0)
