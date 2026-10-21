# Murmur for iPhone

A minimal native SwiftUI dictation app with saved text clips, made by Vijit Pugalia. This is an early 0.1.0 test build, not a tested App Store release.

## Test in LiveContainer

Import `Murmur-LiveContainer-0.1.0.ipa` using LiveContainer's + button and launch it. Allow microphone and speech recognition when prompted. Tap **Start dictation**, speak, then **Stop**. Review the text, tap **Copy**, switch to Messages or WhatsApp and paste. The **Clips** tab stores reusable text; you can pin, copy, or swipe to delete. Add copied text deliberately with **+** and **Paste**.

On-device speech recognition is the default. If unavailable for your selected language, choose another language or explicitly enable Apple network recognition in Settings. There is no API key, subscription, or Murmur server. Recognition quality and latency still need testing on your phone. Recordings stop at 55 seconds in this build.

LiveContainer does not register guest keyboard extensions and shares host permissions. If speech or microphone access is denied, check LiveContainer's permissions in iPhone Settings. If Apple's Speech service does not work through that host, install the app directly with SideStore/Sideloadly; permission behaviour inside LiveContainer has not been verified.

## Keyboard test (direct SideStore / Sideloadly installation)

Install `Murmur-Keyboard-0.1.0.ipa` directly, keeping the keyboard extension. Do not load this variant through LiveContainer expecting a system keyboard. The sideloader must re-sign both app and extension and preserve/remap their common App Group correctly.

1. Open Murmur once. Check for a shared-storage warning.
2. In iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard, add Murmur. Enable Full Access so the keyboard can access Murmur's shared clips. The keyboard itself makes no network requests.
3. Start dictation in Murmur. Switch to a messaging app and select Murmur using the globe key.
4. Tap **Stop**, wait for the transcript, then **Insert transcript**. The app never sends your message.
5. Tap a saved clip to insert it. Use **Next keyboard** to return to normal typing.

The keyboard cannot start microphone capture itself. Some apps and secure fields block custom keyboards. If the App Group is unavailable after signing, Murmur shows a warning and the keyboard refuses to pretend it can read clips. Copy/paste in the main app remains available. Background capture and keyboard handoff require physical-device testing.

## Storage and privacy

Audio is streamed into Apple Speech and is not saved to audio files. Network recognition, if opted in and needed, sends speech to Apple. Saved clips and the latest temporary keyboard transcript live in this app's storage; device backups may include them. Copy uses a local-only pasteboard write. There is no background clipboard collection or analytics. History can be disabled, clips deleted individually, or all clips and the temporary transcript cleared in Settings. The history limit is 100 unpinned clips; pinned clips are retained.

## Build

GitHub Actions uses a macOS runner to compile both variants and run the core persistence tests. Download the `Murmur-iOS-test-packages` artifact from a successful run. These are ad-hoc signed packages; direct device installation requires re-signing through a sideloader or Xcode.

On a Mac with Xcode and XcodeGen installed:

```sh
bash scripts/build.sh
```

On Windows, metadata and package structure can be checked with:

```powershell
python scripts/configure.py
python scripts/validate.py
python scripts/validate.py --ipas dist
```

No Windows application source is included or modified.

## Device acceptance checklist

- Allow and deny microphone/speech permissions; denied access must show a useful error.
- Dictate a short message, a name, numbers, and Hindi if used; compare words against what you spoke.
- Cancel recording; it must stop without saving a clip.
- Test interrupted recording and unplugging a headset.
- Save, pin, restart, copy, delete; confirm clips persist and deletion works.
- With history off, complete dictation; it must not add a saved clip.
- Direct installation only: shared-storage access, Stop/Insert from keyboard, and Messages/WhatsApp field insertion.
- Confirm no message is sent automatically.

Build evidence is separate from this checklist. A successful compile does not confirm iPhone or LiveContainer behaviour.
