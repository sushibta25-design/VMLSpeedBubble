# VMLSpeedBubble V11

Changes from the 0.2.0 build:
- Removes hard-coded 640x240 CarPlay root requirement.
- Detects CarPlay candidates by scene role, external UIScreen, or landscape UIRootSceneWindow geometry.
- Scans both UIApplication windows dynamically and UIWindowScene windows.
- Creates a dedicated overlay UIWindow on the captured CarPlay UIWindowScene.
- Keeps the previously proven _UIVisualEffectContentView host insertion as a second render path.
- Scales bubble position/size relative to the actual host/display size.
- Keeps RuntimeSniffer V4 unchanged for updateSpeedLimit IPC.

Test log: /var/mobile/VMLHostSniffer.txt
Useful searches:
- VML CARPLAY MULTI-DISPLAY RENDER V11
- [root] candidate
- [overlay] *** CARPLAY OVERLAY WINDOW CREATED ***
- [host] *** CARPLAY HOST BUBBLE ADDED ***
- [scanner] no candidate windows
