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
| `base64`, `mktemp`, `date`, `find` (coreutils) | building the upload page, sweeping stale ones |
| `curl` | `--bing` only |
| `magick` (imagemagick, optional) | capping capture size before upload |
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
omarchy-capture-image-search [--private] [--bing] [smart|region|windows|fullscreen]
```

Drag to select a region, or click once to snap to a window. Results open in
about 1–2 seconds, as a tab in your running browser (`--private` gets its own
incognito window, since that is what an incognito flag does).

`--bing` searches Bing instead. It needs no local page at all — Bing answers an
anonymous upload with a result URL that stands on its own. Useful as a fallback
if Google ever changes its form, though its identification is noticeably weaker.

| Variable | Default | |
| --- | --- | --- |
| `LENS_MAX_DIMENSION` | `2000` | Longest edge sent to Lens. `0` disables resizing. |
| `BING_MAX_DIMENSION` | `1600` | Longest edge sent to Bing. |
| `LENS_PAGE_TTL` | `120` | Seconds before the upload page is deleted. |
| `LENS_STALE_MINUTES` | `5` | Age at which a leftover page is swept on the next run. |

## How it works

1. `grim` writes the selection to `$XDG_RUNTIME_DIR` (tmpfs, mode `600`).
2. The freeze is released — the desktop is usable while the upload runs.
3. The capture is capped at 2000px if ImageMagick is installed. It only ever
   shrinks, and a failed convert falls back to the full-size capture.
4. A throwaway local HTML page embeds it, rebuilds it as a browser `File` via
   `DataTransfer`, and submits Google's own Lens upload form.
5. The browser opens that page; the form POST navigates straight to the results.
6. The image is deleted immediately; the page after `LENS_PAGE_TTL` seconds. Any
   page whose cleanup never ran is swept at the start of the next search, so a
   killed timer cannot leave your capture sitting there until logout.

Bing skips steps 4–6: it takes a JPEG (a full-size PNG is past its payload
limit) over `curl` and hands back a result URL the browser opens directly.

The upload and the results share one browser session, which is why the results
actually render.

## Privacy

With `--private` the browser opens an incognito window, so the upload carries no
Google account session. Without it, results land in your normal signed-in
session and Google can associate them with your account.

The capture is written only to your user-private runtime directory and is
removed after use. If the delayed cleanup is ever killed, the page is swept at
the start of the next search rather than lingering until logout.

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
| Bing anonymous upload | Works via plain `curl`. Shipped as `--bing`, but it identifies images far less accurately, and rejects payloads past roughly a megabyte. |

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
