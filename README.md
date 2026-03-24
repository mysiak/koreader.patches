# KOReader Patches

A collection of user patches for [KOReader](https://github.com/koreader/koreader), developed and tested on **Pocketbook Verse Pro**.

---

## Patches

| Patch | Description |
|---|---|
| [KOReader Header Status Bar](#1-koreader-header-status-bar-patch) | Moves status info to a fully customizable top header bar |
| [UI Font Replacement](#2-ui-font-replacement-patch) | Replace KOReader UI fonts from the menu |
| [Estimated Page Count](#3-estimated-page-count-patch) | Heuristic page estimation badge in the file browser |
| [Brightness Tweaks](#4-koreader-brightness-tweaks-patch) | Minimum brightness guard + auto-dim on USB charging |

---

## 1. [KOReader Header Status Bar Patch](https://github.com/mysiak/koreader.patches/blob/main/2-reader-header.lua)

A customizable header status bar that moves status information to the top of the screen. Addresses the lack of customization options in the built-in alternative status bar while reducing distraction from the footer.

**Latest version:** 20th February 2026

### Installation

Download the latest version: [2-reader-header.lua](https://github.com/mysiak/koreader.patches/blob/main/2-reader-header.lua), copy `.lua` file to `koreader/patches` folder, restart KOReader.

### Features

Access via: **Settings → Cog wheel → Header**

**Header Items:**
- Multiple custom text fields with book variables: `{author}`, `{title}`, `{page}`, `{progress}` and more (see in-app help)
- Dynamic fillers — automatically adjust spacing between elements
- Icon toggle, bracket toggle, WiFi icon (shown only when active)
- Author and title truncation options
- Most standard footer items available in the header

**Visual Customization:**
- Separator styles — predefined and fully custom
- Font size and bold toggle
- Color settings — invert header/footer, night mode compatibility, full-screen refresh on toggle to prevent ghosting
- Status bar separator — configurable line divider (color, thickness, margins)
- Transparency — opacity for both bar and background; background opacity can apply to all books or non-reflowable only (PDF, CBZ)
- Margins — top, side (custom or follow book settings), progress bar top margin
- Progress bar — show/hide, height, chapter marks (none / main / all), whole book or chapter scope, configurable colors (greyscale 0–255 or hex)

**Interactive:**
- Tap top area to show/hide the header bar
  > Note: may interfere with KOReader menu; tap slightly lower to access it

### Technical Details

**Fixes:**
- Time-to-finish crash fix for book and chapter estimates
- Current time icon with leading zero formatting
- Progress percentage shown in brackets

**Compatibility:**
- Overlay mode — header renders as overlay; adjust book margins accordingly
- Tested with EPUB, PDF, CBZ

**Known Limitations:**
- No auto-refresh

### Screenshots

**Simple progress bar:**
![Simple progress bar](https://github.com/user-attachments/assets/cb9c53df-ee2b-485d-9d15-1d8ea5e06ef0)

**Progress bar with all chapter marks:**
![Progress bar with all chapter marks](https://github.com/user-attachments/assets/5c95a38a-61c4-4962-85bd-19d66b7c7400)

**Inverted status bar:**
<img width="1072" height="125" alt="Inverted status bar" src="https://github.com/user-attachments/assets/b771a64a-f71e-4671-a558-aa8fbe36feac" />

### Credits

Based on patches by:
- [@oh1apps](https://github.com/oh1apps/koreader_header) — Original header implementation
- [@sebdelsol](https://github.com/sebdelsol/KOReader.patches/blob/main/2-statusbar-thin-chapter.lua) — Thin chapter statusbar

Developed with GitHub Copilot and Claude Sonnet/Opus 4.5.

---

## 2. [UI Font Replacement Patch](https://github.com/mysiak/koreader.patches/blob/main/2--ui-font.lua)

Replace KOReader's UI fonts from the menu. Based on [@sebdelsol's patch](https://github.com/sebdelsol/KOReader.patches/blob/main/2--ui-font.lua), updated for compatibility with Pocketbook Verse Pro and KOReader 2025.10.

### Installation

[Download](https://github.com/mysiak/koreader.patches/blob/main/2--ui-font.lua) the latest version, put `.lua` file into `koreader/patches` folder.

### Changes from Original

- Works on Pocketbook Verse Pro and KOReader 2025.10
- Font replacement can be enabled/disabled from the menu
- Shows custom book font and embedded book fonts in the menu
- Fonts present in the system with both normal + bold variants can be quickly selected as the UI font
- Working filename font pairs: `font-regular + font-bold` and `font + font-bold`

### Screenshot

<img width="400" alt="UI Font Replacement Screenshot" src="https://github.com/user-attachments/assets/a3a1cef7-2855-4f4a-bece-e014c291b56d" />

### Credits

Developed with GitHub Copilot and Claude Sonnet/Opus 4.5.

---

## 3. [Estimated Page Count Patch](https://github.com/mysiak/koreader.patches/blob/main/2-pages-badge_estimate.lua)

Heuristically estimates page count for books in the file browser by reading ZIP headers — no need to fully open each book. Developed as a proof of concept; results are "good enough" for a library overview.

Also includes a companion [Python script](https://github.com/mysiak/koreader.patches/blob/main/books_analysis.py) for analyzing your own library and generating custom-calibrated constants.

### Installation

1. Download the [user patch](https://github.com/mysiak/koreader.patches/blob/main/2-pages-badge_estimate.lua)
2. Follow the badge installation instructions from [@SeriousHornet's patches](https://github.com/SeriousHornet/KOReader.patches) — the icons are required
3. Place `.lua` file in `koreader/patches` folder

### Features

- Displays estimated page count badge in lower-left corner of each book in **Grid/Mosaic view**
- Badge format: `~###p` or `~###p (###p)` when accurate rendered page count is also available
- Finished books show a checkmark before the page count
- Configurable characters per page: 1800 / 2200 / 2500 (≈ 250 / 300 / 350 words per page)

### Performance

- Negligible delay (~3 seconds on ~150 books) when opening the file manager on Pocketbook Verse Pro
- No CPU-intensive rendering required

### Accuracy (tested on ~900 English EPUB books)

| Margin of Error | Books within range |
|---|---|
| ±10% | 63–66% |
| ±15% | 78–82% |
| ±26% | 90% |

### How It Works

The core formula:

```
estimated_pages = html_content_kb / kb_per_page_divisor
```

A fixed divisor is adjusted dynamically based on the ZIP compression ratio, which serves as a proxy for HTML verbosity (bloated EPUBs with excessive `<span>` tags have higher compression ratios and require a larger divisor to avoid over-estimation).

```
compression_ratio = uncompressed_size / compressed_size

if compression_ratio > 3.5:
    bloat_adjustment = (compression_ratio - 3.0) * factor
    kb_per_page_divisor += bloat_adjustment
```

The companion Python script extracts ground truth page counts from your library, tests multiple divisor values, and recommends optimal constants for your specific collection.

### Limitations

- Works best with EPUB; other formats are rough estimates only
- Badge visible only in Grid/Mosaic view of Cover browser or Project title
- Non-English books may be less accurate (run the Python script for custom constants)
- No caching — large folders may slow down UI on repeated browsing
- Developed and tested on Pocketbook Verse Pro only

### Screenshot

<img width="400" alt="Estimated Page Count Screenshot" src="https://github.com/user-attachments/assets/a986ed90-0685-427a-8040-badc51561790" />

---

## 4. [KOReader Brightness Tweaks Patch](https://github.com/mysiak/koreader.patches/blob/main/2-brightness-tweaks.lua)

Prevents accidentally setting brightness too low via swipe gestures, and automatically reduces brightness when the device is charging over USB.

Inspired by [@noxhirsch's patch](https://github.com/koreader/koreader/issues/11852).

**Last updated:** March 20, 2026

### Installation

1. Download the patch: [2-brightness-tweaks.lua](https://github.com/mysiak/koreader.patches/blob/main/2-brightness-tweaks.lua)
2. Copy to KOReader's `patches` folder
3. Restart KOReader

Access via: **Settings → Cog wheel → Brightness tweaks**

### Features

**Minimum Brightness Protection:**
- Prevents swipe gestures from going below a set level (0–100)
- Manual brightness changes via menu remain unrestricted
- Set to 0 to disable

**Brightness Rounding:**
- Snaps gesture-based brightness to multiples of 5
- Does not affect manual adjustments

**Logarithmic Scale:**
- Exponential gesture steps — one swipe = one level up/down

**Automatic USB Brightness Management:**
- Reduces brightness automatically when USB charging is detected
- Saves and restores previous brightness after disconnect
- Restoration on next KOReader start if disconnected in PC link mode
- Manual brightness changes still allowed while charging
- Configurable target brightness level (default: 5%)

### Technical Details

- Polling-based detection every 2 seconds — compatible with devices where USB events don't fire through KOReader
- Polling only active when device is not suspended

### Known Limitations

- ~2-second delay between USB connection and brightness change
- Requires device to report charging state; may not work with all USB configurations
- No visual notification on brightness change

### Screenshot

<img width="400" alt="Brightness Tweaks Screenshot" src="https://github.com/user-attachments/assets/00644876-f799-4973-ab87-c4367233e17f" />
