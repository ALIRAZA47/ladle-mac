"""Tests for publish_release.py. Run: python3 -m unittest discover -s app/scripts -p 'test_*.py'"""

import os
import tempfile
import unittest
import xml.etree.ElementTree as ET

import publish_release as release

EMPTY_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ladle</title>
    <link>https://ladle.alirazakhan.me/</link>
    <description>Updates for Ladle, the free download manager for Mac.</description>
    <language>en</language>
  </channel>
</rss>
"""

NOTES = """---
version: 1.0.0
title: The first pour
---

The first release of Ladle.
"""


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.feed = os.path.join(self.folder.name, "appcast.xml")
        self.notes = os.path.join(self.folder.name, "1.0.0.md")
        with open(self.feed, "w", encoding="utf-8") as handle:
            handle.write(EMPTY_FEED)
        with open(self.notes, "w", encoding="utf-8") as handle:
            handle.write(NOTES)

    def tearDown(self):
        self.folder.cleanup()

    def add(self, version, build):
        release.update_appcast(
            self.feed,
            version,
            build,
            "https://github.com/ALIRAZA47/ladle-mac/releases/download/v%s/Ladle.dmg" % version,
            1000 + build,
            "sig%d==" % build,
            "Thu, 29 Oct 2026 12:00:00 GMT",
        )

    def items(self):
        return ET.parse(self.feed).getroot().find("channel").findall("item")

    def test_first_release_item(self):
        self.add("1.0.0", 1)
        root = ET.parse(self.feed).getroot()
        channel = root.find("channel")
        self.assertEqual(channel.findtext("title"), "Ladle")
        [item] = channel.findall("item")
        self.assertEqual(item.findtext("title"), "Ladle 1.0.0")
        self.assertEqual(item.findtext(release.sparkle("version")), "1")
        self.assertEqual(item.findtext(release.sparkle("shortVersionString")), "1.0.0")
        self.assertEqual(item.findtext(release.sparkle("minimumSystemVersion")), "14.0")
        self.assertEqual(
            item.findtext(release.sparkle("releaseNotesLink")), "https://ladle.alirazakhan.me/changelog/#v1-0-0"
        )
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/ALIRAZA47/ladle-mac/releases/download/v1.0.0/Ladle.dmg")
        self.assertEqual(enclosure.get("length"), "1001")
        self.assertEqual(enclosure.get(release.sparkle("edSignature")), "sig1==")
        with open(self.feed, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', text)
        self.assertIn("<sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>", text)

    def test_newest_first_rerun_replaces_and_old_items_drop_off(self):
        for build in range(1, 13):
            self.add("1.0.%d" % (build - 1), build)
        self.add("1.0.11", 12)  # the same release again
        versions = [item.findtext(release.sparkle("shortVersionString")) for item in self.items()]
        self.assertEqual(len(versions), release.KEEP_ITEMS)
        self.assertEqual(versions[0], "1.0.11")
        self.assertEqual(versions[-1], "1.0.2")
        self.assertEqual(len(set(versions)), len(versions))

    def test_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            release.update_appcast(self.feed, "1.0", 1, "https://x/Ladle.dmg", 10, "sig")
        with self.assertRaises(ValueError):
            release.update_appcast(self.feed, "1.0.0", 1, "https://x/Ladle.dmg", 10, "")

    def test_release_notes(self):
        release.check_notes(self.notes, "1.0.0")
        with self.assertRaises(ValueError):
            release.check_notes(self.notes, "1.0.1")
        release.set_date(self.notes, "2026-10-29")
        release.set_date(self.notes, "2026-10-30")
        with open(self.notes, encoding="utf-8") as handle:
            text = handle.read()
        self.assertTrue(text.startswith("---\nversion: 1.0.0\ntitle: The first pour\ndate: 2026-10-30\n---\n"))
        self.assertEqual(text.count("date:"), 1)
        self.assertIn("The first release of Ladle.", text)
        release.check_notes(self.notes, "1.0.0")

    def test_command_line(self):
        self.assertEqual(release.main(["check-notes", self.notes, "1.0.0"]), 0)
        self.assertEqual(release.main(["check-notes", os.path.join(self.folder.name, "missing.md"), "1.0.0"]), 1)
        code = release.main(
            ["appcast", self.feed, "--version", "1.0.0", "--build", "1", "--url", "https://x/Ladle.dmg", "--length", "5", "--signature", "abc"]
        )
        self.assertEqual(code, 0)
        self.assertEqual(len(self.items()), 1)


if __name__ == "__main__":
    unittest.main()
