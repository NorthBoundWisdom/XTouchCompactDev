"""The measurement recorder is Debug fake MIDI support, not a second production output path."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from configs.measure_display_budget import FakeHost
from test_http_simulator import ROOT


@unittest.skipUnless(sys.platform == 'darwin', 'hardware service is macOS only')
class DisplayMeasurementTests(unittest.TestCase):
    def binary(self):
        return Path(os.environ.get('XTOUCH_HARDWARE_BINARY', ROOT / '.build/debug/XTouchSurfaceHardware')).resolve()

    def test_fake_receipts_record_order_without_tokens_and_failed_sends_record_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            host = FakeHost(self.binary(), directory)
            try:
                self.assertEqual(host.receipts.read_bytes(), b'')
                for control, kind, value in [('a.encoder.2', 'value', 7), ('a.button.3', 'indicator', 'on')]:
                    result = host.rpc('display', 'feedback', {'expected': host.expected, 'control_id': control,
                                                             'kind': kind, 'value': value})
                    self.assertFalse(result.get('isError'))
                receipt_bytes = host.receipts.read_text()
                self.assertFalse(any(token in receipt_bytes for token in host.tokens.values()))
                receipts = [json.loads(line) for line in receipt_bytes.splitlines()]
                self.assertEqual([(row['send_index'], row['kind'], row['index']) for row in receipts],
                                 [(1, 'style', 2), (2, 'value', 2), (3, 'indicator', 3)])
                self.assertEqual([row['server_time'] for row in receipts], sorted(row['server_time'] for row in receipts))
                before = host.rpc('operator', 'snapshot', {'instance_id': 'display.budget'})['structuredContent']
                host.rows.append({'fail_send': True})
                staging = host.script.with_suffix('.next')
                staging.write_text(json.dumps(host.rows))
                staging.replace(host.script)
                failed = host.rpc('display', 'feedback', {'expected': host.expected, 'control_id': 'a.button.3',
                                                        'kind': 'indicator', 'value': 'off'})
                self.assertEqual(failed['structuredContent']['code'], 'transport_error')
                self.assertEqual(host.receipts.read_text(), receipt_bytes)
                after = host.rpc('operator', 'snapshot', {'instance_id': 'display.budget'})['structuredContent']
                self.assertEqual(before['feedback'], after['feedback'])
                self.assertEqual(before['discovery']['latest_sequence'], after['discovery']['latest_sequence'])
            finally:
                host.close()
            self.assertEqual(host.receipts.read_text(), receipt_bytes)

    def test_timing_capture_refuses_to_overwrite_an_existing_evidence_file(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'test-only-display-receipts.jsonl'
            evidence.write_text('previous evidence\n')
            with self.assertRaisesRegex(RuntimeError, 'Debug fake host refused startup'):
                FakeHost(self.binary(), directory)
            self.assertEqual(evidence.read_text(), 'previous evidence\n')
