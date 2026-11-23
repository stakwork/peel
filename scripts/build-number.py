#!/usr/bin/env python3
"""Reads or sets the build number (CURRENT_PROJECT_VERSION) of the iPhone or the Mac app.

  scripts/build-number.py ios|mac        prints it
  scripts/build-number.py ios|mac <N>    sets it

The number is a build setting of each target's configurations in
Apps/Peel.xcodeproj: the iPhone app and its notification extension (SDKROOT
iphoneos), which must move together, or the Mac app (SDKROOT macosx). Setting
the iPhone's also updates the number docs/phases/07-iphone.md quotes. Reading
fails when the configurations disagree. Used by .github/workflows/testflight.yml.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "Apps/Peel.xcodeproj/project.pbxproj")
PHONE_DOC = os.path.join(ROOT, "docs/phases/07-iphone.md")
SDK = {"ios": "iphoneos", "mac": "macosx"}
CONFIG = re.compile(r"isa = XCBuildConfiguration;.*?name = [^;]+;", re.S)
NUMBER = re.compile(r"(CURRENT_PROJECT_VERSION = )(\d+)(;)")


def configs(text, platform):
    """The spans of the platform's target configurations that carry a build number."""
    for match in CONFIG.finditer(text):
        block = match.group(0)
        if f"SDKROOT = {SDK[platform]};" in block and NUMBER.search(block):
            yield match.span()


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] not in SDK or (len(sys.argv) == 3 and not sys.argv[2].isdigit()):
        sys.exit("usage: scripts/build-number.py ios|mac [<N>]")
    platform = sys.argv[1]
    with open(PROJECT) as f:
        text = f.read()
    spans = list(configs(text, platform))
    if not spans:
        sys.exit(f"build-number: no {platform} configuration with CURRENT_PROJECT_VERSION in {PROJECT}")
    if len(sys.argv) == 2:
        numbers = {NUMBER.search(text[a:b]).group(2) for a, b in spans}
        if len(numbers) != 1:
            sys.exit(f"build-number: the {platform} configurations disagree: {sorted(numbers, key=int)}")
        print(numbers.pop())
        return
    number = sys.argv[2]
    # From the end, so the earlier spans stay where they are.
    for a, b in reversed(spans):
        text = text[:a] + NUMBER.sub(rf"\g<1>{number}\g<3>", text[a:b]) + text[b:]
    with open(PROJECT, "w") as f:
        f.write(text)
    if platform == "ios" and os.path.exists(PHONE_DOC):
        with open(PHONE_DOC) as f:
            doc = f.read()
        doc = re.sub(r"(`CURRENT_PROJECT_VERSION` is a copy of the app's \()\d+(\))", rf"\g<1>{number}\g<2>", doc)
        with open(PHONE_DOC, "w") as f:
            f.write(doc)


if __name__ == "__main__":
    main()
