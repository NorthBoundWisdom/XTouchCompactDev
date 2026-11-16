"""Explicit extended startup records isolate display writers; legacy records keep shared quotas."""
import json
import secrets
import subprocess
import sys
import tempfile
import unittest

from test_http_simulator import BINARY, Client
from test_scoped_credentials import ScopedHost, credentials


class MultiDisplayCredentialTests(unittest.TestCase):
    def record(self, extra=1):
        return {**credentials(), 'displays': [secrets.token_hex(32) for _ in range(extra)]}

    def check_independent_feedback(self, hardware=False):
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, self.record(), hardware=hardware,
                              extra=('--write-limits', 'input=2,feedback=2,renew=2,admin=2'))
            try:
                layer = 'b' if hardware else 'a'
                first, second = host.clients['display'], host.clients['display.1']
                old = host.clients['operator'].snapshot()
                written = [first.feedback(layer + '.encoder.1', 'value', 1),
                           first.feedback(layer + '.encoder.1', 'value', 2)]
                denied = host.call('display', 'surface_control_feedback',
                                   {'expected': first.expected, 'control_id': layer + '.encoder.1', 'kind': 'value', 'value': 4})
                self.assertEqual(denied['structuredContent']['code'], 'rate_limited')
                written.append(second.feedback(layer + '.encoder.1', 'value', 3))
                written.append(host.clients['owner'].feedback(layer + '.encoder.2', 'value', 7))
                self.assertEqual(len({row['writer_id'] for row in written}), 3)
                after = first.snapshot()
                self.assertEqual(after['feedback'][layer + '.encoder.1']['value'], 3)
                self.assertEqual(old['inputs'], after['inputs'])
                page = host.call('operator', 'surface_control_events', {'instance_id': 'scoped.test',
                    'epoch': first.expected['epoch'], 'after_sequence': old['discovery']['latest_sequence'], 'limit': 1024})['structuredContent']
                self.assertEqual([row['writer_id'] for row in page['events']], [row['writer_id'] for row in written])
                self.assertEqual([row['value'] for row in page['events']], [1, 2, 3, 7])
                for role in ('display', 'display.1'):
                    tools = host.rpc(role, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})['tools']
                    self.assertEqual({tool['name'] for tool in tools}, {'surface_control_' + suffix for suffix in ('discover', 'snapshot', 'feedback', 'events')})
                    refused = host.call(role, 'surface_control_input', {'expected': first.expected})
                    self.assertEqual(refused['structuredContent']['code'], 'permission_denied')
            finally:
                host.close()

    def test_simulator_display_quotas_are_isolated_and_last_writer_is_visible(self):
        self.check_independent_feedback()

    @unittest.skipUnless(sys.platform == 'darwin', 'hardware service is macOS only')
    def test_fake_hardware_display_quotas_are_isolated_and_last_writer_is_visible(self):
        self.check_independent_feedback(hardware=True)

    def test_extended_displays_do_not_consume_the_owner_operator_aggregate_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, self.record(), extra=('--write-limit', '1'))
            try:
                events = [host.clients[role].feedback('a.encoder.' + str(index), 'value', 10 + index)
                          for index, role in enumerate(('display', 'display.1'), 1)]
                events.append(host.clients['owner'].input('a.encoder.3', 'scalar', 20))
                denied = host.call('operator', 'surface_control_input', {'expected': host.clients['owner'].expected,
                    'expected_input_sequence': events[-1]['input_sequence'], 'control_id': 'a.encoder.4', 'encoding': 'scalar', 'value': 21})
                self.assertEqual(denied['structuredContent']['code'], 'rate_limited')
                self.assertEqual(len({event['writer_id'] for event in events}), 3)
            finally:
                host.close()

    def test_eight_display_writers_and_2048_byte_record_are_supported_without_persisting_tokens(self):
        record = self.record(extra=7)
        raw = json.dumps(record)
        raw += ' ' * (2048 - len(raw.encode()))
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, record, raw_record=raw)
            try:
                events = [host.clients[role].feedback('a.encoder.' + str(index + 1), 'value', index + 1)
                          for index, role in enumerate(('display', *(f'display.{i}' for i in range(1, 8))))]
                self.assertEqual(len({event['writer_id'] for event in events}), 8)
                public = json.dumps([host.ready, events])
                self.assertFalse(any(token in public for token in host.tokens.values()))
            finally:
                host.close()

    def test_legacy_display_token_is_one_shared_writer_and_preserves_512_byte_record(self):
        record = credentials()
        raw = json.dumps(record)
        raw += ' ' * (512 - len(raw.encode()))
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, record, raw_record=raw, extra=('--write-limit', '2'))
            try:
                first = host.clients['display']
                second = Client(host.ready['url'], record['display'], 'scoped.test')
                second.discover()
                one = first.feedback('a.encoder.1', 'value', 1)
                two = second.feedback('a.encoder.2', 'value', 2)
                self.assertEqual(one['writer_id'], two['writer_id'])
                denied = host.call('owner', 'surface_control_feedback', {'expected': first.expected,
                    'control_id': 'a.encoder.3', 'kind': 'value', 'value': 3})
                self.assertEqual(denied['structuredContent']['code'], 'rate_limited')
            finally:
                host.close()

    def test_malformed_extended_records_duplicates_and_both_size_limits_are_rejected(self):
        good = self.record()
        duplicate_extra = {**good, 'displays': [good['displays'][0]] * 2}
        invalid = [
            {**good, 'displays': []}, self.record(extra=8), {**good, 'displays': 'invalid'},
            {**good, 'displays': [None]}, {**good, 'displays': ['bad']}, duplicate_extra,
            *({**good, 'displays': [good[role]]} for role in ('owner', 'operator', 'display')),
            {**good, 'other': []},
        ]
        payloads = [json.dumps(value) for value in invalid]
        payloads += [json.dumps(good)[:-1] + ',"displays":' + json.dumps(good['displays']) + '}',
                     json.dumps(good) + ' ' * 2049, json.dumps(credentials()) + ' ' * 513]
        with tempfile.TemporaryDirectory() as directory:
            for index, payload in enumerate(payloads):
                with self.subTest(case=index):
                    result = subprocess.run([str(BINARY), '--surface-client-tokens-stdin'], input=payload,
                                            text=True, capture_output=True, cwd=directory, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, '')
                    self.assertFalse(any(token in result.stderr for token in [good['owner'], good['operator'], good['display'], *good['displays']]))
