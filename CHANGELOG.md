# Changelog

## v0.11.6.2 — Initial public release

User-confirmed working portable package, following revisions that corrected the Lua UTF-8 BOM loading failure and hid unnecessary console windows.

- Retain the heading-up player-following radar, recognized collectible markers, green/yellow categories, graphical altitude arrows, blue frozen-monster snowflakes, and the 250m all-item directional overview.
- Keep F6 monster freeze/unfreeze, F7 noclip with Space/Ctrl altitude, and F8 emergency recovery.
- Reduce radar workload: slower snapshots, periodic pickup checks, cached draw resources, and less frequent full-item discovery, with documented detection-delay tradeoffs.
- Fix startup script encoding and trim console windows while maintaining file-based logs.
- Expose the simplified `START_HERE.cmd`, `Uninstall.cmd`, and `Generate_Report.cmd` commands.
- Continue collecting diagnostics locally; no automatic upload.

## Earlier development (not published here)

v0.1–v0.11.5 prototypes established monster selection and freeze, multi-entity support, a persistent Military Base stalker lockdown, flying/recovery controls, the live radar, pickup identification and heading-following display. Some earlier experimental builds had runtime crashes or installation failures; they are not recommended for download.
