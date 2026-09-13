# VMLSpeedBubble

Experimental jailbreak tweak for displaying VietMap Live speed information and CarPlay overlays.

## Current weather debug build

Version `16.9-carplay-weather-phoneforeground1` separates the Google Maps phone scene from the CarPlay-triggered/prewarmed Google Maps process. The Google Maps weather sender only posts its sender test and scans destination/navigation UI when the iPhone main-screen scene is foreground active with a key window. The CarPlay weather receiver remains in `com.apple.CarPlayApp`.

Expected probe flow:

1. Connect CarPlay: `WEATHER IPC READY` appears on CarPlay.
2. Unlocking the iPhone alone should no longer produce the Google Maps sender test.
3. Open Google Maps on the iPhone: `GMW PHONE SCENE OK` appears on the iPhone and `GOOGLE MAPS IPC OK` appears on CarPlay.
4. Select a destination and start navigation; the sender then attempts destination capture, CLGeocoder, Open-Meteo, and the weather IPC event.

This repository is experimental and intended for controlled jailbreak testing.
