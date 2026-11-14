---
name: screen-copy
description: Screen Copy (Mantra), the Mac app that mirrors Marko's Android phones in tabs (repo MANTRA_SCREEN_COPY): routes USB / Wi-Fi / Tailscale, the Wi-Fi relay, the rotate button, phone volume, test hooks. Use for ANY Screen Copy / phone mirror / scrcpy tab task.
---
# Screen Copy (Mantra)

- Read TAKEOVER.md (the newest "Where it stopped") and LESSONS.md first. Requests go word for word into momentaryupdates.md and are pushed before code.
- Built only by GitHub Actions (push to main, release v<N> Latest); install = gh release download, codesign "Mantra Apps" --identifier community.auroville.screencopy, quit with osascript (the quit restores the phones), copy to /Applications, open -g.
- Log: ~/Library/Logs/ScreenCopyMantra.log. Test hooks: `open -g screencopy://tab/N`, `screencopy://rotate` (one press), `screencopy://volume/N`.
- A Wi-Fi phone with "No route to host" = the shared adb server has no Local Network permission: the app's relay (app/Relay.swift) handles it; never kill the shared adb server (Connection Keeper).
- Rotation: one press = one turn; presses wait until the picture turned; fixed-to-user-rotation holds landscape; auto-rotate off while connected, restored on quit.
- Stress test before calling it done: six fast rotate presses (= one turn), one press back, a route cut (`adb disconnect <route>`, back in seconds), readback of `dumpsys window displays | grep mCurrentRotation` on each phone; both phones left portrait.

## Run log
- 14.11.2026 v21: Wi-Fi relay, rotation seen through, auto-rotate off while connected; stress-tested on Nothing (USB) and Pixel (Wi-Fi relay).
