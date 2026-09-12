# VMLSpeedBubble V15.4 — Responsive Fuel Alert

Built directly from the last successful V15.3 SOS Bright Red source.

When VietMap reports overspeed:
- keeps the existing bright-red full-screen SOS warning;
- shows a centered black alert banner:
  - `XĂNG ĐANG TĂNG`
  - `GIẢM TỐC ĐỘ ĐÊ!`
- first line is heavier/larger than the second;
- fuel-pump icon + border + four outside warning marks + text all change color together;
- yellow for 0.5 second, blue for 0.5 second, repeating continuously;
- banner is always centered in the active CarPlay canvas;
- banner dimensions, icon, text, border and warning marks scale from the actual
  CarPlay scene width/height instead of assuming one fixed display size.

When overspeed becomes false:
- the red SOS background is hidden;
- the alert banner disappears immediately (no fade-out).

The speed-limit bubble behavior is otherwise unchanged from V15.3.

## VML Method Dump V2
This diagnostic build keeps the existing runtime sniffer and additionally writes:
- `Documents/VMLMethodDump.txt`: methods/properties/ivars for focused VietMap warning/route/map classes.
- `Documents/VMLWarningTrace.txt`: Flutter calls whose method names or payload keys look related to warning/sign/traffic/route/parking/stop/speed-limit data.

Open VietMap Live, wait ~8 seconds for the method dump, then reproduce a route that displays a no-parking/no-stopping sign and collect both files.
