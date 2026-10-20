"""Ensure the stable signing policy fails closed rather than resetting identity."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import ssl
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("local_signing", Path(__file__).resolve().parents[1] / "scripts/harvis_local_signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class LocalSigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cert = self.root / "public.pem"
        # Parsing only: no private key or machine certificate in this fixture.
        der = b"synthetic certificate bytes"
        self.cert.write_text(ssl.DER_cert_to_PEM_cert(der))
        self.value = {"schemaVersion": 1, "name": "Harvis Local Code Signing",
                      "certificateSha1": hashlib.sha1(der).hexdigest().upper(),
                      "certificateSha256": hashlib.sha256(der).hexdigest(),
                      "certificatePath": str(self.cert), "bundleIdentifiers": [signing.BUNDLE_ID]}
        self.path = self.root / "local-signing.json"
        self.save()

    def save(self):
        self.path.write_text(json.dumps(self.value))
        self.path.chmod(0o600)

    def test_configured_default_and_name_resolve_to_exact_certificate(self):
        config = signing.load_config(self.path)
        for identity in ["auto", self.value["name"], self.value["certificateSha1"]]:
            self.assertEqual(signing.resolve(identity, config), self.value["certificateSha1"])

    def test_pinned_identity_rejects_adhoc_and_replacement(self):
        for identity in ["-", "Developer ID Application: Someone", "", "0" * 40]:
            with self.assertRaises(signing.SigningError):
                signing.resolve(identity, self.value)

    def test_unconfigured_machine_can_make_explicit_local_candidate(self):
        self.assertIsNone(signing.load_config(self.root / "absent.json"))
        with self.assertRaises(signing.SigningError):
            signing.resolve("auto", None)
        self.assertEqual(signing.resolve("-", None), "-")

    def test_changed_certificate_is_not_silently_accepted(self):
        self.cert.write_text(ssl.DER_cert_to_PEM_cert(b"different"))
        with self.assertRaises(signing.SigningError):
            signing.load_config(self.path)

    def test_broken_config_is_not_treated_as_unconfigured(self):
        self.path.write_text("{")
        with self.assertRaises(signing.SigningError):
            signing.load_config(self.path)

    def test_symlink_and_writable_config_rejected(self):
        link = self.root / "link.json"
        link.symlink_to(self.path)
        with self.assertRaises(signing.SigningError):
            signing.load_config(link)
        self.path.chmod(0o666)
        with self.assertRaises(signing.SigningError):
            signing.load_config(self.path)

    def test_scope_does_not_expand_to_other_app_identifiers(self):
        self.value["bundleIdentifiers"].append("other.app")
        self.save()
        with self.assertRaises(signing.SigningError):
            signing.load_config(self.path)

    def test_requirement_binds_certificate_and_app_not_binary_version(self):
        req = signing.requirement(self.value)
        self.assertIn('identifier "local.harzva.harvisbar"', req)
        self.assertIn('certificate leaf = H"' + self.value["certificateSha1"].lower() + '"', req)
        self.assertNotIn("cdhash", req)
        self.assertNotIn(self.value["name"], req)


if __name__ == "__main__":
    unittest.main()
