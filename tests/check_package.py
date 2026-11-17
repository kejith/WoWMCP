"""Checks a packaged addon zip: python tests/check_package.py <zip> [<zip> ...]

The zip must hold exactly one folder named like the addon, with the .toc and every file the .toc lists,
and nothing the game does not load. Addon managers and the desktop app rely on this layout.
"""

import glob
import os
import sys
import zipfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
NAME = os.path.splitext(os.path.basename(glob.glob(os.path.join(ROOT, "*.toc"))[0]))[0]
NOT_SHIPPED = ("tests/", ".github/", "README.md", ".pkgmeta", ".git")


def check(path):
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None, "corrupt entry"
        names = [n for n in z.namelist() if not n.endswith("/")]
        prefix = f"{NAME}/"
        outside = [n for n in names if not n.startswith(prefix)]
        assert not outside, f"files outside {prefix}: {outside}"
        inner = [n[len(prefix):] for n in names]
        assert f"{NAME}.toc" in inner, f"{NAME}.toc is missing"
        toc = z.read(f"{prefix}{NAME}.toc").decode("utf-8-sig")
        listed = [line.strip().replace("\\", "/") for line in toc.splitlines()
                  if line.strip() and not line.strip().startswith("#")]
        missing = [f for f in listed if f not in inner]
        assert not missing, f"listed in the .toc but not in the zip: {missing}"
        extra = [n for n in inner if n.startswith(NOT_SHIPPED)]
        assert not extra, f"development files in the zip: {extra}"
        version = next(line.split(":", 1)[1].strip() for line in toc.splitlines() if line.startswith("## Version:"))
    print(f"ok {os.path.basename(path)}: {NAME} {version}, {len(inner)} files")


if __name__ == "__main__":
    paths = [p for arg in sys.argv[1:] for p in (glob.glob(arg) or [arg])]
    if not paths:
        sys.exit("no zip given")
    for p in paths:
        check(p)
