# Forking Nutip

Written for whoever picks this up next, human or agent. [SPECS.md](SPECS.md)
explains *why* the code is shaped the way it is; this file is about
*changing* it.

The app is a handful of Swift files in `Sources/`, no dependencies, no
package manager, plus two JavaScript files in `Resources/`. `./build.sh`
compiles it in a few seconds. There is no test suite for the UI; the CLI is
the test harness for everything under it.

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
| Hotkey presets | `Hotkey` in `Shortcuts.swift` — one line per preset |
| The frontmatter, the file body | `Store.render` and `Store.parse` (keep them symmetrical) |
| File and folder naming | `Store.add` (`YYYY-MM/YYYY-MM-DD-slug.md`) |
| INDEX.md / tags/*.md layout | `Store.index(title:clips:total:depth:)` |
| The folder README | `Store.writeReadme` |
| Which pasteboard types reveal the source page | `Capture.sourcePage` |
| HTML → Markdown rules | `Resources/tomarkdown.js` |
| Palette keys and hints | `Palette.handle` and the `hints.stringValue` lines in `Palette.show` |
| Palette size and row heights | the `static let`s at the top of `Palette` |
| Toast duration | `Toast.show`, the `Timer` |
| CLI commands | `CLI.run` |

## Build and run

```sh
./build.sh              # → build/Nutip.app
./build.sh --install    # → /Applications, started, `nutip` linked in the shell
```

Point a build at a scratch folder without touching your preferences:

```sh
NUTIP_DIR=/tmp/clips build/Nutip.app/Contents/MacOS/Nutip add "hello" -t test
NUTIP_DIR=/tmp/clips build/Nutip.app/Contents/MacOS/Nutip recent
NUTIP_DIR=/tmp/clips build/Nutip.app/Contents/MacOS/Nutip   # the GUI, same folder
```

`nutip extract <url>` prints what a page turns into — the fastest way to
work on `tomarkdown.js`.

Log: `~/Library/Logs/nutip.log`. Every refused hotkey, failed extraction and
AppleScript error lands there with a reason.

## Things that bite

- **Do not add a TCC permission lightly.** Accessibility and Automation
  grants are tied to the code signature, and an ad-hoc signature changes at
  every build: users would re-grant at every update. Nutip went through this
  and came back to the clipboard. If you need one, ship a Developer ID build.
- **A borderless NSPanel gets no key events** until `canBecomeKey` returns
  true (`KeyPanel`). Every "the shortcuts do nothing" bug starts here.
- **Rounded corners on a blurred panel** need `maskImage`, not `cornerRadius`.
- **A subview added to an NSScrollView is invisible**: the clip view covers
  it. The empty-state label lives in the panel, constrained to the scroll view.
- **`Store.render` and `Store.parse` must stay symmetrical.** `parse` strips
  the H1 and bare URL `render` writes; add a line to one, teach the other
  about it, or every re-save duplicates it.
- **A tag is a slug.** Anything that stores or compares a tag goes through
  `Slug.tag`; a raw string would create a second, near-identical tag.
- **Generated files are recognised by `Store.marker`.** Change its text and
  every existing INDEX and tag page becomes "the user's", never rewritten
  again. Bump it deliberately or not at all.
- **The palette reads the selection before it appears.** Anything that
  activates Nutip before `Capture.current()` runs (an alert, a window) makes
  Nutip the frontmost app and the selection is lost.
- **The SQLite index is disposable.** If a search looks wrong, `nutip
  reindex` (or the menu item) rebuilds it from the files. Never fix the
  database by hand; fix the parser.
