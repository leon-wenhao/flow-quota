"""Public-key-only checks against RFC 8032 test vector 1 (no Keychain access)."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sparkle_feed


class SparkleSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = sparkle_feed.verifier()
        cls.public = base64.b64encode(bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
        cls.signature = base64.b64encode(bytes.fromhex(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f"
            "b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")).decode()

    def test_known_signature_passes_and_tampered_data_or_signature_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "message"
            path.write_bytes(b"")
            request = [{"file": str(path), "signature": self.signature}]
            def verify():
                return subprocess.run([str(self.binary), self.public], input=json.dumps(request),
                                      text=True, capture_output=True).returncode
            self.assertEqual(verify(), 0)
            path.write_bytes(b"tampered")
            self.assertNotEqual(verify(), 0)
            path.write_bytes(b"")
            request[0]["signature"] = base64.b64encode(bytes(64)).decode()
            self.assertNotEqual(verify(), 0)
