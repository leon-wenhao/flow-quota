#!/usr/bin/env python3
"""Offline release metadata for the public binary repository (Python 3.9+).

Only version/build/minimumSystemVersion are read from the source build manifest.
The publisher must upload validate_bundle's explicit paths, never a directory glob.
SHA256 uses incremental update: https://docs.python.org/3.9/library/hashlib.html
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import sys
import sparkle_feed


ARCHITECTURES = ("arm64", "x86_64")
METADATA = ("SHA256SUMS", "update-manifest.json", "release-manifest.json", "RELEASE-NOTES.md", *sparkle_feed.FEEDS)
CHUNK_SIZE = 1024 * 1024
MAX_INT = 2**63 - 1
NUMBER = r"(?:0|[1-9][0-9]*)"
VERSION = NUMBER + r"\." + NUMBER + r"\." + NUMBER


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _keys(value, names):
    _require(isinstance(value, dict) and set(value) == set(names), "Unexpected manifest fields")


def _identity(version, build, minimum):
    _require(isinstance(version, str) and re.fullmatch(VERSION, version), "Invalid version")
    _require(all(int(part) <= MAX_INT for part in version.split(".")), "Version out of range")
    _require(type(build) is int and 0 < build <= MAX_INT, "Invalid build")
    _require(isinstance(minimum, str) and re.fullmatch(NUMBER + r"\." + NUMBER +
             r"(?:\." + NUMBER + r")?", minimum), "Invalid minimumSystemVersion")
    _require(all(int(part) <= MAX_INT for part in minimum.split(".")), "System version out of range")


def _urls(repo, version, build):
    _require(isinstance(repo, str) and re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9_.-]*", repo),
        "Invalid repository; expected OWNER/REPO")
    root = "https://github.com/{}/releases".format(repo)
    tag = "v{}".format(version)
    return root + "/tag/" + tag, root + "/download/" + tag + "/"


def _files(output):
    _require(not output.is_symlink() and output.is_dir(), "Output must be a real directory")
    paths = list(output.iterdir())
    _require(all(stat.S_ISREG(path.lstat().st_mode) for path in paths),
             "Bundle contains a symlink or non-regular file")
    return {path.name for path in paths}


def _names(version):
    return ["FlowQuota-{}-{}.dmg".format(version, arch) for arch in ARCHITECTURES]


def _asset(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK_SIZE), b""):
            size += len(chunk)
            digest.update(chunk)
    _require(0 < size <= 2 * 1024**3, "DMG size outside client limits")
    return {"file": path.name, "size": size, "sha256": digest.hexdigest()}


def _read_json(path):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            _require(key not in result, "Duplicate JSON field")
            result[key] = value
        return result

    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    _require(isinstance(value, dict), "Manifest must be a JSON object")
    return value


def _write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _checksums(assets):
    return "".join("{}  {}\n".format(asset["sha256"], asset["file"]) for asset in assets)


def _notes(version, build, minimum):
    # Fixed user-facing notes keep local build paths out of release attachments.
    return """# {version}

## 功能概述

Flow Quota 在 macOS 菜单栏提供流量采样统计、应用用量分析和分时图表，
分别统计普通网络与热点／高成本网络，支持每日阈值和短时大流量预警。
达到阈值时只发送通知，不阻断连接。统计仅覆盖服务运行期间观测到的增量，
应用归因可能重叠，不等同于接口总量或运营商账单。

## 本次更新

- 手动热点开关移至“通用设置 → 网络分类修正”，默认收起；菜单栏概览保留当前网络状态，仍可在识别不准时手动修正或取消标记。
- 用量图表增加所选时段的全部来源排行，上传、下载条形与双饼图共用相同数据；调整窗口大小及图表间距，较多来源可滚动查看。
- 退出时显示停止采集进度，并暂停界面轮询；服务连接中断或超时后尝试系统注销，等待确认。无法确认时保留原因及返回应用选项。
- VPN／代理来源明细目前仅支持 Clash／Mihomo，实际接入 Clash Verge 本地接口；其他 VPN 不会自动出现同类应用或站点拆分，普通接口和进程采样仍按可观测范围统计。
- 修复 DMG 打包暂存目录可能被编辑器跟随 Applications 链接索引的问题，增加打包中断清理。

