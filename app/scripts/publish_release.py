#!/usr/bin/env python3
"""Release bookkeeping: the release workflow's checks, and the update feed the site deploys.

  publish_release.py check-notes  <changelog.md> <version>
      The release notes exist for this version and say so (app-release.yml, before building).

  publish_release.py sparkle-json --version 1.2.0 --build 3 --attributes '<sign_update output>'
                                  [--minimum-system-version 14.0] --out sparkle.json
      Writes the sparkle.json the release publishes next to Ladle.dmg.

  publish_release.py feed --repo OWNER/NAME --appcast site/public/appcast.xml
                          --changelog site/src/content/changelog
      Rebuilds Sparkle's appcast from the published releases (site-deploy.yml, before the site
      builds), and dates the release notes that have no `date:` yet. Nothing is committed.

Releases count when they are published (not drafts or pre-releases), tagged vX.Y.Z, and carry
both Ladle.dmg and sparkle.json. The feed lists the newest 10, newest first; each item's release
notes link is the changelog anchor, e.g. #v1-2-0. If GitHub can't be reached, nothing is written
and the command fails, so a deploy never publishes an empty feed by mistake. Standard library only.
"""

import argparse
import base64
import datetime
import email.utils
import json
import os
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SITE = "https://ladle.alirazakhan.me"
API = "https://api.github.com"
MINIMUM_SYSTEM_VERSION = "14.0"
KEEP_ITEMS = 10
DMG = "Ladle.dmg"
SPARKLE_JSON = "sparkle.json"

ET.register_namespace("sparkle", SPARKLE_NS)


def sparkle(tag):
    return "{%s}%s" % (SPARKLE_NS, tag)


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def notes_link(version):
    """https://ladle.alirazakhan.me/changelog/#v1-0-0"""
    return "%s/changelog/#v%s" % (SITE, version.replace(".", "-"))


# MARK: - Release notes


def split_front_matter(text):
    """Returns (front matter lines, body) for a Markdown file that starts with --- … ---."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        raise ValueError("the changelog file has no front matter")
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            return lines[1:index], "\n".join(lines[index + 1 :])
    raise ValueError("the changelog file's front matter isn't closed")


def front_matter_value(lines, key):
    for line in lines:
        match = re.match(r"^%s:\s*(.*?)\s*$" % re.escape(key), line)
        if match:
            return match.group(1).strip("'\"")
    return None


def check_notes(path, version):
    with open(path, encoding="utf-8") as handle:
        lines, body = split_front_matter(handle.read())
    found = front_matter_value(lines, "version")
    if found != version:
        raise ValueError("%s says version %r, expected %r" % (path, found, version))
    if not front_matter_value(lines, "title"):
        raise ValueError("%s has no title" % path)
    if not body.strip():
        raise ValueError("%s has no release notes" % path)


def set_missing_date(path, day):
    """Adds `date: <day>` to the front matter unless it has a date. Returns whether it changed."""
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", day):
        raise ValueError("dates look like 2026-10-29, not %r" % day)
    with open(path, encoding="utf-8") as handle:
        lines, body = split_front_matter(handle.read())
    if front_matter_value(lines, "date"):
        return False
    lines = [line for line in lines if not re.match(r"^date:", line)] + ["date: %s" % day]
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("---\n" + "\n".join(lines) + "\n---\n" + body)
    return True


# MARK: - sparkle.json


def parse_sign_update(attributes):
    """(edSignature, length) from sign_update's `sparkle:edSignature="…" length="…"`."""
    signature = re.search(r'sparkle:edSignature="([^"]+)"', attributes)
    length = re.search(r'\blength="(\d+)"', attributes)
    if not signature or not length:
        raise ValueError("sign_update gave no signature and length: %r" % attributes)
    return signature.group(1), int(length.group(1))


def make_sparkle_json(version, build, signature, length, minimum=MINIMUM_SYSTEM_VERSION):
    data = {
        "version": version,
        "build": build,
        "edSignature": signature,
        "length": length,
        "minimumSystemVersion": minimum,
    }
    return validate_sparkle_json(data, version)


def validate_sparkle_json(data, version):
    """Checks a release's sparkle.json; returns it with normalized types."""
    if not isinstance(data, dict):
        raise ValueError("sparkle.json isn't an object")
    if data.get("version") != version:
        raise ValueError("sparkle.json is for %r, not %r" % (data.get("version"), version))
    try:
        build = int(data.get("build"))
        length = int(data.get("length"))
        signature = base64.b64decode(str(data.get("edSignature", "")), validate=True)
    except (TypeError, ValueError) as error:
        raise ValueError("sparkle.json for %s is malformed: %s" % (version, error))
    if build < 1 or length < 1:
        raise ValueError("sparkle.json for %s needs a build and length above 0" % version)
    if len(signature) != 64:
        raise ValueError("sparkle.json for %s has no 64-byte EdDSA signature" % version)
    minimum = str(data.get("minimumSystemVersion") or "")
    if not re.match(r"^\d+(\.\d+){0,2}$", minimum):
        raise ValueError("sparkle.json for %s has no minimumSystemVersion" % version)
    return {
        "version": version,
        "build": build,
        "edSignature": data["edSignature"],
        "length": length,
        "minimumSystemVersion": minimum,
    }


