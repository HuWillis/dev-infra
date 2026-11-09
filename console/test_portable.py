import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import server
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import start


class PortableTests(unittest.TestCase):
    def test_prefers_powershell_seven(self):
        with patch('server.executable', return_value='/usr/local/bin/pwsh') as lookup:
            self.assertEqual(server.powershell_executable(), '/usr/local/bin/pwsh')
        self.assertEqual(lookup.call_args.args[0], 'pwsh')

    def test_windows_falls_back_to_builtin_powershell(self):
        with patch('server.os', SimpleNamespace(name='nt', environ={})), patch('server.executable', side_effect=[RuntimeError(), 'powershell.exe']):
            self.assertEqual(server.powershell_executable(), 'powershell.exe')

    def test_mac_missing_powershell_has_actionable_error(self):
        with patch('server.os', SimpleNamespace(name='posix')), patch('server.executable', side_effect=RuntimeError()) as lookup:
            with self.assertRaisesRegex(RuntimeError, 'PowerShell 7'):
                server.powershell_executable()
        self.assertEqual(lookup.call_count, 1)

    def test_launcher_does_not_open_another_checkout(self):
        with patch('sys.argv', ['start.py', '--no-open']), patch('start.probe', return_value={'app':server.APP_ID, 'root':'another-checkout'}), patch('start.subprocess.Popen') as child:
            with self.assertRaisesRegex(SystemExit, 'another checkout'):
                start.main()
            child.assert_not_called()

    def test_launcher_reuses_same_checkout(self):
        with patch('sys.argv', ['start.py', '--no-open']), patch('start.probe', return_value={'app':server.APP_ID, 'root':str(start.ROOT)}), patch('start.subprocess.Popen') as child:
            start.main()
            child.assert_not_called()
