# Implementation notes

What is worth knowing before changing Nutip — the decisions, and the ones
that were rejected.

## Shape of the app

`Sources/*.swift`, compiled as one module by `swiftc`, no package manager.
`main.swift` holds the top-level code; everything else is a type per file.

| File | Type | Job |
|---|---|---|
| `Support.swift` | `Log`, `Settings`, `Slug`, `Dates` | Preferences and helpers |
| `Store.swift` | `Clip`, `Store` | Markdown files in, Markdown files out; INDEX and README generation |
| `Index.swift` | `Index` | SQLite FTS5 over the clips, rebuilt from the files |
| `Capture.swift` | `CaptureContext`, `Capture` | The clipboard, and the page it was copied from |
| `Extractor.swift` | `Extractor` | Hidden `WKWebView` + Readability.js + `tomarkdown.js` |
| `Palette.swift` | `Palette` | The floating panel and its three modes |
| `Toast.swift` | `Toast` | Saved confirmation with Undo |
| `Preferences.swift` | `Preferences` | Onboarding and settings, one window |
| `Shortcuts.swift` | `Hotkey`, `GlobalHotkey` | The global shortcut (Carbon) |
| `Updater.swift` | `Updater` | Daily version check against GitHub |
| `CLI.swift` | `CLI` | `nutip search|recent|add|extract|reindex` |
| `main.swift` | `AppDelegate` | Menu bar, wiring, the save flow |

The save flow is: hotkey → `Capture.current()` reads the clipboard →
`Palette.show(.capture)` → user
presses return → `Store.add` writes the file, `Toast` appears → if there was a
URL, `Extractor` fetches it and `Store.append` completes the file. The
palette is gone before the network is touched.

## The folder is the product

Everything Nutip knows is in the Markdown files. The SQLite index is a cache
rebuilt from them at every launch (`Index.open` → `rebuild`), and lives in
`~/Library/Application Support/Nutip/`, keyed by folder path. Delete it and
nothing is lost. This is what lets the user keep the folder in Git, Obsidian,
iCloud or Dropbox without Nutip being involved.

### One file per clip

Appending to one file per tag was the first idea. Rejected: an append is the
operation that goes wrong under sync (two devices, one file), it forces a
single tag per clip, and it has no place for per-clip metadata. One file per
clip has none of those problems and costs a monthly sub-folder so the Finder
stays usable at a few thousand files.

### Tags, not folders

A clip can be about a competitor *and* about pricing. Folders cannot say
that; tags can. Tags are slugs (`Slug.tag`): `#Pricing Model`,
`pricing-model` and `Pricing model` are one tag, so the user never ends up
with three spellings of the same thing. Renaming a tag in Preferences does
not touch existing clips — a rewrite of every file is exactly the kind of
surprise a tool like this must not produce.

### Generated files carry a marker

`INDEX.md`, `tags/*.md` and the folder `README.md` start with an HTML
comment. It says "do not edit" to a human, and it is how Nutip recognises
its own files: a `tags/x.md` without the marker is never deleted, a `README`
without it is never overwritten. The user can take over any of them.

The index lists the 500 most recent clips (`Settings.indexLimit`), not all
of them: it is what an AI reads first, and it must fit in one read.

### Frontmatter is deliberately dumb

Quoted strings, a flow list for tags, ISO 8601 with offset. No YAML library
on either side: `Store.render` writes it, `Store.parse` reads it with a
`firstIndex(of: ":")`. Nutip only has to round-trip its own output; the
human-readable and tool-readable properties matter more than YAML coverage.

## Capture: the clipboard, and only the clipboard

The gesture is **copy, then hotkey**. Zero permissions, by decision, after
the alternative was built and thrown away:

- Reading the selection through Accessibility (`kAXSelectedTextAttribute`,
  with a simulated ⌘C as fallback) worked in native apps, not in Notion,
  WhatsApp or terminals, and needed the Accessibility grant.
- Asking the browser for its page through AppleScript worked for Safari and
  every Chromium, not Firefox, and needed the Automation grant.