Clash 用量继续完整拆分为已识别来源及“其他未识别（Clash）”，父项不重复加入排名。
当天来源分钟汇总在服务重启后仍保留，原始计数可在用量详情查看。
预警保留触发当时的来源快照；应用／服务阈值仍按原始应用或 Clash 内核整体判断，子来源不产生独立额度。

Mac 总流量继续由单一物理接口独立统计，来源识别失败不削减总量。
Clash 按分钟核对上传和下载，无法核对的分钟完整保留为其他未识别，不缩放或裁剪来凑数。
物理接口与应用计数仍可能存在时间及协议差异，不能保证每个接口字节唯一还原到应用。
统计只覆盖有效观测区间，启动、暂停、重启或采样间断期间的未知流量不补算。

## 系统与安装包

- 最低系统：macOS {minimum}。
- Apple silicon：FlowQuota-{version}-arm64.dmg（arm64）。
- Intel：FlowQuota-{version}-x86_64.dmg（x86_64）。
- 签名：本地 ad-hoc 签名，尚未完成 Apple 公证（notarized: false）。

## 首次打开

打开适合本机架构的 DMG，将左侧 Flow Quota 拖入右侧 Applications 后启动。
安装窗口提供拖拽箭头，底部可查看安装提示及“安装说明.txt”。
由于此版本使用 ad-hoc 签名且未公证，macOS 可能提示无法验证开发者。
确认下载来源可信后，在“系统设置 → 隐私与安全性”中使用系统提供的
“仍要打开”，按系统提示确认。本文不提供绕过安全检查的命令；
如果系统未提供该选项或仍拒绝启动，请保留提示信息并反馈。
首次使用时允许通知；通知权限失败可在应用中查看。

## 后续更新

