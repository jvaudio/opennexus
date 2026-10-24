#!/usr/bin/env python3
"""Adds a release to OpenNexus's Sparkle update feed, appcast.xml (M38, D276).

The feed lists every release, newest first; Sparkle offers the newest one the Mac can
run, from the channels the user allows (Settings › General › Updates). A build that's
already listed is replaced, so a release can be rebuilt. Called by App/tools/release.sh:

    appcast.py --feed appcast.xml --version 0.2 --build 120 \\
        --url https://github.com/jvaudio/opennexus/releases/download/v0.2/OpenNexus-0.2.dmg \\
        --signed 'sparkle:edSignature="…" length="…"' [--channel beta] [--notes-link URL]
"""
import argparse
import email.utils
import os
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
MINIMUM_SYSTEM = "27.0"


def q(tag):
    return f"{{{SPARKLE}}}{tag}"


def empty_feed():
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "OpenNexus"
    ET.SubElement(channel, "link").text = "https://github.com/jvaudio/opennexus"
    ET.SubElement(channel, "description").text = "OpenNexus updates"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--feed", required=True)
    a.add_argument("--version", required=True)
    a.add_argument("--build", required=True)
    a.add_argument("--url", required=True)
    a.add_argument("--signed", required=True, help="sign_update's output")
    a.add_argument("--channel")
    a.add_argument("--notes-link")
    args = a.parse_args()

    attrs = dict(re.findall(r'([\w:]+)="([^"]*)"', args.signed))
    signature, length = attrs.get("sparkle:edSignature"), attrs.get("length")
    if not signature or not length:
        raise SystemExit(f"appcast: no signature and length in sign_update's output: {args.signed!r}")

    tree = ET.parse(args.feed) if os.path.exists(args.feed) else empty_feed()
    channel = tree.getroot().find("channel")
    for old in channel.findall("item"):
        if old.findtext(q("version")) == args.build:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"OpenNexus {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, q("version")).text = args.build
    ET.SubElement(item, q("shortVersionString")).text = args.version
    ET.SubElement(item, q("minimumSystemVersion")).text = MINIMUM_SYSTEM
    if args.channel:
        ET.SubElement(item, q("channel")).text = args.channel
    if args.notes_link:
        # Opens in the browser: OpenNexus itself loads nothing from the network.
        ET.SubElement(item, q("fullReleaseNotesLink")).text = args.notes_link
    ET.SubElement(item, "description").text = (
        f"<p>OpenNexus {args.version} is available.</p>"
        + (f'<p><a href="{args.notes_link}">What’s new</a></p>' if args.notes_link else "")
    )
    ET.SubElement(item, "enclosure", {
        "url": args.url, q("edSignature"): signature, "length": length, "type": "application/octet-stream",
    })

    # Newest first, after the channel's own elements.
    first = next((i for i, e in enumerate(channel) if e.tag == "item"), len(channel))
    channel.insert(first, item)
    ET.indent(tree, space="  ")
    tree.write(args.feed, encoding="utf-8", xml_declaration=True)
    with open(args.feed, "a") as f:
        f.write("\n")
    print(f"appcast: {args.feed} now lists {len(channel.findall('item'))} release(s); newest {args.version} ({args.build})")


if __name__ == "__main__":
    main()
