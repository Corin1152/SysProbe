#!/bin/bash
# 核对两份 Localizable.strings。
#
#   bash scripts/check-localization.sh
#
# 文案的唯一来源就是这两份文件（键是英文原文）。它们同时被 SwiftUI（按环境 locale
# 去 .lproj 里挑）和 `Strings.text`（直接查 .lproj）使用，所以「键集合一致、没有重复
# 键、中英占位符数量一致」是硬要求 —— 少一条就是某处静默显示英文，或者 String(format:)
# 直接崩。
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

ROOT = pathlib.Path("Sources/Shared/Localization")
LANGS = ["en", "zh-Hans"]
PAIR = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|f|s)")

tables = {}
for lang in LANGS:
    path = ROOT / f"{lang}.lproj" / "Localizable.strings"
    if not path.is_file():
        print(f"::error::{path} is missing")
        sys.exit(1)
    entries = {}
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.startswith('"'):
            continue
        m = PAIR.match(line)
        if not m:
            print(f"::error::{path}:{lineno}: cannot parse {line!r}")
            sys.exit(1)
        key, value = m.group(1), m.group(2)
        if key in entries:
            print(f"::error::{path}:{lineno}: duplicate key {key!r}")
            sys.exit(1)
        entries[key] = value
    if len(entries) < 150:
        print(f"::error::{path}: only {len(entries)} entries, expected the whole UI")
        sys.exit(1)
    tables[lang] = entries
    print(f"{lang}: {len(entries)} entries")

base = tables[LANGS[0]]
for lang in LANGS[1:]:
    other = tables[lang]
    for key in sorted(set(base) - set(other)):
        print(f"::error::{lang}.lproj is missing {key!r}")
    for key in sorted(set(other) - set(base)):
        print(f"::error::{lang}.lproj has an extra key {key!r}")

bad = 0
for key, value in tables["zh-Hans"].items():
    if len(SPEC.findall(key)) != len(SPEC.findall(value)):
        print(f"::error::placeholder count differs for {key!r} -> {value!r}")
        bad += 1
if bad:
    sys.exit(1)

print("localization OK")
PY
