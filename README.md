# PANICORE Host Controller

An **unofficial Windows Steam mod** for **PANICORE**, with a live top-down radar, host-controlled monster freezing, noclip/flying, and emergency recovery. Developed through iterative testing of PANICORE gameplay and diagnostic logs.

**Current release: v0.11.6.2 (working build confirmed by the original tester).** For normal installation, visit **[Releases](../../releases/latest)** and download the complete `PANICORE_Controller_Portable_v0.11.6.2_Quiet_Setup.zip`. GitHub's automatic **Source code (ZIP)** is not the versioned installer package.

## Features

- **Radar (F5)**: heading-up top-down display that turns with the player; shows players, monsters, and recognized collectible items. Green markers represent important tools/escape components; yellow represent other supplies. Nearby item names, approximate distances and graphical altitude arrows are displayed. Frozen monsters use blue snowflakes.
- **Monster freeze (F6)**: host-only freeze/unfreeze for recognized enemies, including multiple bosses and the Military Base stalker replacement-lockdown behavior. Behavior may depend on game version and multiplayer authority.
- **Noclip (F7)**: pass through walls; **hold Space to rise**, **hold Ctrl to descend** and release to hover. Returning to normal collision outside a level may make you fall.
- **Emergency return (F8)**: attempts to return your character to the starting area and restore walking/collision.
- **Radar zoom**: **Shift + Up** to zoom out; **Shift + Down** to zoom in. Standard zooms show in-range contacts. At the maximum 250m zoom, off-range recognized items are represented by directional rim markers.
- A click-through, keyboard-controlled radar intended not to capture the game mouse.

## Install and start

1. Exit PANICORE and fully extract the release ZIP into its own normal Windows folder (for example, your Desktop). Do **not** launch commands inside a compressed ZIP preview.
2. Run **`START_HERE.cmd`**. It verifies the package, locates PANICORE, checks/install missing prerequisites as necessary, deploys the controller, and launches through Steam.
3. Host a private PANICORE game, press **F5** to show the radar, and use the shortcuts above. Keep the startup window open while playing.

The launcher uses a pinned, checksum-verified **UE4SS** development build downloaded from the official UE4SS GitHub releases. The Microsoft Visual C++ runtime may be installed from Microsoft's official source if it is not already present. Internet access is needed for missing dependencies. **No game executable or proprietary PANICORE assets are included** in the release.

## Three user commands

| Command | What it does |
| --- | --- |
| `START_HERE.cmd` | Verifies, installs/launches controller and PANICORE |
| `Uninstall.cmd` | Removes verified controller-owned game-side files; preserves saves and unrelated installations |
| `Generate_Report.cmd` | Creates a local diagnostic ZIP in `Reports` (does **not** upload automatically) |

The `App` folder contains source scripts and internal checks; `Reports` collects local reports. If upgrading or changing machines, close PANICORE before cleanup and installation. Installations of another UE4SS mod may require manual conflict resolution instead of overwriting their files.

## Compatibility and limits

- **Windows x64 + Steam edition of PANICORE**. The development/test reports referenced **Unreal Engine 5.4.4**. Future game updates may change objects or loader compatibility.
- **Designed for host-owned sessions**; installing only on a client is not guaranteed to allow F6/F7/F8. Host-to-client synchronization was not conclusively verified in every mode.
- The original tester confirmed v0.11.6.2 runs successfully, including radar and control functionality, after fixes to the earlier Lua-file encoding and window behavior. **This does not constitute a crash-free guarantee**; some earlier experimental releases suffered native UE4SS access violations.
- Use in **solo or consenting private multiplayer sessions**. Respect game rules and other players. No anti-cheat bypass is provided.
- The earlier skin-price, all-skins achievement, and 2,222 zombie-slap experiments are **not part of this release**.

## Troubleshooting

- If the game or controller does not start, run `Generate_Report.cmd` and inspect its report under `Reports`. The launcher also writes local setup logs.
- A game crash may include local paths in its logs. **Review and redact personal information before publicly posting diagnostic ZIPs or crash reports.** Do not upload the save folder or player identifiers to a public issue.
- If switching between controller versions, close the game and use `Uninstall.cmd` before deleting a version's folder. It should not overwrite or remove unrelated, unverified loader files.

## Source code and building

All controller source (`App/Mods/PanicoreHostControl/Scripts/main.lua`), the radar renderer (`App/Radar_View.ps1`), launcher, cleanup, and verification scripts are included. They use UE4SS Lua and Windows PowerShell; no separate compilation is required for these scripts. The normal supported method is the **release ZIP**, not GitHub's auto-generated source archive.

The release ZIP SHA-256 is recorded in [`RELEASE_SHA256.txt`](RELEASE_SHA256.txt). `App/SHA256_MANIFEST.txt` contains integrity hashes for the scripts.

## License and credits

Controller and installer source: **MIT License**, see [`LICENSE`](LICENSE). The UE4SS dependency and Microsoft runtimes are owned and licensed by their respective publishers; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). This repository does not bundle either dependency.

Created by Jimmy and ChatGPT as an independent community project. **Not affiliated with or endorsed by ZTEK Studio, PANICORE, Steam, or the UE4SS maintainers.** All game assets remain the property of their respective owners.
