"""Tests for publish_release.py. Run: python3 -m unittest discover -s app/scripts -p 'test_*.py'"""

import base64
import contextlib
import io
import json
import os
import tempfile
import unittest
import urllib.error
import xml.etree.ElementTree as ET

import publish_release as release

REPO = "ALIRAZA47/ladle-mac"

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
version: {version}
title: A pour
{date}---

What changed.
"""

SIGNATURE = base64.b64encode(bytes(range(64))).decode()


def sparkle_json(version, build, length=1000, signature=SIGNATURE, minimum="14.0"):
    return {"version": version, "build": build, "edSignature": signature, "length": length, "minimumSystemVersion": minimum}


def fake_release(version, draft=False, prerelease=False, tag=None, assets=("Ladle.dmg", "sparkle.json", "Ladle-Chrome-Extension.zip"), size=1000, month=None):
    tag = tag or "v" + version
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "published_at": "2026-%s-01T15:30:00Z" % (month or "11"),
        "assets": [
            {
                "name": name,
                "size": size if name == "Ladle.dmg" else 10,
                "browser_download_url": "https://github.com/%s/releases/download/%s/%s" % (REPO, tag, name),
            }
            for name in assets
        ],
    }


class Fetcher:
    """Serves each release's sparkle.json from a dict, and records what was fetched."""

    def __init__(self, files):
        self.files = files
        self.fetched = []

    def __call__(self, url):
        self.fetched.append(url)
        if url not in self.files:
            raise urllib.error.URLError("no such file: %s" % url)
        return json.dumps(self.files[url]).encode()


