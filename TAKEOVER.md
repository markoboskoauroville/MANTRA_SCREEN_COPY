# TAKEOVER: Screen Copy (Mantra)

A Swift Mac app (bundle id community.auroville.screencopy, installed as /Applications/Screen Copy (Mantra).app, signed "Mantra Apps"): a tabbed screen copy of Marko's Android phones, one tab per phone, every stream running in the background. It finds the phones by itself and puts them on cards, one card per physical phone, with all its routes (USB, Wi-Fi, Tailscale).

## Architecture chosen: (a) our own client of the scrcpy server protocol
scrcpy's desktop client is an SDL window and cannot be embedded in a tab, so the app speaks the scrcpy-server protocol itself (scrcpy 4.1, Apache-2.0, jar bundled in server/ and copied into the app's Resources):
- push the jar to /data/local/tmp, `adb forward tcp:0 localabstract:scrcpy_<scid>`, start `app_process ... com.genymobile.scrcpy.Server 4.1 key=value ...` with tunnel_forward=true;
- three sockets in order video, audio, control on the forwarded port; the dummy byte, the 64-byte device name, the codec id; 4.x media packets with a 12-byte header (config flag bit 6, key bit 5, pts, size) and 12-byte session packets (bit 7 set, width, height);
- video H.264: Annex-B split, SPS/PPS to a CMVideoFormatDescription, AVCC samples into an AVSampleBufferDisplayLayer (VideoToolbox hardware decode) with DisplayImmediately; tab switch sends RESET_VIDEO so a fresh key frame arrives;
- audio: audio_codec=raw (16-bit 48 kHz stereo, nothing to decode) played by one shared AVAudioEngine, one player node per tab (own volume and mute), only the active tab by default, or ALL TABS; the Mac's default output is used and the app never changes the Mac's audio device (the ADAM D3V is the boss);
- control: touch (pointer id -1), scroll, keycodes, text, paste (SET_CLIPBOARD), BACK/HOME/APPS. Layouts (big-endian) from scrcpy's test_control_msg_serialize.c.

## Sound rule: pre-fader
audio_source=playback (AudioPlaybackCapture), no audio_dup, so the phone stays silent in the room and the Mac hears the sound before the phone's own volume. Per tab switch PHONE SILENT / PHONE SPEAKS (audio_dup, restarts the stream). Bottom strip PHONE VOLUME sets the phone's own media/ring/alarm/call volume (`cmd media_session volume --stream N --set`, read back), for this phone or all phones; it never changes what the Mac hears.

## Discovery (Discovery.swift, every ~6 s, scan every ~24 s)
`adb devices -l`; `adb mdns services` (_adb-tls-connect); a port-5555 scan of every private /24 the Mac is on; Tailscale peers (Tailscale status --json, Android, port 5555); each found address gets `adb connect`. Routes are merged by `ro.serialno` into one Phone. Route order: USB, Wi-Fi, Tailscale, then measured round trip. A tab follows the best route and falls over by itself when it drops; a click on a route badge forces that route (click again to release). A USB-only phone gets ENABLE WI-FI AND TAILSCALE ACCESS (`adb tcpip 5555`). PAIR A PHONE runs `adb pair`.

## Build and install
Never compiled on the Mac: push to main, .github/workflows/build.yml (macos-15) builds, release v<N> marked Latest. Install: gh release download, codesign --force -s "Mantra Apps" (bundle id above), copy to /Applications. The repo is public (modules/building-repos-public.md: private minutes are blocked by billing), no README, no description. Version is `let VERSION = N` in app/App.swift, whole numbers.

## URL scheme / log
`open -g screencopy://tab/2` selects tab 2; log in ~/Library/Logs/ScreenCopyMantra.log (window number, per-tab fps and audio level every 5 s). Launch argument --muted starts every tab muted (tests).

## Not done in v1
Mac microphone to the phone (see LESSONS.md: no way without root or hardware), phone microphone to the Mac, camera, recording, file drop.