在应用中点击“检查更新”，确认后下载安装并自动替换、重启，无需再次拖拽。
更新源和安装包使用 Ed25519 签名校验；不在后台自动检查或下载。
旧版若仍提示打开 DMG，请手动安装一次本版本，之后可使用应用内替换。
""".format(version=version, build=build, minimum=minimum)


def prepare_bundle(output, source_manifest, repo, version, build, source_commit):
    """Generate six public metadata files beside two existing DMGs, then validate.

    Raises ValueError/OSError for invalid inputs; signs using the local Keychain,
    verifies using the committed public key; does not build or upload anything.
    Source identity must match the explicit release arguments. Other source fields
    are intentionally never copied. Only the explicit source_commit is recorded for tag verification.
    """
    _require(isinstance(source_commit, str) and re.fullmatch(r"[0-9a-f]{40}", source_commit),
             "Invalid source commit")
    output = Path(output)
    source = _read_json(Path(source_manifest))
    minimum = source.get("minimumSystemVersion")
    _identity(version, build, minimum)
    _require(source.get("version") == version and type(source.get("build")) is int
             and source["build"] == build, "Source version/build mismatch")
    release_url, download_root = _urls(repo, version, build)
    names = _names(version)
    present = _files(output)
    _require(set(names) <= present <= set(names + list(METADATA)),
             "Missing DMG or unexpected bundle file")
    assets = [_asset(output / name) for name in names]
    packages = {
        "macos/" + arch: {"format": "dmg", "fileName": asset["file"],
                          "url": download_root + asset["file"],
                          "size": asset["size"], "sha256": asset["sha256"]}
        for arch, asset in zip(ARCHITECTURES, assets)
    }
    manifest = {
        "schemaVersion": 2, "product": "flow-quota", "channel": "stable",
        "version": version, "build": build, "minimumSystemVersion": minimum,
        "releaseNotesURL": release_url, "downloadURL": release_url,
        "publishedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "packages": packages,
    }
    release = {"version": version, "build": build, "releaseURL": release_url,
               "minimumSystemVersion": minimum, "assets": assets,
               "signing": "ad-hoc", "notarized": False, "sourceCommit": source_commit}
    _write_json(output / "update-manifest.json", manifest)
    _write_json(output / "release-manifest.json", release)
    (output / "SHA256SUMS").write_text(_checksums(assets), encoding="utf-8")
    (output / "RELEASE-NOTES.md").write_text(_notes(version, build, minimum), encoding="utf-8")
    sparkle_feed.prepare(output, manifest)
    return validate_bundle(output, repo)


def validate_bundle(output, repo):
    """Return (schema-2 update dict, eight explicit Path objects) for a valid bundle.

    Raises ValueError/OSError on failure. All paths are regular files from a fixed
    allowlist; callers must keep the directory unchanged between validation/upload.
    This checks offline metadata integrity, not DMG architecture or code signing.
    """
    output = Path(output)
    present = _files(output)
    _require("update-manifest.json" in present, "Missing update-manifest.json")
    manifest = _read_json(output / "update-manifest.json")
    _keys(manifest, ("schemaVersion", "product", "channel", "version", "build",
                     "minimumSystemVersion", "releaseNotesURL", "downloadURL",
                     "publishedAt", "packages"))
    version, build, minimum = (manifest[key] for key in ("version", "build", "minimumSystemVersion"))
    _identity(version, build, minimum)
    release_url, download_root = _urls(repo, version, build)
    names = _names(version)
    _require(present == set(names + list(METADATA)), "Missing or unexpected bundle files")
    _require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 2
             and manifest["product"] == "flow-quota" and manifest["channel"] == "stable",
             "Unsupported update schema/product/channel")
    _require(manifest["releaseNotesURL"] == release_url and manifest["downloadURL"] == release_url,
             "Release URL must match repository and build tag")
    published = manifest["publishedAt"]
    _require(isinstance(published, str), "Invalid publication timestamp")
    _require(datetime.strptime(published, "%Y-%m-%dT%H:%M:%SZ").strftime(
        "%Y-%m-%dT%H:%M:%SZ") == published, "Invalid publication timestamp")
    packages = manifest["packages"]
    _keys(packages, ["macos/" + arch for arch in ARCHITECTURES])
    assets = []
    for arch, name in zip(ARCHITECTURES, names):
        package = packages["macos/" + arch]
        _keys(package, ("format", "fileName", "url", "size", "sha256"))
        _require(package["format"] == "dmg" and package["fileName"] == name
                 and package["url"] == download_root + name, "Invalid package path/URL/architecture")
        _require(type(package["size"]) is int and package["size"] > 0, "Invalid package size")
        _require(isinstance(package["sha256"], str) and
                 re.fullmatch(r"[0-9a-f]{64}", package["sha256"]), "Invalid SHA-256 digest")
        asset = _asset(output / name)
        _require(package["size"] == asset["size"] and package["sha256"] == asset["sha256"],
                 "DMG size/digest mismatch")
        assets.append(asset)
    release = _read_json(output / "release-manifest.json")
    _keys(release, ("version", "build", "releaseURL", "minimumSystemVersion", "assets",
                    "signing", "notarized", "sourceCommit"))
    source_commit = release["sourceCommit"]
    _require(isinstance(source_commit, str) and re.fullmatch(r"[0-9a-f]{40}", source_commit),
             "Invalid source commit")
    _require(type(release["build"]) is int and release["notarized"] is False,
             "Invalid release build/notarization")
    _require(isinstance(release["assets"], list) and len(release["assets"]) == 2,
             "Expected two release assets")
    for asset in release["assets"]:
        _keys(asset, ("file", "size", "sha256"))
        _require(type(asset["size"]) is int, "Invalid release asset size")
    _require(release == {"version": version, "build": build, "releaseURL": release_url,
                        "minimumSystemVersion": minimum, "assets": assets,
                        "signing": "ad-hoc", "notarized": False, "sourceCommit": source_commit},
             "Release manifest mismatch")
    _require((output / "SHA256SUMS").read_text(encoding="utf-8") == _checksums(assets),
             "SHA256SUMS mismatch")
    _require((output / "RELEASE-NOTES.md").read_text(encoding="utf-8") == _notes(version, build, minimum),
             "Release notes differ from public template")
    sparkle_feed.validate(output, manifest)
    return manifest, [output / name for name in names + list(METADATA)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("prepare", "validate"):
        child = commands.add_parser(command)
        child.add_argument("--output", required=True, type=Path)
        child.add_argument("--repo", required=True)
        if command == "prepare":
            child.add_argument("--source-manifest", required=True, type=Path)
            child.add_argument("--source-commit", required=True)
            child.add_argument("--version", required=True)
            child.add_argument("--build", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            _require(re.fullmatch(r"[1-9][0-9]*", args.build), "Invalid build")
            manifest, assets = prepare_bundle(args.output, args.source_manifest, args.repo,
                                              args.version, int(args.build), args.source_commit)
        else:
            manifest, assets = validate_bundle(args.output, args.repo)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, "release bundle: {}\n".format(error))
    print("Validated v{}: {} assets".format(manifest["version"], len(assets)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
