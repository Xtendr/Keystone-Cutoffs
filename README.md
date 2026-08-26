# Keystone Cutoffs

An in-game Mythic+ title and percentile tracker for World of Warcraft.

Keystone Cutoffs brings live Raider.IO Mythic+ rating cutoffs directly into your World of Warcraft UI. You no longer have to tab out to a web browser to see how close you are to the top 0.1% title or track your region's percentile brackets. Everything you need to know about the current season's competitive ladder is available at a glance.

## Features

* **Live Region Cutoffs:** Tracks the exact Mythic+ rating needed for the top 0.1% title, plus the 1%, 10%, and 25% brackets.
* **Daily Automated Updates:** Cutoff data is refreshed daily from Raider.IO. Every region and derived dataset is validated before a release can replace the previous known-good file.
* **Automatic Season Rollover:** The updater reads Raider.IO's regional season schedule and dungeon pool, then switches only after the new season is available in every supported region.
* **Dungeon Score Overlays:** Enhances the native Mythic+ UI by overlaying your best score and time directly onto the dungeon icons.
* **Native Rarity Colors:** Dungeon scores are color-coded automatically based on Blizzard's official keystone level rarity (Green for +2, Blue for +3-5, Purple, Orange).
* **Compact & Draggable:** A clean, draggable main panel that can be collapsed or put into "Compact Mode" to save screen space when you only want to see the essentials.
* **Customization:** Choose from any SharedMedia font for your dungeon overlays, with live previews. Adjust text sizes, outlines, and shadows for perfect readability.
* **Optional Goal Mode:** Replace the default cutoff block with one focused percentile, achievement, or custom score goal. Disabled by default.
* **Optional Progress Insights:** Track movement between bundled cutoff releases, show the dungeon furthest behind title pace, or retain last-known character scores. Every history feature is disabled by default.
* **Optional Standalone Panel:** Keep the dashboard visible outside Blizzard's Mythic+ window, with independent scale, opacity, and position controls. Disabled by default.
* **Detailed Ladder View:** Open a deliberate popout for every percentile, achievement threshold, population value, and opted-in character snapshot without adding rows to the normal panel.

## Usage

* Type `/kc` to open the settings window.
* **Left-click** the minimap button to open settings, or **Right-click** to toggle the main Mythic+ panel.
* Hold **Shift + Left-Click** on the main panel to drag it around your screen.
* Adjust your dungeon overlay fonts, sizes, and outlines in the "Customize" tab.
* Toggle "Compact Mode" in the "Display" tab for a minimal UI footprint.
* Use the "Goals" and "Advanced" tabs only when you want the optional progression tools. Those tabs retain selective `?` help for unfamiliar features; familiar Display and Customize controls stay visually quiet.

All newly added progression, history, and standalone features are opt-in. Existing users keep the lightweight default dashboard unless they explicitly enable them.

## Installation

You can install Keystone Cutoffs via [CurseForge](https://www.curseforge.com/wow/addons/keystone-cutoffs) or your favorite addon manager.

## Feedback & Issues

Have suggestions, bug reports, or feature requests? Please open an issue on GitHub or leave a comment on CurseForge!

## Data release safety

Daily releases fail closed: incomplete regional cutoffs, missing score colors, or partial dungeon benchmarks stop publication and preserve the last valid `CutoffData.lua`. A maintainer can set `KEYSTONE_CUTOFFS_SEASON` for an explicit, validated season override when needed.
