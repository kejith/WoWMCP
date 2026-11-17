# /// script
# requires-python = ">=3.11"
# dependencies = ["lupa>=2.0"]
# ///
"""Lädt jede Lua-Datei aus der .toc in Lua 5.4, ohne sie auszuführen. Findet Syntaxfehler, mehr nicht:
das Spiel selbst läuft mit Lua 5.1 und eigener API.

    uv run tests/check_syntax.py
"""

import os
import sys

from lupa.lua54 import LuaRuntime

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def toc_files() -> list[str]:
    toc = next(f for f in os.listdir(ROOT) if f.endswith(".toc"))
    lines = (line.strip() for line in open(os.path.join(ROOT, toc), encoding="utf-8"))
    return [line for line in lines if line and not line.startswith("#")]


if __name__ == "__main__":
    load = LuaRuntime(register_eval=False).eval("function(src, name) return load(src, name) end")
    failed = False
    for name in toc_files():
        path = os.path.join(ROOT, name)
        if not os.path.exists(path):
            print(f"FEHLT {name} (steht in der .toc)")
            failed = True
            continue
        result = load(open(path, encoding="utf-8").read(), name)
        chunk, error = result if isinstance(result, tuple) else (result, None)
        if chunk is None:
            print(f"FEHLER {error}")
            failed = True
        else:
            print(f"ok {name}")
    sys.exit(1 if failed else 0)
