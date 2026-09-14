<p align="center">
  <img src="docs/icon.png" width="120" alt="">
</p>

<h1 align="center">Nutip</h1>

Save anything as Markdown, for you and your AI. Copy something, press a key,
pick a tag, done. Nutip writes one `.md` file per clip into a folder you own,
and keeps an index an AI agent can read in one go.

No account, no permission to grant, no database you cannot open, no AI
inside. The folder is the product.

## Install

```sh
git clone https://github.com/GNRNicolas/nutip.git && cd nutip && ./build.sh --install
```

Builds it, puts it in `/Applications`, starts it, and links the `nutip`
command into your shell. Needs macOS 13+ and the Xcode command line tools
(`xcode-select --install`). No dependencies.

Nutip lives in the menu bar as a tray icon. The first launch asks for a
folder and your first tags.

## Use

Copy anything with **⌘C**, then press **⌥⌘S** (changeable). The palette opens
over whatever you are doing:

- Copied text becomes a text clip. A copied link becomes a link clip. Text
  copied from a web page in Safari, Chrome, Arc, Brave or Edge keeps the
  page it came from: the browser puts it on the clipboard, Nutip reads it.
- **↑↓** move through your tags, **1–9** (or **⌘1–9**) toggle them, several
  are fine. **←** jumps to a one-line note: *why* you are saving this.
- **→** saves. The palette closes at once; if there is a page, its readable
  text is fetched in the background and added to the file a couple of
  seconds later.

A small toast confirms, with **Undo** (⌘Z while it shows). Nothing to name,
nothing to file.

Press the hotkey with an empty clipboard, or click **Browse**, and the
palette opens in **browse** mode: type to search everything you saved (title, note, tags, text — `#tag`
restricts to a tag), **↩** opens the file in your editor, **⌘↩** opens the
original link, **⌘E** edits tags and note, **⌘⌫** deletes.

### The folder

```
Nutip/
  README.md              how the folder is laid out, for humans and agents
  INDEX.md               the 500 most recent clips, newest first
  tags/reading.md        the same list, one tag
  2026-09/
    2026-09-13-title-of-the-thing.md
```

One clip:

```markdown
---
title: "Markdown - Wikipedia"
url: https://en.wikipedia.org/wiki/Markdown
source: "Safari · en.wikipedia.org"
captured_at: 2026-09-13T14:03:22+02:00
tags: [reading, reference]
why: "the CommonMark history, for the docs"
---

# Markdown - Wikipedia

<https://en.wikipedia.org/wiki/Markdown>

The paragraph you had selected, if any.

---

**Markdown** is a lightweight markup language for creating formatted text…
```

Point the folder at your Obsidian vault, a Git repo, iCloud Drive — Nutip
does not care, and never needs to be running for the files to be useful.

### For AI agents

Give Claude, Cursor or ChatGPT the folder. `INDEX.md` fits in one read and
carries the `why` lines — the only thing an AI cannot infer. `tags/*.md`
narrows it. The generated `README.md` in the folder explains the layout to
whoever opens it, agent or human.

### Command line

The same binary is the CLI (`./build.sh --install` links it as `nutip`):

```sh
nutip recent 10                     # newest clips
nutip search "pricing #competitors" # full-text, #tag filters
nutip search claude --json          # for scripts and agents
nutip add https://example.com -t reading -w "the pricing table"
nutip extract https://example.com   # what a page becomes, on stdout
nutip reindex                       # rebuild INDEX.md, tags/ and the search index
```

## Permissions

None. Nutip reads the clipboard, which any app may do, and nothing else. It
never asks for Accessibility or Automation, so nothing breaks when you
rebuild or update. That is why the gesture is *copy, then hotkey* rather
than *select, then hotkey*: reading a selection would need a permission
that macOS revokes at every reinstall of an unsigned app.

## Update

Nutip checks GitHub once a day and tells you when a release is out. It
downloads nothing; the update is:

```sh
git pull && ./build.sh --install
```

Turn the check off in the menu.

## Privacy

Nutip talks to the network twice: to fetch a page you just saved (through a
hidden web view, no cookies, forgotten afterwards) and to ask GitHub for the
latest version number, once a day, anonymously. Nothing else leaves your Mac.
The clipboard is read only when you press the hotkey, never watched.
Logs go to `~/Library/Logs/nutip.log`.

## Fork it

[FORKME.md](FORKME.md) is for changing the app; [SPECS.md](SPECS.md) for why
it is shaped this way. MIT.
