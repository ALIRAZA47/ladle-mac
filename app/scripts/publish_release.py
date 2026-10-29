#!/usr/bin/env python3
"""Release bookkeeping for the app's release workflow (.github/workflows/app-release.yml).

  publish_release.py check-notes   <changelog.md> <version>
  publish_release.py set-date      <changelog.md> <YYYY-MM-DD>
  publish_release.py appcast       <appcast.xml> --version 1.2.0 --build 3 --url URL
                                   --length BYTES --signature ED_SIGNATURE [--date RFC2822]

`appcast` adds (or replaces) the item for a version in Sparkle's RSS feed, newest first, and keeps
the most recent items. Each item's release notes link is the changelog anchor, e.g. #v1-2-0.
Standard library only, so it runs on any runner.
"""

import argparse
import email.utils
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SITE = "https://ladle.alirazakhan.me"
MINIMUM_SYSTEM_VERSION = "14.0"
KEEP_ITEMS = 10

ET.register_namespace("sparkle", SPARKLE_NS)


def sparkle(tag):
    return "{%s}%s" % (SPARKLE_NS, tag)


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def notes_link(version):
    """https://ladle.alirazakhan.me/changelog/#v1-0-0"""
    return "%s/changelog/#v%s" % (SITE, version.replace(".", "-"))


# MARK: - Changelog


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


def set_date(path, day):
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", day):
        raise ValueError("dates look like 2026-10-29, not %r" % day)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    lines, body = split_front_matter(text)
    lines = [line for line in lines if not re.match(r"^date:", line)]
    lines.append("date: %s" % day)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("---\n" + "\n".join(lines) + "\n---\n" + body)


# MARK: - Appcast


def item_version(item):
    element = item.find(sparkle("shortVersionString"))
    if element is not None and element.text:
        return element.text.strip()
    enclosure = item.find("enclosure")
    if enclosure is not None:
        return enclosure.get(sparkle("shortVersionString"))
    return None


def make_item(version, build, url, length, signature, date):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "Ladle %s" % version
    ET.SubElement(item, "pubDate").text = date
    ET.SubElement(item, sparkle("version")).text = str(build)
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = MINIMUM_SYSTEM_VERSION
    ET.SubElement(item, sparkle("releaseNotesLink")).text = notes_link(version)
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", url)
    enclosure.set("length", str(length))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(sparkle("edSignature"), signature)
    return item


def update_appcast(path, version, build, url, length, signature, date=None):
    if not re.match(r"^\d+\.\d+\.\d+$", version):
        raise ValueError("versions look like 1.2.0, not %r" % version)
    if int(length) <= 0 or not signature:
        raise ValueError("the update needs its length and EdDSA signature")
    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("%s has no <channel>" % path)
    items = [item for item in channel.findall("item") if item_version(item) != version]
    for item in channel.findall("item"):
        channel.remove(item)
    items.append(make_item(version, build, url, length, signature, date or email.utils.formatdate(usegmt=True)))
    items.sort(key=lambda item: version_key(item_version(item) or "0"), reverse=True)
    for item in items[:KEEP_ITEMS]:
        channel.append(item)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    notes = commands.add_parser("check-notes")
    notes.add_argument("changelog")
    notes.add_argument("version")
    dated = commands.add_parser("set-date")
    dated.add_argument("changelog")
    dated.add_argument("date")
    feed = commands.add_parser("appcast")
    feed.add_argument("appcast")
    feed.add_argument("--version", required=True)
    feed.add_argument("--build", required=True, type=int)
    feed.add_argument("--url", required=True)
    feed.add_argument("--length", required=True, type=int)
    feed.add_argument("--signature", required=True)
    feed.add_argument("--date")
    args = parser.parse_args(argv)
    try:
        if args.command == "check-notes":
            check_notes(args.changelog, args.version)
        elif args.command == "set-date":
            set_date(args.changelog, args.date)
        else:
            update_appcast(args.appcast, args.version, args.build, args.url, args.length, args.signature, args.date)
    except (OSError, ValueError, ET.ParseError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
