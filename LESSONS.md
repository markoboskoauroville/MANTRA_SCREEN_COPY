# LESSONS: Screen Copy (Mantra)

- 13.11.2026 scrcpy 4.x changed its wire format: video has session packets (bit 7) with the size, no width/height after the codec id; every media packet has a 12-byte header. The documentation (doc/develop.md) does not list the control message layouts: they are in app/tests/test_control_msg_serialize.c.
- The forward-tunnel dummy byte arrives right after the first accept; the device name and codec id only after all three sockets are connected. Reading them before connecting audio and control deadlocks.
- GitHub's private-repository minutes were blocked ("recent account payments have failed"): the repository is public by rule (building-repos-public.md), after the three secret checks.
- Mac microphone to the phone's WhatsApp call: see the section in the session report; Android does not mix another app's playback into a call's uplink, and the Mac cannot be a USB audio gadget. Real options: hardware (USB-C audio adapter with a cable from the Mac's output), WhatsApp Desktop on the Mac, or an emulator with the host microphone.
