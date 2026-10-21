"""Generate reproducible XcodeGen metadata and a simple original app icon."""
from pathlib import Path
import json
import plistlib
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]

def plist(path, value):
    output = ROOT / path
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(value))

app_info = {
    "CFBundleDisplayName": "Murmur", "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSRequiresIPhoneOS": True, "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    "NSMicrophoneUsageDescription": "Murmur uses your microphone only when you start dictation.",
    "NSSpeechRecognitionUsageDescription": "Murmur turns your speech into text. On-device recognition is preferred; network recognition requires your opt-in.",
    "UIBackgroundModes": ["audio"], "ITSAppUsesNonExemptEncryption": False,
}
plist("Config/App.plist", app_info)
plist("Config/Standalone.plist", app_info)
plist("Config/Keyboard.plist", {
    "CFBundleDisplayName": "Murmur", "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundlePackageType": "XPC!", "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.keyboard-service",
        "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).KeyboardViewController",
        "NSExtensionAttributes": {"IsASCIICapable": False, "PrefersRightToLeft": False,
                                   "PrimaryLanguage": "en", "RequestsOpenAccess": True}}
})
plist("Config/Shared.entitlements", {"com.apple.security.application-groups": ["group.com.vijitpugalia.murmur.ios"]})

def app_target(standalone=False):
    return {
        "type": "application", "platform": "iOS",
        "sources": ["App", "Shared"],
        "settings": {"base": {
            "PRODUCT_BUNDLE_IDENTIFIER": "com.vijitpugalia.murmur.ios" + (".standalone" if standalone else ""),
            "PRODUCT_NAME": "MurmurStandalone" if standalone else "Murmur",
            "INFOPLIST_FILE": "Config/Standalone.plist" if standalone else "Config/App.plist",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            **({"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) STANDALONE"} if standalone else {
                "CODE_SIGN_ENTITLEMENTS": "Config/Shared.entitlements"})
        }},
        **({} if standalone else {"dependencies": [{"target": "MurmurKeyboard", "embed": True}]})
    }

project = {
    "name": "Murmur", "options": {"deploymentTarget": {"iOS": "16.0"}},
    "settings": {"base": {"SWIFT_VERSION": "5.0", "TARGETED_DEVICE_FAMILY": "1,2",
        "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
        "CODE_SIGN_STYLE": "Automatic", "GENERATE_INFOPLIST_FILE": False}},
    "targets": {
        "Murmur": app_target(), "MurmurStandalone": app_target(True),
        "MurmurKeyboard": {"type": "app-extension", "platform": "iOS", "sources": ["Keyboard", "Shared"],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.vijitpugalia.murmur.ios.keyboard",
                "INFOPLIST_FILE": "Config/Keyboard.plist", "CODE_SIGN_ENTITLEMENTS": "Config/Shared.entitlements",
                "APPLICATION_EXTENSION_API_ONLY": True, "SKIP_INSTALL": True}}}
    },
    "schemes": {name: {"build": {"targets": {name: "all"}}} for name in ["Murmur", "MurmurStandalone"]}
}
(ROOT / "project.json").write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")

# Draw an original five-bar waveform with no external assets or dependencies.
size = 1024
pixels = bytearray()
bars = [(272, 360, 336, 664), (376, 264, 440, 760), (480, 192, 544, 832), (584, 264, 648, 760), (688, 360, 752, 664)]
for y in range(size):
    pixels.append(0)
    for x in range(size):
        white = any(x0 <= x < x1 and y0 <= y < y1 for x0, y0, x1, y1 in bars)
        pixels.extend((247, 252, 251) if white else (14, 99, 96))
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
assets = ROOT / "App/Assets.xcassets"
icon = assets / "AppIcon.appiconset"
icon.mkdir(parents=True, exist_ok=True)
(icon / "AppIcon.png").write_bytes(png)
(assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
(icon / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2))
print("Generated project.json, property lists, entitlements, and icon.")
