"""Tests for sparkle_ed.py. Run: python3 -m unittest discover -s app/scripts -p 'test_*.py'"""

import base64
import contextlib
import io
import os
import tempfile
import unittest

import sparkle_ed as ed

# RFC 8032, section 7.1: TEST 1, TEST 2 and TEST 3.
VECTORS = [
    (
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "",
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ),
    (
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    ),
    (
        "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        "af82",
        "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
    ),
]


def b64(data):
    return base64.b64encode(data).decode()


class Ed25519Tests(unittest.TestCase):
    def test_rfc8032_vectors(self):
        for seed, public, message, signature in VECTORS:
            seed, public = bytes.fromhex(seed), bytes.fromhex(public)
            message, signature = bytes.fromhex(message), bytes.fromhex(signature)
            self.assertEqual(ed.public_key(seed), public)
            self.assertEqual(ed.sign(seed, message), signature)
            self.assertTrue(ed.verify(public, message, signature))
            self.assertFalse(ed.verify(public, message + b"!", signature))
            tampered = bytearray(signature)
            tampered[40] ^= 0x01
            self.assertFalse(ed.verify(public, message, bytes(tampered)))
            self.assertFalse(ed.verify(public, message, signature[:63]))

    def test_chunks_match_whole_message(self):
        seed = os.urandom(32)
        message = os.urandom(3 * 1024 + 7)
        signature = ed.sign(seed, message)
        chunks = [message[:1000], message[1000:1001], message[1001:]]
        self.assertTrue(ed.verify_chunks(ed.public_key(seed), chunks, signature))
        other = ed.public_key(os.urandom(32))
        self.assertFalse(ed.verify_chunks(other, chunks, signature))


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.folder.cleanup()

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = ed.main(list(args))
        return code, out.getvalue().strip(), err.getvalue().strip()

    def test_generate_public_key_and_verify(self):
        key_file = os.path.join(self.folder.name, "key.txt")
        code, public, _ = self.run_main("generate", key_file)
        self.assertEqual(code, 0)
        self.assertEqual(oct(os.stat(key_file).st_mode & 0o777), "0o600")
        self.assertEqual(len(base64.b64decode(public)), 32)
        code, derived, _ = self.run_main("public-key", key_file)
        self.assertEqual((code, derived), (0, public))

        with open(key_file, encoding="utf-8") as handle:
            seed = base64.b64decode(handle.read())
        update = os.path.join(self.folder.name, "Ladle.dmg")
        with open(update, "wb") as handle:
            handle.write(os.urandom(300_000))
        with open(update, "rb") as handle:
            signature = b64(ed.sign(seed, handle.read()))
        self.assertEqual(self.run_main("verify", update, signature, public)[0], 0)
        stranger = b64(ed.public_key(os.urandom(32)))
        code, _, err = self.run_main("verify", update, signature, stranger)
        self.assertEqual(code, 1)
        self.assertIn("doesn't match", err)

    def test_rejects_malformed_keys(self):
        update = os.path.join(self.folder.name, "file")
        with open(update, "wb") as handle:
            handle.write(b"x")
        code, _, err = self.run_main("verify", update, b64(bytes(64)), "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY")
        self.assertEqual(code, 1)
        self.assertIn("error", err)
        key_file = os.path.join(self.folder.name, "short.txt")
        with open(key_file, "w", encoding="utf-8") as handle:
            handle.write(b64(bytes(16)))
        self.assertEqual(self.run_main("public-key", key_file)[0], 1)
        self.assertEqual(self.run_main("nonsense")[0], 2)


if __name__ == "__main__":
    unittest.main()
