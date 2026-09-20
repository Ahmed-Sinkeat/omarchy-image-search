# omarchy-image-search

[![CI](https://github.com/Ahmed-Sinkeat/omarchy-image-search/actions/workflows/ci.yml/badge.svg)](https://github.com/Ahmed-Sinkeat/omarchy-image-search/actions/workflows/ci.yml)

Select a region of your screen and reverse-image-search it with Google Lens, on
[Omarchy](https://omarchy.org) / Hyprland.

Two keybindings: one searches in your normal browser session, one in a private
window. The capture never touches persistent storage, and the desktop unfreezes
as soon as the region is grabbed — the upload happens afterwards.

## Requirements

Omarchy provides most of these already:

| Needs | For |
| --- | --- |
| `hyprctl`, `jq` | reading the cursor setting |
| `grim` | the capture |
| `pkill` (procps-ng) | dismissing an already-open selector |
| `base64`, `mktemp`, `date` (coreutils) | building the upload page |
| `setsid` (util-linux) | deleting the page after the browser reads it |
| `omarchy-capture-region`, `omarchy-launch-browser`, `omarchy-notification-send` | Omarchy |
| A browser | verified on Helium, Chromium and Zen |

## Install

```sh
./install.sh
```

It copies the script into `~/.local/bin` and prints the two lines to add to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + PRINT", "Search screen with Google Lens", "omarchy-capture-image-search")
o.bind("SUPER + SHIFT + ALT + PRINT", "Search screen with Google Lens (private)", "omarchy-capture-image-search --private")
```

Then `hyprctl reload`.

## Usage

```
omarchy-capture-image-search [--private] [smart|region|windows|fullscreen]
```

Drag to select a region, or click once to snap to a window. Results open in
about 1–2 seconds.

## How it works

1. `grim` writes the selection to `$XDG_RUNTIME_DIR` (tmpfs, mode `600`).
2. The freeze is released — the desktop is usable while the upload runs.
3. A throwaway local HTML page embeds the capture, rebuilds it as a browser
   `File` via `DataTransfer`, and submits Google's own Lens upload form.
4. The browser opens that page; the form POST navigates straight to the results.
5. The PNG is deleted immediately; the page 30 seconds later
   (`LENS_PAGE_TTL` to tune).

The upload and the results share one browser session, which is why the results
actually render.

## Privacy

With `--private` the browser opens an incognito window, so the upload carries no
Google account session. Without it, results land in your normal signed-in
session and Google can associate them with your account.

The capture is written only to your user-private runtime directory and is
removed after use. If the delayed cleanup is ever killed, the page file remains
there (mode `600`, RAM-backed) until logout.

Google receives the selected region. That is the point of the tool, but it is
worth saying plainly.

## Why this approach

Other routes were tried and measured, not guessed:

| Route | Result |
| --- | --- |
| **Local page + top-level form POST** | **Works.** Full results in ~1s, every browser tested, private mode included. |
| `curl` upload to `lens.google.com/v3/upload` | Endpoint returns `303` with a result URL, but that URL renders a page that never finishes loading. |
| In-page `fetch()` to the same endpoint | Blocked by CORS. A top-level form POST is exempt, which is the whole trick. |
| Clipboard paste into the Lens panel | Works, but needs `wtype`, a focused window, and Google's internal `jsname` selector. |
| Automating the GTK file chooser | Works, but needs AT-SPI, `wtype`, and window polling — ~200 extra lines. |
| Chrome DevTools `DOM.setFileInputFiles` | Injects the file but never submits; also needs a debug port on your daily browser. |
| Bing anonymous upload | Works via plain `curl`, but identifies images far less accurately. |

## Limitations

- Depends on Google's upload form fields (`encoded_image`) staying put. If
  Google changes them, the page stops working and needs a one-line fix.
- Brave did not get past its first-run onboarding in testing.
- Results language follows your Google locale.

## Test

```sh
./test-image-search.sh
```

Stubs the compositor, capture and browser; asserts the freeze is released before
launch, the PNG is removed, the page carries the right payload, `--private`
propagates, and that the old `wtype`/`gdbus`/`curl` paths are never used.

## License

MIT