# MARK: - The feed


def _request(url, token=None, accept="application/vnd.github+json"):
    headers = {"Accept": accept, "User-Agent": "ladle-release-feed", "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = "Bearer %s" % token
    return urllib.request.Request(url, headers=headers)


def fetch_json(url, token=None):
    with urllib.request.urlopen(_request(url, token), timeout=30) as response:
        return json.load(response)


def fetch_bytes(url):
    # Release downloads redirect to storage that refuses extra credentials, so no token here.
    request = urllib.request.Request(url, headers={"User-Agent": "ladle-release-feed"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def list_releases(repo, token=None):
    releases, page = [], 1
    while True:
        batch = fetch_json("%s/repos/%s/releases?per_page=100&page=%d" % (API, repo, page), token)
        if not isinstance(batch, list):
            raise ValueError("GitHub didn't return a list of releases")
        releases.extend(batch)
        if len(batch) < 100:
            return releases
        page += 1


def published_versions(releases):
    """(version, release) for published vX.Y.Z releases with Ladle.dmg and sparkle.json, newest first."""
    found = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        match = re.match(r"^v(\d+\.\d+\.\d+)$", release.get("tag_name") or "")
        names = {asset.get("name") for asset in release.get("assets") or []}
        if match and DMG in names and SPARKLE_JSON in names and release.get("published_at"):
            found.append((match.group(1), release))
    found.sort(key=lambda pair: version_key(pair[0]), reverse=True)
    return found


def _asset(release, name):
    return next(asset for asset in release["assets"] if asset.get("name") == name)


def _published_at(release):
    text = release["published_at"].replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(text).astimezone(datetime.timezone.utc)


def make_item(repo, version, info, published):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "Ladle %s" % version
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(published, usegmt=True)
    ET.SubElement(item, sparkle("version")).text = str(info["build"])
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = info["minimumSystemVersion"]
    ET.SubElement(item, sparkle("releaseNotesLink")).text = notes_link(version)
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", "https://github.com/%s/releases/download/v%s/%s" % (repo, version, DMG))
    enclosure.set("length", str(info["length"]))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(sparkle("edSignature"), info["edSignature"])
    return item


def build_feed(repo, appcast_path, changelog_dir, releases, fetch=None):
    """Writes the appcast and the missing release dates. Returns the versions in the feed."""
    fetch = fetch or fetch_bytes
    entries = []
    for version, release in published_versions(releases):
        info = validate_sparkle_json(json.loads(fetch(_asset(release, SPARKLE_JSON)["browser_download_url"])), version)
        size = _asset(release, DMG).get("size")
        if size is not None and int(size) != info["length"]:
            raise ValueError("sparkle.json for %s says %d bytes, but Ladle.dmg is %s" % (version, info["length"], size))
        entries.append((version, info, _published_at(release)))

    # Everything is fetched and checked before anything is written.
    tree = ET.parse(appcast_path)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("%s has no <channel>" % appcast_path)
    for item in channel.findall("item"):
        channel.remove(item)
    for version, info, published in entries[:KEEP_ITEMS]:
        channel.append(make_item(repo, version, info, published))
    ET.indent(tree, space="  ")
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
    with open(appcast_path, "a", encoding="utf-8") as handle:
        handle.write("\n")

    for version, _, published in entries:
        notes = os.path.join(changelog_dir, "%s.md" % version)
        if not os.path.exists(notes):
            print("note: %s has no release notes at %s" % (version, notes), file=sys.stderr)
        elif set_missing_date(notes, published.strftime("%Y-%m-%d")):
            print("dated the release notes for %s" % version)
    return [version for version, _, _ in entries[:KEEP_ITEMS]]


# MARK: - Command line


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    notes = commands.add_parser("check-notes")
    notes.add_argument("changelog")
    notes.add_argument("version")
    signed = commands.add_parser("sparkle-json")
    signed.add_argument("--version", required=True)
    signed.add_argument("--build", required=True, type=int)
    signed.add_argument("--attributes", required=True, help="sign_update's output for Ladle.dmg")
    signed.add_argument("--minimum-system-version", default=MINIMUM_SYSTEM_VERSION)
    signed.add_argument("--out", required=True)
    feed = commands.add_parser("feed")
    feed.add_argument("--repo", required=True, help="OWNER/NAME")
    feed.add_argument("--appcast", required=True)
    feed.add_argument("--changelog", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "check-notes":
            check_notes(args.changelog, args.version)
        elif args.command == "sparkle-json":
            signature, length = parse_sign_update(args.attributes)
            data = make_sparkle_json(args.version, args.build, signature, length, args.minimum_system_version)
            with open(args.out, "w", encoding="utf-8") as handle:
                json.dump(data, handle, indent=2)
                handle.write("\n")
        else:
            token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
            versions = build_feed(args.repo, args.appcast, args.changelog, list_releases(args.repo, token))
            print("appcast: %s" % (", ".join(versions) if versions else "no releases yet, empty channel"))
    except (OSError, ValueError, KeyError, StopIteration, ET.ParseError, urllib.error.URLError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
