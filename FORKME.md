# Forking Nutip

Written for whoever picks this up next, human or agent. [SPECS.md](SPECS.md)
explains *why* the code is shaped the way it is; this file is about
*changing* it.

The app is a handful of Swift files in `Sources/`, no dependencies, no
package manager, plus two JavaScript files in `Resources/`. `./build.sh`
compiles it: about a minute from a cold clone, fifteen seconds once Swift's
module cache is warm. Measured on an M-series Mac.

`./Tools/test.sh` drives the CLI against a throwaway folder and is the test
harness for everything under the UI: the file format, the index pages, the
search, and what happens when a nut on disk is malformed. It refuses to run
anywhere near your real folder. Run it before you push; CI runs it too. The
palette itself has no automated test — it is checked by hand.

## Make it yours first

Fork and rename before anything else, or your users will get update prompts
pointing at the upstream repo.

| What | Where |
|---|---|
| Update source | `Sources/Updater.swift`, `repository` and `homepage` |
| App name | `build.sh`, `NAME=`; `Sources/Support.swift`, `Settings.appName` |
| Bundle identifier | `build.sh`, `ID=` |
| Version | `build.sh`, `VERSION=` and `BUILD=` |
| Icon | replace `Resources/icon.png`, a square 1024×1024 PNG with the rounded square drawn in, then delete `Resources/Nutip.icns` |
| Emoji fallback icon | `Tools/makeicon.swift`, `emoji` |
| Copyright | `LICENSE` |
| Clone URL and screenshots | `README.md`, `docs/` |

## Where things are

| To change | Edit |
|---|---|
| Default tags, default folder, index length | `Settings` in `Support.swift` |
| The tag list and its undo | `Preferences.tagsBox`, `addTag`/`removeSelectedTags`/`undoTags` |
| Hotkey presets | `Hotkey` in `Shortcuts.swift`, one line per preset |
| The frontmatter, the file body | `Store.render` and `Store.parse` (keep them symmetrical) |
| File and folder naming | `Store.add` (`YYYY-MM/YYYY-MM-DD-slug.md`) |
| INDEX.md layout | `Store.rootIndex` |
| tags/*.md and monthly pages | `Store.index(title:subtitle:nuts:…)` |
| Which pages a save rewrites | `Store.regenerateIndexes(months:tags:full:)` |
| The folder README and AGENTS.md | `Store.writeReadme`, `Store.writeAgents` |
| How much page text a nut keeps | `Settings.bodyLimit` |
| Which pasteboard types reveal the source page | `Capture.sourcePage` |
| HTML → Markdown rules | `Resources/tomarkdown.js` |
| Palette keys | `Palette.handleEverywhere`, `handleTagMode`, `handleBrowse` |
| Palette wording per mode | `Palette.showCapture`, `showEdit`, `showBrowse` |
| Palette layout | the `make…` functions in `Palette`, assembled by `assemble(in:)` |
| Palette size and row heights | the `static let`s at the top of `Palette` |
| Toast duration | `Toast.show`, the `Timer` |
| CLI commands | `CLI.run` |
| What an agent is told about the CLI | `skills/nutip/SKILL.md` |
| What an agent is told about the folder | `Store.writeAgents` |

## Build and run

```sh
./build.sh              # → build/Nutip.app
./build.sh --install    # → /Applications, started, `nutip` linked in the shell
```

Point a build at a scratch folder without touching your preferences:

```sh
NUTIP_DIR=/tmp/nuts build/Nutip.app/Contents/MacOS/Nutip add "hello" -t test
NUTIP_DIR=/tmp/nuts build/Nutip.app/Contents/MacOS/Nutip recent
NUTIP_DIR=/tmp/nuts build/Nutip.app/Contents/MacOS/Nutip   # the GUI, same folder
```

`nutip extract <url>` prints what a page turns into: the fastest way to
work on `tomarkdown.js`.

Log: `~/Library/Logs/nutip.log`. Every refused hotkey, failed extraction and
index error lands there with a reason.

## Things that bite

- **Do not add a TCC permission lightly.** Accessibility and Automation
  grants are tied to the code signature, and an ad-hoc signature changes at
  every build: users would re-grant at every update. Nutip went through this
  and came back to the clipboard. If you need one, ship a Developer ID build.
- **A borderless NSPanel gets no key events** until `canBecomeKey` returns
  true (`KeyPanel`). Every "the shortcuts do nothing" bug starts here.
- **Rounded corners on a blurred panel** need `maskImage`, not `cornerRadius`.
- **A subview added to an NSScrollView is invisible**: the nut view covers
  it. The empty-state label lives in the panel, constrained to the scroll view.
- **`Store.render` and `Store.parse` must stay symmetrical.** `parse` strips
  the H1 and bare URL `render` writes; add a line to one, teach the other
  about it, or every re-save duplicates it.
- **A tag is a slug.** Anything that stores or compares a tag goes through
  `Slug.tag`; a raw string would create a second, near-identical tag.
- **Generated files are recognised by `Store.marker`.** Change its text and
  every existing INDEX and tag page becomes "the user's", never rewritten
  again. Bump it deliberately or not at all.
- **The palette reads the clipboard before it appears.** `Capture.current()`
  also asks `NSWorkspace` which app is frontmost, for the `source` field, so
  anything that activates Nutip first (an alert, a window) records Nutip
  instead of the app the user was in.
- **Nothing that runs after a save may read the whole folder.** Index pages
  are written from `Index` rows, and `Index.sync()` only opens files whose
  modification date or size changed. Calling `Store.all()` in a save path
  puts the folder back to O(everything) per nut.
- **An index row has no body** (`bodyLoaded == false`). `Store.save` reloads
  it before writing; if you add another writer, do the same or you will blank
  files.
- **Adding a column to `nuts` means bumping `Index.schema`**, which drops the
  database and rebuilds it. There is no migration and there should not be one.
- **A stored `NSMenuItem` can only belong to one menu.** `buildMenu` removes
  its items from their old menu first; hand `NSMenu` an item that still has
  one and the app aborts on an assertion, with a stack that blames the menu
  rather than the second call.
- **The SQLite index is disposable.** If a search looks wrong, `nutip
  reindex` (or the menu item) rebuilds it from the files. Never fix the
  database by hand; fix the parser.
