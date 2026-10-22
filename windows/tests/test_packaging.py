import subprocess
import sys
import unittest
from pathlib import Path


class PackagingTests(unittest.TestCase):
    def test_duplicate_and_reserved_names_fail_before_reading_inputs(self) -> None:
        script = Path(__file__).resolve().parents[1] / 'scripts/package-test-kit.py'
        for first, second in [('/a/setup.exe', '/b/setup.exe'),
                              ('/a/Setup.exe', '/b/setup.EXE'),
                              ('/a/README.md', '/b/second.exe')]:
            with self.subTest(first=first, second=second):
                result = subprocess.run(
                    [sys.executable, str(script), '--xnook', first, '--xisland', second,
                     '--output', 'unused.zip', '--xisland-inputs', 'unused.json',
                     '--xisland-license', 'unused.txt'], capture_output=True, text=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('文件名与另一安装器或包内材料冲突', result.stderr)
                self.assertNotIn('FileNotFoundError', result.stderr)


if __name__ == '__main__':
    unittest.main()
