"""SC-R05 real subprocess tests. Credentials exist only in this process and anonymous pipes."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

from test_http_simulator import BINARY, ROOT, Client


def credentials():
    return {role: secrets.token_hex(32) for role in ('owner', 'operator', 'display')}


class ScopedHost:
    def __init__(self, directory, tokens, hardware=False, extra=(), raw_record=None):
        self.directory = Path(directory)
        self.tokens = {role: token for role, token in tokens.items() if role != 'displays'}
        self.tokens.update({'display.' + str(index + 1): token for index, token in enumerate(tokens.get('displays', []))})
        self.script = self.directory / 'test-only-midi.json'
        env = dict(os.environ)
        env.pop('XTOUCH_HARDWARE_TEST_SCRIPT', None)
        env.pop('XTOUCH_HARDWARE_TEST_REPORT', None)
        if hardware:
            executable = Path(os.environ.get('XTOUCH_HARDWARE_BINARY', ROOT / '.build/debug/XTouchSurfaceHardware')).resolve()
            self.script.write_text(json.dumps([{'connected': True}, {'bytes': [176, 37, 64]}]))
            env['XTOUCH_HARDWARE_TEST_SCRIPT'] = str(self.script)
            command = [str(executable), '--receive-channel', '2', '--light-protocol', 'observed114', '--allow-surface-feedback']
        else:
            command = [str(BINARY), '--allow-surface-input', '--allow-surface-feedback', '--allow-surface-reset']
        command += ['--surface-client-tokens-stdin', '--surface-instance-id', 'scoped.test', *extra]
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, cwd=directory, env=env)
        self.process.stdin.write(raw_record if raw_record is not None else json.dumps(tokens) + '\n')
        self.process.stdin.close()
        line = self.process.stdout.readline()
        if not line:
            self.process.wait(timeout=5)
            message = self.process.stderr.read()
            self.process.stdout.close()
            self.process.stderr.close()
            raise AssertionError('Scoped host failed startup: ' + message)
        self.ready = json.loads(line)
        self.clients = {role: Client(self.ready['url'], token, 'scoped.test',
                                    accepted_sources=('hardware',) if hardware else ('simulation',))
                        for role, token in self.tokens.items()}
        for client in self.clients.values():
            client.discover()

    def call(self, role, name, arguments=None, token=None):
        envelope = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                    'params': {'name': name, 'arguments': arguments or {}}}
        return self.rpc(role, envelope, token=token)

    def rpc(self, role, envelope, token=None):
        request = urllib.request.Request(self.ready['url'], json.dumps(envelope).encode(),
                                        {'Authorization': 'Bearer ' + (token or self.tokens[role]), 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)['result']

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


class ScopedCredentialTests(unittest.TestCase):
    def assert_role_catalogues(self, hardware=False):
        suffixes = {
            'owner': ['discover', 'snapshot', 'input', 'feedback', 'events', 'reset', 'renew'],
            'operator': ['discover', 'snapshot', 'input', 'renew', 'events'],
            'display': ['discover', 'snapshot', 'feedback', 'events'],
        }
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, credentials(), hardware=hardware)
            try:
                original = host.clients['owner'].snapshot()
                owner_tools = host.rpc('owner', {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})['tools']
                self.assertEqual([tool['name'] for tool in owner_tools],
                                 ['surface_control_' + name for name in suffixes['owner']])
                for role, permitted in suffixes.items():
                    with self.subTest(role=role, hardware=hardware):
                        response = host.rpc(role, {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
                        expected = [tool for tool in owner_tools
                                    if tool['name'] in {'surface_control_' + name for name in permitted}]
                        # Keep each complete descriptor, its schema and its order unchanged.
                        self.assertEqual(response, {'tools': expected})
                after = host.clients['owner'].snapshot()
                self.assertEqual({key: value for key, value in after.items() if key != 'server_time'},
                                 {key: value for key, value in original.items() if key != 'server_time'})
            finally:
                host.close()

    def test_simulator_catalogue_only_lists_the_authenticated_role_tools(self):
        self.assert_role_catalogues()

    @unittest.skipUnless(sys.platform == 'darwin', 'hardware service is macOS only')
    def test_hardware_catalogue_only_lists_the_authenticated_role_tools(self):
        self.assert_role_catalogues(hardware=True)

    def test_operator_display_are_separate_trusted_writers_with_enforced_scopes(self):
        tokens = credentials()
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, tokens)
            try:
                operator = host.clients['operator']
                display = host.clients['display']
                owner = host.clients['owner']
                pressed = operator.input('a.touch.1', 'boolean', True, hold_s=2)
                shown = display.feedback('a.encoder.1', 'value', 12)
                owner_event = owner.feedback('a.encoder.2', 'value', 13)
                writers = {pressed['writer_id'], shown['writer_id'], owner_event['writer_id']}
                self.assertEqual(len(writers), 3)
                self.assertTrue(all(len(writer) == 32 and all(c in '0123456789abcdef' for c in writer) for writer in writers))
                self.assertFalse(any(token in json.dumps([pressed, shown, owner_event, host.ready]) for token in tokens.values()))
                renewal = operator.renew('a.touch.1', hold_s=3)
                self.assertGreater(renewal['hold_deadline'], pressed['hold_deadline'])
                expected = operator.expected
                before = owner.snapshot()
                denied = [
                    ('display', 'surface_control_input', {'expected': expected, 'expected_input_sequence': pressed['input_sequence'], 'control_id': 'a.encoder.3', 'encoding': 'scalar', 'value': 42}),
                    ('display', 'surface_control_renew', {'expected': expected, 'control_id': 'a.touch.1', 'hold_s': 1}),
                    ('operator', 'surface_control_feedback', {'expected': expected, 'control_id': 'a.encoder.1', 'kind': 'value', 'value': 7}),
                ]
                denied += [(role, name, {'expected': expected, 'expected_sequence': before['discovery']['latest_sequence']})
                           for role in ('operator', 'display') for name in ('surface_control_reset', 'unknown_legacy_tool')]
                for role, name, arguments in denied:
                    with self.subTest(role=role, tool=name):
                        reply = host.call(role, name, arguments)
                        self.assertTrue(reply['isError'])
                        self.assertEqual(reply['structuredContent']['code'], 'permission_denied')
                after = owner.snapshot()
                for field in ('inputs', 'feedback', 'holds'):
                    self.assertEqual(after.get(field), before.get(field))
                self.assertEqual(after['discovery']['latest_sequence'], before['discovery']['latest_sequence'])
                for role in ('operator', 'display'):
                    page = host.call(role, 'surface_control_events', {'instance_id': 'scoped.test', 'epoch': expected['epoch'], 'after_sequence': '0', 'limit': 100})['structuredContent']
                    self.assertEqual([e['writer_id'] for e in page['events']], [pressed['writer_id'], shown['writer_id'], owner_event['writer_id']])
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    host.call('operator', 'surface_control_discover', token=secrets.token_hex(32))
                self.assertEqual(caught.exception.code, 401)
                caught.exception.close()
                # Owner's old reset permission is preserved; secondary credentials cannot gain it.
                self.assertFalse(host.call('owner', 'surface_control_reset', {'expected': expected, 'expected_sequence': after['discovery']['latest_sequence']})['isError'])
            finally:
                host.close()

    def test_separate_clients_share_the_existing_aggregate_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, credentials(), extra=("--write-limit", "2"))
            try:
                # Permission failures are not charged. Accepted writes by both clients share 2/s.
                expected = host.clients["owner"].expected
                denied = host.call("operator", "surface_control_feedback", {"expected": expected, "control_id": "a.encoder.1", "kind": "value", "value": 1})
                self.assertEqual(denied["structuredContent"]["code"], "permission_denied")
                first = host.clients["operator"].input("a.encoder.1", "scalar", 20)
                second = host.clients["display"].feedback("a.encoder.2", "value", 13)
                third = host.call("owner", "surface_control_feedback", {"expected": expected, "control_id": "a.encoder.3", "kind": "value", "value": 14})
                self.assertEqual(third["structuredContent"]["code"], "rate_limited")
                self.assertEqual(host.clients["owner"].snapshot()["discovery"]["latest_sequence"], second["sequence"])
                self.assertNotEqual(first["writer_id"], second["writer_id"])
            finally:
                host.close()

    def test_v1_principal_persists_owner_only_secondary_ids_rotate_on_restart(self):
        tokens = credentials()
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / 'principals.json'
            observed = []
            for _ in range(2):
                host = ScopedHost(directory, tokens, extra=('--surface-principal-file', str(record)))
                try:
                    events = [host.clients[role].feedback('a.encoder.%d' % index, 'value', index)
                              if role != 'operator' else host.clients[role].input('a.encoder.3', 'scalar', 12)
                              for index, role in enumerate(('owner', 'operator', 'display'), 1)]
                    observed.append([event['writer_id'] for event in events])
                finally:
                    host.close()
            self.assertEqual(observed[0][0], observed[1][0])
            self.assertNotEqual(observed[0][1], observed[1][1])
            self.assertNotEqual(observed[0][2], observed[1][2])
            self.assertEqual(set(json.loads(record.read_text())), {'schema_version', 'remote_writer_id', 'interface_writer_id', 'system_writer_id'})
            self.assertFalse(any(token in record.read_text() for token in tokens.values()))

    def test_startup_refuses_bad_records_duplicates_oversize_and_old_input_flags(self):
        good = credentials()
        invalid = [
            json.dumps({key: value for key, value in good.items() if key != 'display'}),
            json.dumps({**good, 'extra': 'x'}),
            json.dumps({**good, 'display': good['operator']}),
            json.dumps({**good, 'operator': 'bad'}),
            json.dumps(good)[:-1] + ',"display":' + json.dumps(good['display']) + '}',
            ' ' * 513,
        ]
        with tempfile.TemporaryDirectory() as directory:
            for index, payload in enumerate(invalid):
                with self.subTest(case=index):
                    result = subprocess.run([str(BINARY), '--surface-client-tokens-stdin'], input=payload, text=True, capture_output=True, cwd=directory, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, '')
                    self.assertFalse(any(token in result.stderr for token in good.values()))
            for extra in (['--token-stdin'], ['--token-file', '/does-not-exist']):
                result = subprocess.run([str(BINARY), '--surface-client-tokens-stdin', *extra], input=json.dumps(good), text=True, capture_output=True, cwd=directory, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
            result = subprocess.run([str(BINARY), '--surface-client-tokens-stdin'], stdin=subprocess.DEVNULL, text=True, capture_output=True, cwd=directory, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            # Describe remains a read-only operation and does not consume its supplied stdin.
            result = subprocess.run([str(BINARY), '--surface-client-tokens-stdin', '--describe'], input='invalid', text=True, capture_output=True, cwd=directory, timeout=5)
            self.assertEqual(result.returncode, 0)

    @unittest.skipUnless(sys.platform == 'darwin', 'hardware service is macOS only')
    def test_hardware_scopes_keep_remote_input_denied_and_attribute_display_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, credentials(), hardware=True)
            try:
                expected = host.clients['owner'].expected
                before = host.clients['owner'].snapshot()
                probes = [
                    ('surface_control_input', {'expected': expected, 'expected_sequence': before['discovery']['latest_sequence'], 'control_id': 'b.fader.1', 'encoding': 'scalar', 'value': 127}, 'permission_denied'),
                    ('surface_control_renew', {'expected': expected, 'control_id': 'b.button.1', 'hold_s': 1}, 'unsupported_hold'),
                    ('surface_control_reset', {'expected': expected, 'expected_sequence': before['discovery']['latest_sequence']}, 'permission_denied'),
                ]
                for name, arguments, code in probes:
                    self.assertEqual(host.call('operator', name, arguments)['structuredContent']['code'], code)
                shown = host.clients['display'].feedback('b.encoder.1', 'value', 13)
                owner_event = host.clients['owner'].feedback('b.button.2', 'indicator', 'on')
                page = host.call('display', 'surface_control_events', {'instance_id': 'scoped.test', 'epoch': expected['epoch'], 'after_sequence': '0', 'limit': 100})['structuredContent']
                self.assertEqual(len(page['events']), 3)
                self.assertEqual(len({e['writer_id'] for e in page['events']}), 3)
                self.assertNotEqual(shown['writer_id'], owner_event['writer_id'])
                self.assertEqual(host.clients['owner'].snapshot()['inputs'], before['inputs'])
            finally:
                host.close()
