# SWIFT_RADIO

A macOS radio streaming player with real-time audio visualization and keyboard-first navigation. Streams internet radio stations from the Radio Browser API inside a compact 300×520px floating panel.

---

## Getting Started

### Requirements

- macOS (SwiftUI required)
- Xcode
- Network access

### Installation

1. Create a new SwiftUI project in Xcode
2. Delete the default `ContentView.swift` and `<AppName>App.swift`
3. Add `RadioStation.swift` to the project
4. In Xcode, go to **Signing & Capabilities → App Sandbox** and enable **Outgoing Connections (Client)**
5. Press **⌘R** to build and run

---

## Interface Overview

The UI is divided into two main areas:

**Home Panel** — shows your Favorites and Recents lists. Use `←/→` to switch between them.

**All Stations Browser** — a searchable, genre-filtered catalog of live radio stations fetched from Radio Browser.

A transport bar at the top provides **`<<`**, **`■/▶`**, and **`>>`** buttons for sweep navigation and play/pause.

The visualizer below the transport shows a 6-band frequency spectrum that reacts to live audio.

---

## Controls

### Global (anywhere)

| Key | Action |
|-----|--------|
| `Space` | Toggle play / pause |
| `V` | Cycle visualizer preset |
| `D` | Toggle the debug/tweak panel |
| `?` | Show the keyboard shortcut cheatsheet |

The cheatsheet also appears automatically on first launch and can be dismissed with any key (or a click outside the panel).

### Home Panel (Favorites & Recents)

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move selection up / down |
| `j` / `k` | Vim-style up / down |
| `Home` / `End` | Jump to first / last item |
| `PageUp` / `PageDown` | Scroll by 5 items |
| `←` / `→` | Switch between Favorites and Recents |
| `Shift+←` / `Shift+→` | Play previous / next station |
| `Enter` | Play selected station |
| `Cmd+]` | Jump to All Stations browser |
| `Cmd+F` or `/` | Open search in All Stations |
| `M` or `Shift+F10` | Open context menu |
| `Cmd+Delete` | Remove selected station from Favorites (asks to confirm) |

### All Stations Browser

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move selection up / down |
| `j` / `k` | Vim-style up / down |
| `Home` / `End` | Jump to first / last |
| `PageUp` / `PageDown` | Scroll by 5 items |
| `←` / `→` | Switch genre tab (exits browser at leftmost tab) |
| `Enter` | Play selected station |
| `F` | Toggle favorite on selected station |
| `S`, `Cmd+F`, or `/` | Open search bar |
| `Cmd+[` | Back to Home |
| `Esc` | Clear search filter, or exit browser if no filter active |
| `M` or `Shift+F10` | Open context menu |

### Search Bar (Global Command Palette)

Open from anywhere with `Cmd+K` (or `Cmd+F`, `/`, or `S` inside the browser). Queries run
live against the Radio Browser API — not just the current list — so you can find any
of ~40k stations in a single bar.

The bar intelligently parses a single input into multiple fields:

| You type | Parsed as |
|----------|-----------|
| `Jazz Israel` | tag=jazz, country=IL |
| `United States NPR` | country=US, name="NPR" |
| `News` | tag=news |
| `KAN GIMEL` | name="KAN GIMEL" |

| Key | Action |
|-----|--------|
| Type | Runs a debounced (300ms) API search across name, country, and genre |
| `Backspace` | Remove last character (closes bar when empty) |
| `↓` | Move focus into results list |
| `Enter` | Play highlighted result and close search |
| `Esc` | Clear query and close search bar |

### Context Menu

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move between items |
| `Tab` | Cycle forward through items |
| `Enter` / `Space` | Execute focused action |
| `Esc` | Close menu |

### Confirm Delete Dialog

| Key | Action |
|-----|--------|
| `↑` | Focus **Cancel** |
| `↓` | Focus **Remove** |
| `Tab` | Toggle between buttons |
| `Enter` / `Space` | Execute focused button |
| `Esc` | Cancel |

### Mouse / Trackpad

- Click a station row to play it
- Click genre tabs to switch categories
- Click `< >` arrows on the Home panel to switch Favorites / Recents
- Click the **All Stations** link to enter browse mode
- Click transport buttons (`<<`, `■/▶`, `>>`) to control playback

---

## Genres

The All Stations browser ships with four genre tabs:

| Tab | Description |
|-----|-------------|
| **All Stations** | Mix of top-voted MP3 stations worldwide |
| **News** | News and talk radio |
| **Jazz** | Jazz stations |
| **Rock** | Rock and alternative stations |

Stations are fetched from the Radio Browser API filtered to MP3 streams at 96 kbps or higher, sorted by community votes.

---

## Visualizer Presets

Press **`V`** to cycle through three built-in presets:

| Preset | Character |
|--------|-----------|
| **Pulsar Bloom** | Smooth, uniform expansion — gentle breathing effect |
| **Fixed Grow** | Static grow with strong radius scaling — circles swell in place |
| **Kinetic Weave** | Weighted sizing without uniform scaling — individual band motion |

---

## Tweak Panel (Advanced)

Press **`D`** to open the live parameter editor. Changes take effect immediately.

| Parameter | Range | Default | Effect |
|-----------|-------|---------|--------|
| Smoothness | 0 – 0.99 | 0.75 | Frame interpolation damping; higher = more fluid |
| Uniformity | 0 – 1.0 | 0.07 | Blend individual band levels toward their average |
| Y-Sensitivity | 0 – 50 | 0.11 | Vertical offset magnitude per band |
| Scale Power | 0 – 5 | 1.00 | Radius scale multiplier |
| Base Size | 5 – 100 | 5 | Circle diameter in pixels |
| Spacing | 0 – 100 | 12.5 | Gap between circles |
| Y-Limit | 10 – 500 | 500 | Maximum vertical offset |

---

## Favorites & Recents

- **Favorites** are saved to `UserDefaults` and persist across launches.
- **Recents** tracks the last 20 played stations automatically.
- Press `F` on any station in the browser to add or remove it from Favorites.
- Press `Cmd+Delete` on a Favorite in the Home panel to remove it (with confirmation).

On first launch, four default stations are loaded:

- SomaFM Groove Salad
- KEXP 90.3 FM Seattle
- NTS Radio 1
- dublab

---

## Tips

- The entire app is usable without a mouse — every panel is fully keyboard-navigable.
- If a stream fails to load, the player retries alternate URLs automatically before showing an error.
- The search bar filters across station name, tags, country, codec, and bitrate as you type.
- Station metadata (codec, bitrate, votes, country) is shown in small text beneath each station name.
