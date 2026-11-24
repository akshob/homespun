# SPDX-License-Identifier: Apache-2.0
import unittest

from uploaded_build import uploaded_build


class UploadedBuildTests(unittest.TestCase):
    def test_selects_the_explicit_uploaded_build_among_other_archive_output(self):
        self.assertEqual(uploaded_build(
            "Archived build 202611241200\nUploaded build 202611241201 (Homespun)\n"
            "An older build 202611241159 is VALID\n"), "202611241201")
        self.assertEqual(uploaded_build(
            "Uploaded build 202611241201. It shows in App Store Connect after processing:\n"
            "  python3 scripts/asc.py wait 202611241201\n"), "202611241201")

    def test_rejects_missing_malformed_or_ambiguous_upload_identity(self):
        for log in ["Upload failed\n", "Uploaded build \n", "Uploaded build 0\n",
                    "Uploaded build 202611241201oops\n",
                    "Uploaded build 202611241201.1\n",
                    "Uploaded build 202611241201\nUploaded build 202611241202\n",
                    "Uploaded build 202611241201\nUploaded build 202611241201\n"]:
            with self.subTest(log=log):
                with self.assertRaises(ValueError):
                    uploaded_build(log)
