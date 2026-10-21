"""Deterministic source/package checks. Does not claim iPhone runtime coverage."""
import argparse
import json
import plistlib
import struct
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--ipas", type=Path)
args = parser.parse_args()
checks = 0
def check(condition, message):
    global checks
    if not condition:
        raise SystemExit("FAIL: " + message)
    checks += 1
    print("PASS: " + message)

project = json.loads((root / "project.json").read_text())
check(set(project["targets"]) == {"Murmur", "MurmurStandalone", "MurmurKeyboard"}, "Both app variants and keyboard are declared")
for name in ["App", "Standalone"]:
    info = plistlib.loads((root / f"Config/{name}.plist").read_bytes())
    check(bool(info.get("NSMicrophoneUsageDescription")) and bool(info.get("NSSpeechRecognitionUsageDescription")), name + " declares speech and microphone permissions")
check("dependencies" not in project["targets"]["MurmurStandalone"], "Standalone has no extension dependency")
check("CODE_SIGN_ENTITLEMENTS" not in project["targets"]["MurmurStandalone"]["settings"]["base"], "Standalone does not request App Groups")
keyboard = plistlib.loads((root / "Config/Keyboard.plist").read_bytes())
check(keyboard["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.keyboard-service", "Keyboard extension point")
check("import Speech" not in (root / "Keyboard/KeyboardViewController.swift").read_text(), "Recording belongs to containing app")
if args.ipas:
    ipas = list(args.ipas.glob("*.ipa"))
    check(len(ipas) == 2, "Exactly two IPA packages")
    for path in sorted(ipas):
        with zipfile.ZipFile(path) as archive:
            check(archive.testzip() is None, path.name + " ZIP integrity")
            infos = [n for n in archive.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith("/Info.plist")]
            check(len(infos) == 1, path.name + " contains one app")
            info = plistlib.loads(archive.read(infos[0]))
            executable = infos[0].rsplit("/", 1)[0] + "/" + info["CFBundleExecutable"]
            binary = archive.read(executable)
            check(binary[:4] == b"\xcf\xfa\xed\xfe" and struct.unpack("<I", binary[4:8])[0] == 0x0100000C, path.name + " contains arm64 Mach-O executable")
            extensions = [n for n in archive.namelist() if n.endswith(".appex/Info.plist")]
            check(len(extensions) == (0 if "LiveContainer" in path.name else 1), path.name + " correct extension count")
            check(info["CFBundleShortVersionString"] == "0.1.0", path.name + " version")
print(f"{checks} checks passed")
