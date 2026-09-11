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
