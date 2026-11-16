"""Read-only actual binary discovery agrees with packaged display tables; no devices."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

from test_http_simulator import BINARY, ROOT


class DisplayCatalogueTests(unittest.TestCase):
    def check_catalogue(self, source, binary, extra=()):
        result = subprocess.run([str(binary), '--describe', *extra], capture_output=True, check=True)
        description = json.loads(result.stdout)
        controls = description['discovery']['profile']['controls']
        if source == 'hardware':
            self.assertTrue(all(not row['feedback_kinds'] for row in controls if '.fader.' in row['id']))
        subprocess.run([sys.executable, str(ROOT / 'configs/check_display_targets.py'),
                        '--binary', str(binary), '--source', source, '--table',
                        str(ROOT / ('docs/DISPLAY_TARGETS_' + source.upper() + '.md'))], check=True)

    def test_default_simulation_catalogue_matches_actual_discovery(self):
        self.check_catalogue('simulation', BINARY)

    @unittest.skipUnless(sys.platform == 'darwin', 'hardware service is macOS only')
    def test_default_hardware_catalogue_matches_discovery_and_has_no_fader_feedback(self):
        binary = Path(os.environ.get('XTOUCH_HARDWARE_BINARY', ROOT / '.build/debug/XTouchSurfaceHardware')).resolve()
        self.check_catalogue('hardware', binary, ('--receive-channel', '2', '--light-protocol', 'observed114'))
