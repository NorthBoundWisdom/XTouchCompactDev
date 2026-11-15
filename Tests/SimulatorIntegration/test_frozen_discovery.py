"""Canonical wire bytes use the independent published 1.3 host, not current descriptors."""
import hashlib
import json
import subprocess
import unittest

from test_http_simulator import BINARY, ROOT


class FrozenSimulationDiscoveryTests(unittest.TestCase):
    def test_default_discovery_matches_published_13_under_fixed_json_encoding(self):
        frozen = (ROOT / 'Tests/Fixtures/surface-simulation-v1.3-discovery.json').read_bytes().rstrip(b'\n')
        self.assertEqual(hashlib.sha256(frozen).hexdigest(), '8c75f0937e4786bdcb3054cf5c0672edd200159fa55205b49cf47b9528113066')
        described = json.loads(subprocess.check_output([str(BINARY), '--describe']))['discovery']
        actual = json.dumps(described, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
        self.assertEqual(actual, frozen)
        # Original SHA/identity: published xtouch-surface-1.3-83f6c2b; original file left untouched.