def url(version, name="sparkle.json"):
    return "https://github.com/%s/releases/download/v%s/%s" % (REPO, version, name)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.feed = os.path.join(self.folder.name, "appcast.xml")
        self.changelog = os.path.join(self.folder.name, "changelog")
        os.mkdir(self.changelog)
        with open(self.feed, "w", encoding="utf-8") as handle:
            handle.write(EMPTY_FEED)

    def tearDown(self):
        self.folder.cleanup()

    def write_notes(self, version, date=None):
        path = os.path.join(self.changelog, "%s.md" % version)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(NOTES.format(version=version, date="date: %s\n" % date if date else ""))
        return path

    def read(self, path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def items(self):
        return ET.parse(self.feed).getroot().find("channel").findall("item")

    # Release notes

    def test_check_notes(self):
        path = self.write_notes("0.1.0")
        release.check_notes(path, "0.1.0")
        with self.assertRaises(ValueError):
            release.check_notes(path, "0.1.1")

    def test_set_missing_date_keeps_an_existing_date(self):
        path = self.write_notes("0.1.0")
        self.assertTrue(release.set_missing_date(path, "2026-11-01"))
        self.assertFalse(release.set_missing_date(path, "2026-12-24"))
        text = self.read(path)
        self.assertTrue(text.startswith("---\nversion: 0.1.0\ntitle: A pour\ndate: 2026-11-01\n---\n"))
        self.assertIn("What changed.", text)
        release.check_notes(path, "0.1.0")

    # sparkle.json

    def test_sparkle_json_from_sign_update(self):
        out = os.path.join(self.folder.name, "sparkle.json")
        attributes = 'sparkle:edSignature="%s" length="123456"' % SIGNATURE
        code = release.main(["sparkle-json", "--version", "0.1.0", "--build", "1", "--attributes", attributes, "--out", out])
        self.assertEqual(code, 0)
        with open(out, encoding="utf-8") as handle:
            data = json.load(handle)
        self.assertEqual(data, sparkle_json("0.1.0", 1, length=123456))
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(["sparkle-json", "--version", "0.1.0", "--build", "1", "--attributes", "nothing", "--out", out]), 1)

    def test_validate_sparkle_json(self):
        good = sparkle_json("1.0.0", 4)
        self.assertEqual(release.validate_sparkle_json(dict(good, build="4"), "1.0.0")["build"], 4)
        for bad in [
            dict(good, version="1.0.1"),
            dict(good, build=0),
            dict(good, length="many"),
            dict(good, edSignature="short"),
            dict(good, edSignature=base64.b64encode(bytes(32)).decode()),
            dict(good, minimumSystemVersion=""),
            ["not", "an", "object"],
        ]:
            with self.assertRaises(ValueError):
                release.validate_sparkle_json(bad, "1.0.0")

    # The feed

    def test_feed_from_published_releases(self):
        releases = [fake_release("0.%d.0" % n, month="%02d" % n) for n in range(1, 13)]
        releases += [
            fake_release("0.20.0", draft=True),
            fake_release("0.21.0", prerelease=True),
            fake_release("0.22.0", tag="v0.22.0-beta"),
            fake_release("0.23.0", assets=("Ladle.dmg",)),
            fake_release("0.24.0", assets=("sparkle.json",)),
        ]
        fetch = Fetcher({url("0.%d.0" % n): sparkle_json("0.%d.0" % n, n) for n in range(1, 13)})
        self.write_notes("0.12.0")
        self.write_notes("0.11.0", date="2026-01-01")

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            versions = release.build_feed(REPO, self.feed, self.changelog, releases, fetch)

        self.assertEqual(versions, ["0.%d.0" % n for n in range(12, 2, -1)], "newest first, the last 10")
        self.assertEqual(len(fetch.fetched), 12, "only published vX.Y.Z releases with both assets")
        channel = ET.parse(self.feed).getroot().find("channel")
        self.assertEqual(channel.findtext("title"), "Ladle")
        first = self.items()[0]
        self.assertEqual(first.findtext("title"), "Ladle 0.12.0")
        self.assertEqual(first.findtext("pubDate"), "Tue, 01 Dec 2026 15:30:00 GMT")
        self.assertEqual(first.findtext(release.sparkle("version")), "12")
        self.assertEqual(first.findtext(release.sparkle("shortVersionString")), "0.12.0")
        self.assertEqual(first.findtext(release.sparkle("minimumSystemVersion")), "14.0")
        self.assertEqual(first.findtext(release.sparkle("releaseNotesLink")), "https://ladle.alirazakhan.me/changelog/#v0-12-0")
        enclosure = first.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/ALIRAZA47/ladle-mac/releases/download/v0.12.0/Ladle.dmg")
        self.assertEqual(enclosure.get("length"), "1000")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(release.sparkle("edSignature")), SIGNATURE)
        text = self.read(self.feed)
        self.assertTrue(text.startswith('<?xml version="1.0" encoding="utf-8"?>\n<rss '))
        self.assertEqual(text.count('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'), 1)
        self.assertIn("<sparkle:shortVersionString>0.12.0</sparkle:shortVersionString>", text)

        self.assertIn("date: 2026-12-01", self.read(os.path.join(self.changelog, "0.12.0.md")), "dated from published_at")
        self.assertIn("date: 2026-01-01", self.read(os.path.join(self.changelog, "0.11.0.md")), "an existing date stays")

    def test_zero_releases_leave_an_empty_channel(self):
        with open(self.feed, "w", encoding="utf-8") as handle:
            handle.write(EMPTY_FEED.replace("</channel>", "<item><title>Ladle 9.9.9</title></item></channel>"))
        self.assertEqual(release.build_feed(REPO, self.feed, self.changelog, [], Fetcher({})), [])
        self.assertEqual(self.items(), [])
        channel = ET.parse(self.feed).getroot().find("channel")
        self.assertEqual(channel.findtext("title"), "Ladle")
        self.assertEqual(channel.findtext("language"), "en")
        # Still a Sparkle feed, written the way the site keeps it.
        self.assertEqual(self.read(self.feed), EMPTY_FEED)

    def test_a_bad_release_writes_nothing(self):
        releases = [fake_release("1.0.0"), fake_release("1.1.0", size=999)]
        fetch = Fetcher({url("1.0.0"): sparkle_json("1.0.0", 1), url("1.1.0"): sparkle_json("1.1.0", 2)})
        with self.assertRaises(ValueError):
            release.build_feed(REPO, self.feed, self.changelog, releases, fetch)
        self.assertEqual(self.read(self.feed), EMPTY_FEED, "the DMG's size and sparkle.json disagree")
        with self.assertRaises(urllib.error.URLError):
            release.build_feed(REPO, self.feed, self.changelog, [fake_release("1.0.0")], Fetcher({}))
        self.assertEqual(self.read(self.feed), EMPTY_FEED, "a sparkle.json that can't be downloaded")

    def test_command_line_reads_every_page_and_fails_without_github(self):
        original_json, original_bytes = release.fetch_json, release.fetch_bytes
        pages = [[fake_release("0.%d.0" % n) for n in range(100)], [fake_release("1.0.0")]]
        requested = []

        def fake_json(address, token=None):
            requested.append((address, token))
            return pages[len(requested) - 1] if len(requested) <= len(pages) else []

        def fake_bytes(address):
            version = address.split("/download/v")[1].split("/")[0]
            build = 200 if version == "1.0.0" else int(version.split(".")[1]) + 1
            return json.dumps(sparkle_json(version, build)).encode()

        args = ["feed", "--repo", REPO, "--appcast", self.feed, "--changelog", self.changelog]
        try:
            release.fetch_json, release.fetch_bytes = fake_json, fake_bytes
            os.environ["GITHUB_TOKEN"] = "token-for-test"
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(release.main(args), 0)
            self.assertEqual(len(requested), 2, "follows the second page")
            self.assertTrue(requested[1][0].endswith("/repos/ALIRAZA47/ladle-mac/releases?per_page=100&page=2"))
            self.assertEqual(requested[0][1], "token-for-test")
            self.assertEqual(self.items()[0].findtext("title"), "Ladle 1.0.0")
            self.assertEqual(len(self.items()), 10)

            def offline(address, token=None):
                raise urllib.error.URLError("offline")

            release.fetch_json = offline
            before = self.read(self.feed)
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(release.main(args), 1)
            self.assertIn("offline", err.getvalue())
            self.assertEqual(self.read(self.feed), before, "a failed listing leaves the feed alone")
        finally:
            release.fetch_json, release.fetch_bytes = original_json, original_bytes
            os.environ.pop("GITHUB_TOKEN", None)


if __name__ == "__main__":
    unittest.main()
