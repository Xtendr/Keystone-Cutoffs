# Keystone Cutoffs - Full Context Handoff

This file summarizes the addon codebase and the full decision history from this development chat so another agent (e.g., Claude in terminal) can continue with full context.

---

## 1) Project Overview

**Addon name:** Keystone Cutoffs  
**Path:** `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\KeystoneCutoffs`  
**Purpose:** In-game Mythic+ cutoff tracker and UI helper.

Core value:
- Shows Raider.IO title/percentile cutoff targets in-game.
- Shows your gap to Top 0.1%, Top 1%, and Keystone Myth.
- Enhances Mythic+ dungeon icons with score/time overlays.
- Provides customizable display/settings UI.

---

## 2) Current File Roles

- `KeystoneCutoffs.lua`  
  Main addon logic (panel UI, positioning, settings window, minimap icon, overlays, data rendering).

- `CutoffData.lua`  
  Auto-generated data payload consumed by addon runtime.

- `update_cutoffs.py`  
  Fetches Raider.IO cutoff + score tier data and writes `CutoffData.lua`.

- `KeystoneCutoffs.toc`  
  Metadata + load order + addon compatibility info.

- `.github/workflows/release.yml`  
  CI/CD for data updates, auto-tagging, packaging, and CurseForge upload.

- `.pkgmeta`  
  Packager metadata (including CurseForge project ID placeholder/value used in workflow ecosystem).

---

## 3) Major Features Implemented During This Chat

### UI/Panel
- Removed old "Mythic+ Profile" section from panel.
- Added compact mode for panel rows.
- Added stale-data warning behavior on "Cutoffs Updated" if data age > 7 days.
- Made panel draggable with `Shift + Left drag`.
- Added collapse chevron icon behavior (open/closed state).
- Fixed earlier collapse-anchor drift issue.
- Later fixed panel anchoring regression so panel follows Blizzard panel push behavior.

### Overlay Customization
- Customization tab and controls:
  - SharedMedia font selection with live preview.
  - Score/time font size sliders.
  - Outline mode options including shadow behavior.
- Score/time overlay rendering on dungeon icons.
- Native Blizzard rarity color integration for dungeon score overlays.

### Minimap / Settings
- Minimap button via LDB + LibDBIcon.
- Left-click opens settings; right-click toggles panel.
- Show/hide minimap button setting.
- Fixed "Font not set" runtime issue in font dropdown.

### Addon Metadata / Visuals
- Added addon icon texture to TOC for native AddOns list.
- Added/removed panel settings icon based on user preference.

---

## 4) CI/CD and Release Automation Status

### Current intention
Hands-off automation:
- Daily schedule updates data.
- If data changed, bot commits update and auto-creates a release tag.
- Tag-triggered workflow packages and uploads to CurseForge.

### Important resolved CI/CD issues from chat
1. **Packager env var mismatch**
   - BigWigs packager script expects `CF_API_KEY` (not `CF_API_TOKEN`).
   - Workflow updated accordingly.

2. **CurseForge project ID source**
   - Packager reads `## X-Curse-Project-ID:` from TOC.
   - This line was added to TOC.

3. **Game version mismatch**
   - TOC interface was temporarily set to 120005 only (caused in-game "Incompatible" on 12.0.1).
   - Updated to include multiple interfaces:
     - `## Interface: 120000, 120001, 120005`

4. **Auto-tag naming**
   - Auto tags changed to cleaner format:
     - `vdata-YYYY-MM-DD`
     - fallback same-day rerun suffix: `-run<runNumber>`

---

## 5) Critical Bug Found and Fixed: Lost Delta Colors

### Symptom
Panel gap values (e.g. `+577.8`) became white instead of colorized.

### Root cause
`scoreColors` became empty in `CutoffData.lua`.

Why empty:
- `update_cutoffs.py` `fetch_score_tiers()` expected dict payload (`tiers`/`scoreTiers`).
- Raider.IO endpoint currently returns a plain list.
- Parser returned `[]`, so gradient array was empty at runtime.

### Fix applied
In `update_cutoffs.py`:
- `fetch_score_tiers()` now supports both:
  - list payload (direct return)
  - dict payload fallback (`tiers`, `scoreTiers`)