- Both grants are tied to the code signature. An ad-hoc signature changes at
  every build, so **every update silently revoked them**, and the app fell
  back to the clipboard anyway with no way to tell the user why. For a tool
  that people install with `git pull && ./build.sh`, that is not a corner
  case, it is every update.

A gesture with one extra key beats a permission dialog that comes back at
each release. What the clipboard gives without asking:

- The text (`public.utf8-plain-text`), or a bare URL, which becomes a link clip.
- **The page the text was copied from**: Chromium browsers write
  `org.chromium.source-url`, Safari a `com.apple.webarchive` whose main
  resource carries the URL, some apps `WebURLsWithTitlesPboardType`.
  `Capture.sourcePage` reads all three. Firefox writes none.
- The frontmost app's name, from `NSWorkspace`, for the `source` field.

`CaptureContext.changeCount` remembers the pasteboard generation of the last
clip saved; pressing the hotkey again without copying anything new shows an
orange "same clipboard" line rather than silently duplicating.

## Extraction without an HTML parser

A hidden `WKWebView` loads the page and runs two scripts: Mozilla's
`Readability.js` (the same one Firefox Reader View uses, Apache 2.0) to find
the article, and `Resources/tomarkdown.js`, ~150 lines that walk the resulting
DOM into Markdown. Rejected alternatives: writing a readability heuristic
(months to match Mozilla's), a Swift HTML→Markdown library (a dependency, and
still worse than running the real DOM), plain `URLSession` (no JavaScript, so
no SPA). The web view uses a non-persistent data store — no cookies of the
user's session, nothing kept. Pages behind a login therefore extract nothing
beyond what was selected; that is by design in v1.

The extraction runs **after** the palette has closed and appends to the
file. If the user pressed Undo in the meantime, `AppDelegate.extract` finds
the file gone and drops the result.

## The palette is a non-activating panel

`NSPanel` with `.nonactivatingPanel`: it takes key events without making
Nutip the active app, so the user's window keeps focus and nothing shifts.
A borderless panel refuses to become key by default (`canBecomeKey` is
false), which is what `KeyPanel` exists for; without it no key reaches the
palette at all. Rounded corners are an `NSVisualEffectView.maskImage`: the
behind-window blur is drawn by the window server and ignores a layer's
`cornerRadius`.
Keys are handled by one local event monitor in `Palette.handle`, in this
order: keys that mean the same everywhere (esc, ↑↓, return), then the
mode's own. The capture flow is arrows only: ↑↓ pick a tag, ← goes to the
note (and back to the list from the start of the note), → saves (from the
end of the note). Digits are read by **key code** (the physical digit row),
so `1` and `⌘1` toggle the first tag on an AZERTY keyboard without Shift.
Every key also has a button in the footer, with its shortcut printed after
the label. Browse remembers the capture it was opened from, and esc returns
to it.

## Global shortcut

`RegisterEventHotKey` (Carbon) — the API launchers use, no permission
needed, consumes the keystroke. Unlike Eyesaver it stays registered for the
whole session: a clipper is asked for at any moment. Conflicts cannot be
detected (macOS accepts a duplicate registration silently); the menu bar
item is the way in when the key seems dead, and the preset list avoids
combinations the system uses.

## The CLI is the same binary

`main.swift` calls `CLI.run` before `NSApplication` exists. With arguments,
the process prints and exits; without, it becomes the menu bar app.
`Bundle.main` still resolves to the `.app`, so preferences are shared.
`nutip extract` spins a run loop around the same `Extractor`, which is how the
Markdown output is tested without the GUI. `nutip add` does not extract
pages: it is meant for scripts, and a script can pipe `nutip extract` into
it if it wants the text.

## What v1 leaves out, on purpose

- **AI inside the app.** Summaries, auto-tags, suggested destinations.
  The folder is built so any agent can do that from outside.
- **An MCP server.** The folder plus `nutip search --json` is the
  interface; a server is a second deliverable.
- **Images, screenshots, PDFs.** Text only.
- **iOS / Share Sheet.** Put the folder in iCloud Drive and this becomes
  possible later; nothing in the format prevents it.
- **Git.** The folder is often a repo; Nutip never runs `git`.
