"""Signed, architecture-specific Sparkle feeds. Private keys never enter Python."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)
FEEDS = ("appcast-arm64.xml", "appcast-x86_64.xml")
ACCOUNT = "local.flowquota.app"
SIGNATURE = re.compile(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*\Z")


def public_key():
    return plistlib.loads((ROOT / "macos/Configuration/Info.plist").read_bytes())["SUPublicEDKey"]


def signature_value(value):
    try:
        if not isinstance(value, str) or len(base64.b64decode(value, validate=True)) != 64:
            raise ValueError("Invalid Ed25519 signature")
    except Exception as error:
        raise ValueError("Invalid Ed25519 signature") from error
    return value


def signer():
    return subprocess.check_output([str(ROOT / "scripts/sparkle-tools.sh")], text=True).strip()


def sign_archive(path, tool):
    return signature_value(subprocess.check_output(
        [tool, "--account", ACCOUNT, "-p", str(path)], text=True).strip())


INSTALL_DESCRIPTION = (
    "下载后自动替换并重启，保留规则、偏好和当天累计。更新期间不补算流量。"
    "当前为 ad-hoc 签名，未完成 Apple 公证；系统可能要求额外确认。"
)


def description_from_notes(path):
    """Build Sparkle's plain-text update description from the public release notes."""
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    try:
        start = lines.index("## 本次更新") + 1
        end = lines.index("## 系统与安装包", start)
    except ValueError as error:
        raise ValueError("Release notes must contain 本次更新 and 系统与安装包 sections") from error

    updates = []
    paragraph = []

    def flush_paragraph():
        if paragraph:
            updates.append("• " + " ".join(paragraph))
            paragraph.clear()

    for raw in lines[start:end]:
        line = raw.strip()
        if not line:
            flush_paragraph()
        elif line.startswith("- "):
            flush_paragraph()
            updates.append("• " + line[2:].strip())
        else:
            paragraph.append(line)
    flush_paragraph()
    if not updates:
        raise ValueError("Release notes 本次更新 section is empty")
    return "本次更新：\n" + "\n".join(updates) + "\n\n" + INSTALL_DESCRIPTION


def make_xml(manifest, arch, signature, description):
    package = manifest["packages"]["macos/" + arch]
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Flow Quota"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Flow Quota " + manifest["version"]
    ET.SubElement(item, "{" + NS + "}version").text = str(manifest["build"])
    ET.SubElement(item, "{" + NS + "}shortVersionString").text = manifest["version"]
    ET.SubElement(item, "{" + NS + "}minimumSystemVersion").text = manifest["minimumSystemVersion"]
    ET.SubElement(item, "description").text = description
    ET.SubElement(item, "enclosure", {
        "url": package["url"], "length": str(package["size"]),
        "type": "application/octet-stream", "{" + NS + "}edSignature": signature,
    })
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def sign_feed(feed, tool):
    subprocess.run([tool, "--account", ACCOUNT, "--disable-signing-warning", str(feed)],
                   check=True, stdout=subprocess.DEVNULL)


def prepare(output, manifest):
    output = Path(output)
    description = description_from_notes(output / "RELEASE-NOTES.md")
    tool = signer()
    for arch, name in zip(("arm64", "x86_64"), FEEDS):
        package = output / manifest["packages"]["macos/" + arch]["fileName"]
        feed = output / name
        feed.write_bytes(make_xml(manifest, arch, sign_archive(package, tool), description))
        sign_feed(feed, tool)


def verifier():
    source = ROOT / "scripts/verify-update-signatures.swift"
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
    binary = ROOT / ".artifacts/update-tools" / ("verify-" + digest)
    if not binary.exists():
        binary.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
        subprocess.run(["xcrun", "swiftc", str(source), "-o", str(binary)], check=True, env=env)
    return binary


def verify_signatures(requests):
    subprocess.run([str(verifier()), public_key()], input=json.dumps(requests), text=True, check=True)


def validate(output, manifest):
    output = Path(output)
    description = description_from_notes(output / "RELEASE-NOTES.md")
    requests = []
    for arch, name in zip(("arm64", "x86_64"), FEEDS):
        path = output / name
        data = path.read_bytes()
        match = SIGNATURE.search(data)
        if not match or int(match[2]) != match.start():
            raise ValueError("Missing or malformed signed appcast: " + name)
        length = int(match[2])
        # Compare the entire payload against our public template, not just selected
        # XML fields: no hidden links, scripts, extra enclosures or unknown options.
        try:
            root = ET.fromstring(data[:length])
            signature = signature_value(root.find("channel/item/enclosure").get("{" + NS + "}edSignature"))
        except (ET.ParseError, AttributeError) as error:
            raise ValueError("Malformed appcast") from error
        if data[:length] != make_xml(manifest, arch, signature, description):
            raise ValueError("Appcast differs from the expected release/architecture")
        package = output / manifest["packages"]["macos/" + arch]["fileName"]
        requests.extend([{"file": str(path), "signature": signature_value(match[1].decode()), "length": length},
                         {"file": str(package), "signature": signature}])
    verify_signatures(requests)
