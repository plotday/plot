#!/usr/bin/env python3
"""Inline original source text into dart2js web source maps.

`flutter build web --source-maps` emits `main.dart.js.map` with a `sources`
list but no `sourcesContent`. PostHog (and any source-map consumer) can then
resolve a minified frame to `file:line:function`, but has no code to display —
issues show the right location with an empty source pane.

This script reads each referenced source file from disk and embeds its text in
the map's `sourcesContent` array, so PostHog Error Tracking shows real code.
Run it after `flutter build web --source-maps` and before the source maps are
uploaded (e.g. `posthog-cli sourcemap upload`).

Resolution is semantic, not by `../` depth (dart2js bakes paths relative to a
deeper notional dir, so spec-relative joins miss):

  - `<...>/.pub-cache/<rest>`        -> $PUB_CACHE/<rest>           (pub packages)
  - `<...>/fvm/versions/<v>/<rest>`  -> $FLUTTER_ROOT/<rest>        (Flutter SDK via fvm)
  - `<...>/packages/flutter/<rest>`  -> $FLUTTER_ROOT/packages/...  (Flutter SDK, non-fvm)
  - `org-dartlang-sdk:///dart-sdk/x` -> $FLUTTER_ROOT/bin/cache/dart-sdk/x
  - other `org-dartlang-sdk:///`     -> skipped (engine internals, not on disk)
  - everything else (our app code)   -> <app-root>/<path after leading ../>

Sources that can't be resolved get a null entry, which is valid per the source
map spec — the consumer just won't show text for that frame.

Usage: inline-web-source-content.py <build/web dir>
"""

import json
import os
import re
import sys


def resolve(source, app_root, pub_cache, flutter_root):
    """Map a source-map `sources` entry to a local file path, or None."""
    # Flutter engine + dart: SDK internals.
    if source.startswith("org-dartlang-sdk:"):
        prefix = "org-dartlang-sdk:///dart-sdk/"
        if source.startswith(prefix) and flutter_root:
            return os.path.join(flutter_root, "bin", "cache", "dart-sdk", source[len(prefix):])
        return None  # _engine / ui internals are not present on disk

    # pub.dev / hosted / git packages.
    if "/.pub-cache/" in source and pub_cache:
        return os.path.join(pub_cache, source.split("/.pub-cache/", 1)[1])

    # Flutter framework when installed via fvm (…/fvm/versions/<ver>/<rest>).
    m = re.search(r"/fvm/versions/[^/]+/(.+)$", source)
    if m and flutter_root:
        return os.path.join(flutter_root, m.group(1))

    # Flutter framework, non-fvm layout (…/packages/flutter/<rest>).
    if flutter_root:
        idx = source.find("packages/flutter/")
        if idx != -1:
            return os.path.join(flutter_root, source[idx:])

    # Our app code (and third_party/): strip leading ../ and anchor at app root.
    return os.path.join(app_root, re.sub(r"^(\.\./)+", "", source))


def inline(map_path, flutter_root, pub_cache):
    with open(map_path, encoding="utf-8") as f:
        data = json.load(f)

    sources = data.get("sources") or []
    if not sources:
        return 0, 0

    # build/web/main.dart.js.map -> app root is two dirs up from build/web.
    map_dir = os.path.dirname(os.path.abspath(map_path))
    app_root = os.path.dirname(os.path.dirname(map_dir))

    content = []
    filled = 0
    for source in sources:
        path = resolve(source, app_root, pub_cache, flutter_root)
        text = None
        if path and os.path.isfile(path):
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
                filled += 1
            except OSError:
                text = None
        content.append(text)

    data["sourcesContent"] = content
    with open(map_path, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"))
    return filled, len(sources)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: inline-web-source-content.py <build/web dir>")

    build_dir = sys.argv[1]
    flutter_root = os.environ.get("FLUTTER_ROOT")
    pub_cache = os.environ.get("PUB_CACHE") or os.path.expanduser("~/.pub-cache")

    maps = []
    for root, _dirs, files in os.walk(build_dir):
        for name in files:
            if name.endswith(".js.map"):
                maps.append(os.path.join(root, name))

    if not maps:
        print(f"inline-web-source-content: no .js.map files under {build_dir}", file=sys.stderr)
        return

    for map_path in maps:
        filled, total = inline(map_path, flutter_root, pub_cache)
        print(f"inline-web-source-content: {os.path.relpath(map_path, build_dir)} "
              f"-> embedded {filled}/{total} sources")


if __name__ == "__main__":
    main()
