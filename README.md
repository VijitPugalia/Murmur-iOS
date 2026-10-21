# Murmur for iPhone

Native dictation and saved clips, made by Vijit Pugalia. Version 0.2.0 is a test build.

## One app, including its keyboard

Install `Murmur-0.2.0.ipa` directly with SideStore or Sideloadly, keeping the keyboard extension. LiveContainer cannot register it.

1. Open Settings in Murmur, choose Groq Whisper, enter your own Groq API key and tap Save API key. The key is stored in the app's Keychain and is not shared with the keyboard.
2. Choose Large V3 Turbo for speed or Large V3 to compare accuracy. Review Personal vocabulary; it starts with Vijit Pugalia. Add names and terms one per line. Hints are not automatic word replacements.
3. In iPhone Settings > General > Keyboard > Keyboards > Add New Keyboard, add Murmur and enable Allow Full Access for shared session controls and clips. The keyboard itself makes no network requests.
4. In Murmur, tap Activate keyboard session. The microphone remains active for up to five minutes. Idle audio is discarded, not stored or sent.
5. Switch to a messaging app, select Murmur with the globe key, tap Record and speak after Listening appears.
6. Tap Stop & Insert. The recording goes to Groq; the returned text is inserted only if the keyboard and original text field remain active. If you change fields, edit or leave the keyboard, use Insert text explicitly. Murmur never presses Send.
7. Record another message during the same session. Cancel discards the current recording/request. End session switches the microphone off.

Session expiry, microphone interruption and headset disconnection end the session and cancel unfinished work. Open Murmur to reactivate. iOS may end background execution sooner. Each dictation is limited to 55 seconds. The keyboard cannot independently start a cold microphone session.

## Recognition and privacy

Groq requires internet and your API key; that account's limits and charges apply. There is no automatic model/provider fallback or rewriting pass. Errors require a new dictation; recordings are not retained for retry. The API endpoint is the transcription endpoint, not translation.

Audio is converted to mono 16 kHz PCM WAV. A 250 ms tail and converter flush preserve the ending before the file is finalised and uploaded. Vocabulary is capped at 24 lines / 400 characters. English locale choices send an English language hint; Hindi sends Hindi. Stop-to-text time is measured per request and displayed, not promised.

Apple recognition remains an explicit in-app option. It receives vocabulary hints and waits up to ten seconds for final recognition instead of two. A timeout labels the text as potentially incomplete. Keyboard sessions require Groq mode.

Only recordings you start are saved temporarily and uploaded. Temporary audio is deleted on completion, failure or cancellation; crash leftovers are removed at next launch. Groq's own data policies apply to uploaded speech. Idle microphone audio is discarded. The latest transcript and saved clips are shared locally with the keyboard; the API key is not. Device backups may include clips. Copy is local-only. No clipboard surveillance or analytics.

Clips supports pin, delete, copy and deliberate pasted text. History can be disabled. It retains up to 100 unpinned clips plus pinned clips.

Both app and extension require the same signed App Group. Murmur recognises matching team-suffixed group names from its provisioning profile. If sharing is unavailable, activation reports the problem; main-app copy/paste remains available.

## Build

GitHub Actions uses macOS to run rules, persistence, multipart and mocked HTTP tests, then compile the app and keyboard. The Murmur-iOS artifact contains one ad-hoc-signed IPA; SideStore re-signs it for installation.

On a Mac with Xcode and XcodeGen, run `bash scripts/build.sh`.
On Windows, run `python scripts/configure.py`, `python scripts/validate.py`, and `python scripts/validate.py --ipas dist`.

Automated tests use neither personal recordings nor real API credentials. A successful build does not establish actual transcription accuracy or physical-device background behaviour.

## iPhone acceptance checks

- Compare Turbo and Large V3 with the same sentences, including Vijit Pugalia, a genuine mention of Ajit, numbers and important words at the end.
- Measure wrong/missing words and Stop-to-text delay.
- Test repeated Record / Stop & Insert, cancellation during upload and switching text fields before completion.
- End the session and check that the microphone indicator disappears. Test expiry, incoming calls and disconnecting a headset.
- Test invalid keys, offline operation and rate limits.
- Check saved clips, history-off, pinning and deletion.
