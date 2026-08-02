#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "miuread.koplugin"
DIST = ROOT / "dist"
DEFAULT_REPOSITORY = (ROOT / "REPOSITORY").read_text(encoding="utf-8").strip()

CHANNEL_RULES = {
    "beta": {
        "branch": "beta",
        "manifest": "update-beta.json",
        "label": "内测通道",
        "version_re": r"^\d+\.\d+\.\d+-beta\.\d+$",
        "manifest_url": "https://raw.githubusercontent.com/{repo}/beta/update-beta.json",
    },
    "stable": {
        "branch": "main",
        "manifest": "update.json",
        "label": "正式通道",
        "version_re": r"^\d+\.\d+\.\d+$",
        "manifest_url": "https://raw.githubusercontent.com/{repo}/main/update.json",
    },
}

EXCLUDED_PARTS = {".git", "dist", "__pycache__", ".pytest_cache", ".mypy_cache"}
EXCLUDED_NAMES = {".DS_Store", "Thumbs.db"}


def fail(message: str) -> None:
    raise SystemExit(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def zip_tree(source: Path, target: Path, prefix: str | None = None) -> None:
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in sorted(source.rglob("*"), key=lambda p: p.as_posix()):
            rel = path.relative_to(source)
            if any(part in EXCLUDED_PARTS for part in rel.parts):
                continue
            if path.name in EXCLUDED_NAMES or path.suffix == ".pyc" or path.is_dir():
                continue
            arc = Path(prefix) / rel if prefix else rel
            info = zipfile.ZipInfo(arc.as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IMODE(path.stat().st_mode) & 0xFFFF) << 16
            zf.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def check_lua_syntax() -> tuple[int, str]:
    lua_files = sorted(PLUGIN.rglob("*.lua"))
    if not lua_files:
        fail("没有找到 Lua 文件")
    interpreters = ["luac", "luac5.1", "luajit"]
    executable = next((shutil.which(x) for x in interpreters if shutil.which(x)), None)
    if executable:
        for path in lua_files:
            if Path(executable).name.startswith("luac"):
                cmd = [executable, "-p", str(path)]
            else:
                cmd = [executable, "-b", str(path), os.devnull]
            proc = subprocess.run(cmd, text=True, capture_output=True)
            if proc.returncode:
                fail(f"Lua 语法检查失败：{path}\n{proc.stderr or proc.stdout}")
        return len(lua_files), Path(executable).name
    return len(lua_files), "未找到 luac/luajit，已完成结构与版本检查"


def validate(channel: str) -> tuple[str, dict, int, str]:
    rule = CHANNEL_RULES[channel]
    version = read(ROOT / "VERSION").strip()
    declared_channel = read(ROOT / "CHANNEL").strip()
    if declared_channel != channel:
        fail(f"CHANNEL={declared_channel}，但请求构建 {channel}")
    if not re.fullmatch(rule["version_re"], version):
        fail(f"版本号不符合 {channel} 规则：{version}")

    config = read(PLUGIN / "miuread" / "config.lua")
    meta = read(PLUGIN / "_meta.lua")
    changelog = read(PLUGIN / "CHANGELOG.md")
    expected_manifest = rule["manifest_url"].format(repo=DEFAULT_REPOSITORY)

    checks = {
        f'VERSION = "{version}"': config,
        f'UPDATE_CHANNEL = "{channel}"': config,
        f'UPDATE_CHANNEL_LABEL = "{rule["label"]}"': config,
        f'UPDATE_MANIFEST = "{expected_manifest}"': config,
        f'version = "{version}"': meta,
    }
    missing = [needle for needle, haystack in checks.items() if needle not in haystack]
    if missing:
        fail("版本或通道标识不一致：\n- " + "\n- ".join(missing))
    if not changelog.startswith(f"# {version}\n"):
        fail("CHANGELOG.md 首行版本与 VERSION 不一致")
    if "3.5.0-beta.16" in config or "3.5.0-beta.16" in meta:
        fail("运行代码仍残留旧版本号")

    forbidden = []
    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT)
        if any(part == ".git" for part in rel.parts) or path.name in EXCLUDED_NAMES or path.suffix == ".pyc":
            forbidden.append(rel.as_posix())
    if forbidden:
        fail("发现不应打包的文件：\n- " + "\n- ".join(forbidden))

    lua_count, lua_tool = check_lua_syntax()
    return version, rule, lua_count, lua_tool


def release_notes(version: str, channel: str) -> str:
    title = f"觅阅 {version}" + ("（内测）" if channel == "beta" else "")
    body = read(ROOT / "RELEASE_NOTES.md").strip()
    return f"# {title}\n\n{body}\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", choices=sorted(CHANNEL_RULES), required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    version, rule, lua_count, lua_tool = validate(args.channel)
    print(f"版本检查通过：{version} / {args.channel}")
    print(f"Lua 文件：{lua_count}；检查方式：{lua_tool}")
    if args.check_only:
        return

    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)

    full_name = f"miuread-v{version}-full.zip"
    source_name = f"miuread-v{version}-repository-code.zip"
    notes_name = f"RELEASE_NOTES-v{version}.md"
    manifest_name = rule["manifest"]

    full_path = DIST / full_name
    zip_tree(PLUGIN, full_path, prefix="miuread.koplugin")
    full_hash = sha256(full_path)
    full_size = full_path.stat().st_size

    repository = os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPOSITORY).strip() or DEFAULT_REPOSITORY
    url = f"https://github.com/{repository}/releases/download/v{version}/{full_name}"
    notes_lines = [line.strip()[2:] for line in read(PLUGIN / "CHANGELOG.md").splitlines() if line.strip().startswith("- ")]
    notes = "\n".join(f"- {line}" for line in notes_lines[:4])
    manifest = {
        "name": f"觅阅 {version}",
        "version": version,
        "channel": args.channel,
        "package_type": "full",
        "package_url": url,
        "sha256": full_hash,
        "size": full_size,
        "published_at": os.environ.get("RELEASE_DATE") or datetime.now(timezone.utc).date().isoformat(),
        "summary": notes_lines[0] if notes_lines else f"觅阅 {version}",
        "notes": notes,
    }
    manifest_text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    (DIST / manifest_name).write_text(manifest_text, encoding="utf-8", newline="\n")
    (ROOT / manifest_name).write_text(manifest_text, encoding="utf-8", newline="\n")

    notes_text = release_notes(version, args.channel)
    (DIST / notes_name).write_text(notes_text, encoding="utf-8", newline="\n")

    source_prefix = f"miuread-v{version}-repository-code"
    source_path = DIST / source_name
    zip_tree(ROOT, source_path, prefix=source_prefix)

    checksums = []
    for path in sorted(DIST.iterdir(), key=lambda p: p.name):
        if path.is_file() and path.name != "SHA256SUMS.txt":
            checksums.append(f"{sha256(path)}  {path.name}")
    (DIST / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="utf-8", newline="\n")

    print(f"已生成：{full_path.name}")
    print(f"已生成：{source_path.name}")
    print(f"已生成：{manifest_name}")


if __name__ == "__main__":
    main()