Also fixed Windows console encoding crash:
- replaced unicode arrow in print output with ASCII `->`.

Result:
- regenerated `CutoffData.lua` contains populated `scoreColors` entries.
- panel score/gap colorization restored.

---

## 6) Latest Panel Positioning Fix (UI push behavior)

### Symptom
When another Blizzard window opens, panel no longer "pushes" correctly and can overlap.

### Root cause
Drag persistence had been stored as absolute `UIParent` anchor, disconnecting panel from dynamic `ChallengesFrame` positioning.

### Fix applied in `KeystoneCutoffs.lua`
- On drag stop: store offset relative to `ChallengesFrame` (`TOPLEFT` to `TOPRIGHT`).
- Positioning logic now prefers new schema anchored to `ChallengesFrame`.
- Legacy saved absolute format (`relPoint=BOTTOMLEFT`) is auto-migrated by clearing once so normal anchoring resumes.

---

## 7) Known Runtime/Packaging Notes

1. **Source zip vs packager zip**
   - A GitHub source zip (repo snapshot) is not the same as the BigWigs packager output zip.
   - For testing installs, prefer packaged release artifact (`KeystoneCutoffs-vX.Y.Z.zip`) produced by workflow.

2. **Line ending warnings**
   - LF/CRLF warnings appeared often in Windows git terminal; these were warnings, not blockers.

3. **Folder/git history issue occurred**
   - At one point repo metadata got split/missing due to folder rename (`_archived` path confusion).
   - Resolved by reinitializing local git, merging unrelated histories, resolving conflicts, and pushing.

---

## 8) Current Expected Behavior (Post-Fixes)

- Addon loads on current patch (12.0.1) and upcoming metadata versions.
- Gap values on panel are colorized again.
- Panel tracks `ChallengesFrame` better when Blizzard frame push occurs.
- CI/CD can auto-update data and auto-release to CurseForge.

---

## 9) Suggested Immediate Validation Checklist

1. In-game:
   - Open Mythic+ frame and verify panel appears with colored delta numbers.
   - Open another large panel (friends/character/etc.) and verify panel stays correctly aligned.
   - Shift-drag panel once to save new relative offset.

2. GitHub:
   - Ensure `main` includes latest:
     - `update_cutoffs.py` list-response fix
     - `CutoffData.lua` with non-empty `scoreColors`
     - `KeystoneCutoffs.toc` interface + project ID lines
     - `KeystoneCutoffs.lua` panel anchoring fix

3. Release:
   - Tag next version (e.g. `v1.0.9` or newer).
   - Confirm workflow run shows packaging/upload.
   - Confirm CurseForge file appears with expected game versions.

---

## 10) TOC and Metadata Targets

Expected TOC highlights:
- `## Interface: 120000, 120001, 120005`
- `## X-Curse-Project-ID: 1516987`
- `## IconTexture: Interface\AddOns\KeystoneCutoffs\Assets\KeystoneCutoffs_logo`

---

## 11) Reddit/Feature Direction Context (Future Ideas)

A requested enhancement idea from feedback:
- show per-dungeon "title pace" gap vs player.

Discussed recommended MVP:
- For each dungeon, derive a benchmark (median from sampled high-end runs/title-caliber pool).
- Compare player's current dungeon value/score to benchmark.
- Present clear delta in tooltip/overlay style.

Feasible, but requires careful data source/aggregation to avoid bias.

---

## 12) Commit/History Context Mentioned in Chat

Representative commits referenced during this session:
- `22c469f` - panel alignment follow/push behavior fix
- `7b31624` - merge commit keeping local fixes
- `fda5233` - interface compatibility commit period
- `ebaac81` - `CF_API_KEY` env usage fix for packager
- `ee25e1c` - cleaner daily auto-tag naming
- `987c20d` - auto-tag daily data updates flow

(Exact history may include additional commits/rebases from manual terminal operations.)

---

## 13) If Continuing Work in Terminal

Recommended first commands:

```powershell
cd "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\KeystoneCutoffs"
git status
git log --oneline -n 15
```

Then validate current file state before next release/tag.

