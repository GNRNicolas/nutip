# Implementation notes

What is worth knowing before changing Nutip: the decisions, and the ones
that were rejected.

## Shape of the app

`Sources/*.swift`, compiled as one module by `swiftc`, no package manager.
`main.swift` holds the top-level code; everything else is a type per file.

| File | Type | Job |
|---|---|---|
| `Support.swift` | `Log`, `Settings`, `Slug`, `Dates` | Preferences and helpers |
| `Store.swift` | `Nut`, `Store` | Markdown files in, Markdown files out; INDEX and README generation |
| `Index.swift` | `Index` | SQLite FTS5 over the nuts, rebuilt from the files |
| `Capture.swift` | `CaptureContext`, `Capture` | The clipboard, and the page it was copied from |
| `Extractor.swift` | `Extractor` | Hidden `WKWebView` + Readability.js + `tomarkdown.js` |
| `Tidy.swift` | `Tidy` | The pass between the extractor and the file: no pictures, no stray space |
| `Palette.swift` | `Palette` | The floating panel and its three modes |
| `PaletteViews.swift` | `KeyPanel`, `TagCell`, `NutCell` | The panel subclass and the rows |
| `Preview.swift` | `PreviewPane` | The pane beside the browse list: what the highlighted nut says |
| `Toast.swift` | `Toast` | Saved confirmation with Undo |
| `Backdrop.swift` | `Backdrop`, `Wash` | The screen dimmed behind the palette |
| `Preferences.swift` | `Preferences` | Onboarding and settings, one window |
| `Shortcuts.swift` | `Hotkey`, `GlobalHotkey` | The global shortcut (Carbon) |
| `Updater.swift` | `Updater` | Daily version check against GitHub |
| `CLI.swift` | `CLI` | `nutip search|recent|add|rm|extract|filters|enrich|tags|folder|reindex|doctor` |
| `main.swift` | `AppDelegate` | Menu bar, wiring, the save flow |

The save flow is: hotkey → `Capture.current()` reads the clipboard →
`Palette.show(.capture)` → user
presses → → `Store.add` writes the file, `Toast` appears → if there was a
URL, `Extractor` fetches it and `Store.append` completes the file. The
palette is gone before the network is touched.

## The folder is the product

Everything Nutip knows is in the Markdown files. The SQLite index is a cache
brought back in line with them at every launch (`Index.open` → `sync`, which
reads only the files whose size or date changed) and rebuilt from scratch only
on `nutip reindex`. It lives in
`~/Library/Application Support/Nutip/`, keyed by folder path. Delete it and
nothing is lost. This is what lets the user keep the folder in Git, Obsidian,
iCloud or Dropbox without Nutip being involved.

### A folder that is not there

The path in the preferences stops resolving more often than it looks: a Mac
restored under another user name, a folder renamed in the Finder, a vault moved,
an external disk left at home. Nutip used to call `createDirectory` on the way
in and carry on. That is the wrong answer twice over — an empty folder appears
where the old one was, the nuts look lost, and the real ones are still sitting
wherever the user left them; and when the parent is not writable either, the
only thing said is Cocoa's own "you don't have permission to save the file", a
sentence that names neither the path nor a way out.

So `Store.missingFolder` is asked before anything writes, and everything that
writes stops: `ensureFolder`, `regenerateIndexes`, launch, browse, Open Folder.
The app names the path and offers the two answers that exist — point Nutip at
the folder again, or start a new one there — and the nut that was being saved
is held and written once the question is answered, because losing it to a
dialog would be the third wrong answer. `nutip doctor` marks the folder
`⚠ not found`.

Creating a folder is left to the moment someone names one: the panel in
Preferences, `nutip folder <path>`, and `NUTIP_DIR`, which is a folder asked
for by the command at hand rather than one the preferences merely remember.

### One file per nut

Appending to one file per tag was the first idea. Rejected: an append is the
operation that goes wrong under sync (two devices, one file), it forces a
single tag per nut, and it has no place for per-nut metadata. One file per
nut has none of those problems and costs a monthly sub-folder so the Finder
stays usable at a few thousand files.

### Tags are edited as a list, and removals are undoable

The first version used an `NSTokenField`: compact, native, and one ⌘A away
from wiping every tag with no way back. Tags are now a table with + and −,
renamed in place. A removal writes straight through to preferences, with no
confirmation dialog, because ⌘Z takes it back (⇧⌘Z redoes it) and the line
under the list says how many nuts carried the tag. The app has no menu bar,
so ⌘Z is caught by a local event monitor that lives only while the window is
key, and by key code rather than by character so it works on AZERTY.

### Tags, not folders

A nut can be about a competitor *and* about pricing. Folders cannot say
that; tags can. A tag keeps the letters that were typed, capitals and accents
included (`Pricing-Model`, `Réflexions`); only what would break a file name, a
relative link or a `#tag` in a query is folded away, so a space becomes a dash
(`Slug.tag`). Comparison is a different question from spelling: two tags are
the same when their `tagKey` matches, which is case- and accent-insensitive,
the same folding the search index uses. So `Reading`, `reading` and `réading`
are one tag with one page, named the way Settings spells it, or failing that
the way most files do. Renaming a tag in Preferences does
not touch existing nuts: a rewrite of every file is exactly the kind of
surprise a tool like this must not produce.

### A save costs the same at ten nuts and at ten thousand

The folder is meant to be saved into without thinking, so the cost of a nut
must not grow with the folder. Two rules keep it flat:

- **The index is read from SQLite, never from the files.** `Store.stamps()`
  lists the folder and its modification dates, `Index.sync()` reads only the
  files that appeared or changed, and every index page is written from rows
  the database already holds. Before this, saving re-read and re-parsed every
  nut: 7 s and 137 MB of reading on a folder of 5 000, at every single save.
  It is now under half a second.
- **Only the pages that mention the nut are rewritten**: the root `INDEX.md`,
  the nut's month, and the tags it gained or lost. `nutip reindex` (or a
  folder that changed behind Nutip's back) rewrites everything.

The index rows carry no body, which is what makes them cheap. A row that
comes back from a search therefore has `bodyLoaded == false`, and `Store.save`
reloads the body from the file before writing: an edit of tags or of the note
can never truncate a nut.

### One nut stays readable in one go

An extracted page is capped at `Settings.bodyLimit` (40 000 characters, a few
long articles' worth) with a line saying so and the link to the rest. Nothing
in the folder should cost an agent its context window to open, and past that
length the link is worth more than the text.

### Generated files carry a marker

`INDEX.md`, `AGENTS.md`, the folder `README.md`, `tags/*.md` and
`YYYY-MM/INDEX.md` start with an HTML
comment. It says "do not edit" to a human, and it is how Nutip recognises
its own files: a `tags/x.md` without the marker is never deleted, a `README`
without it is never overwritten. The user can take over any of them.

The root index lists the 500 most recent nuts (`Settings.indexLimit`), not
all of them: it is what an AI reads first, and it must fit in one read. What
it loses in depth it makes up in shape: the totals, every tag and every
month as a link, so one read tells an agent what the folder holds and where
to go next. `YYYY-MM/INDEX.md` is the complete list for one month, bounded by
the month itself; `tags/<tag>.md` is the same for one tag. A tag with no nuts
has no page.

`AGENTS.md` is generated alongside `README.md`: same facts, written for an
agent rather than a person, and named what the tools look for.

### Frontmatter is deliberately dumb

Quoted strings, a flow list for tags, ISO 8601 with offset. No YAML library
on either side: `Store.render` writes it, `Store.parse` reads it with a
`firstIndex(of: ":")`. Nutip only has to round-trip its own output; the
human-readable and tool-readable properties matter more than YAML coverage.

### A page arrives with things that are not text

Nutip is text only, and an extracted page does not know that. A README comes
with a row of shield badges, a logo, a hero screenshot; a marketing page comes
with a dozen `![](…)` and a scattering of non-breaking spaces. On a real
folder, **5% of all body lines held nothing but images**, and one nut lost more
than half its bytes to image URLs alone. None of it is text, and all of it is
read as text: in an editor a row of six badges is six broken images, which is a
hole in the middle of the page.

`Tidy.markdown` runs once, in `Extractor`, which is the one door every saved
page comes through — so `nutip extract` prints exactly what a save writes. It
drops images and the links wrapped around them, folds the exotic spaces back
into the space bar, removes what trails at the end of a line, and collapses a
run of blank lines to one.

Two judgements in it are worth stating, because both could have gone the other
way:

- **An alt text survives only when it is a sentence** — thirty characters with
  a space in them. Most alts are a file name or a layout hint (`line`, `Blur`,
  `hero-screenshot`, the project's own name) and lose nothing by going. The few
  that describe the picture are the only text that picture ever had, so they
  stay, as plain prose.
- **A fenced code block is not touched at all.** The whitespace in there is the
  content. Tables keep their empty cells for the same reason: `| a |  | b |` is
  a shape, not stray spacing.

`nutip tidy` runs the same pass on stdin. The extractor needs a network and the
tests do not have one, so that command is how all twenty-one of the rules above
are actually checked — and it is a way to put an older nut through them by hand.

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

- The text (`public.utf8-plain-text`), or a bare URL, which becomes a link nut.
- **The page the text was copied from**: Chromium browsers write
  `org.chromium.source-url`, Safari a `com.apple.webarchive` whose main
  resource carries the URL, some apps `WebURLsWithTitlesPboardType`.
  `Capture.sourcePage` reads all three. Firefox writes none.
- The frontmost app's name, from `NSWorkspace`, for the `source` field.

`CaptureContext.changeCount` remembers the pasteboard generation of the last
nut saved; pressing the hotkey again without copying anything new shows an
orange "same clipboard" line rather than silently duplicating.

## Extraction without an HTML parser

A hidden `WKWebView` loads the page and runs two scripts: Mozilla's
`Readability.js` (the same one Firefox Reader View uses, Apache 2.0) to find
the article, and `Resources/tomarkdown.js`, ~150 lines that walk the resulting
DOM into Markdown. Rejected alternatives: writing a readability heuristic
(months to match Mozilla's), a Swift HTML→Markdown library (a dependency, and
still worse than running the real DOM), plain `URLSession` (no JavaScript, so
no SPA). The web view uses a non-persistent data store, no cookies of the
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
Keys are handled by one local event monitor. `Palette.handle` reads the event
into a `Key` and asks, in order, `handleEverywhere` (esc, ↑↓, return, ⌘F, ⌘O, ⌘Q)
then the mode's own handler. The capture flow is arrows only: ↑↓ pick a tag, ← goes to the
note (and back to the list from the start of the note), → saves (from the
end of the note). A highlighted row is not a ticked one, which cost a user
their first tag: → therefore saves with the highlighted tag when nothing is
ticked, ⌘→ saves with none, and the footer states which. Editing a nut is
exempt, since unticking everything there has to mean no tags. Digits are read by **key code** (the physical digit row),
so `1` and `⌘1` toggle the first tag on an AZERTY keyboard without Shift.
Every key also has a button in the footer, with its shortcut printed after
the label. Browse remembers the capture it was opened from, and esc returns
to it.

### Browse is read, not just searched

Browse listed fifty rows of two lines each and stopped, with no way to see
what a nut held short of opening the file in another app — which ends the
browse. Two changes make the list somewhere you can wander:

- **A pane beside the list.** ↑↓ moves, the pane follows: title, the reason
  you wrote, and the body. It is read-only and unselectable, because the panel
  is non-activating and a click that took first responder would pull the caret
  out of the search field. Markdown is rendered *lightly* — headings stand
  out, bullets are bullets, `**`, backticks and link targets go — which is not
  a renderer and must not become one: the pane is a glance at a file, and a
  real renderer would be a dependency and a second way for the text to be
  wrong. Editing is still ⌘E.
- **Pages, not a cap.** `Index.search` takes an `offset` and the palette asks
  for the next fifty when the scroller nears the end. Every ordering ends on
  `path`, which is unique: without it, two nuts saved in the same second can
  tie on `captured_at` and a page boundary repeats one and skips the other.
  `nutip recent|search --offset N` is the same paging from the command line,
  and it is what the black-box tests can reach.

Browse is wider and taller than a capture, and both dimensions are read off the
screen rather than fixed, so one build is right on a laptop and on a desk
display. The width is capped at 1320pt — past that a panel has stopped being a
palette — and the list takes 36% of it, held between 360 and 500pt: narrower and
every title truncates, wider and the prose beside it does.

The height is the share of the screen left once the chrome is paid for, and the
chrome was **guessed at 260pt when it is 143** — measured twice, from a panel of
503pt showing six rows and one of 563 showing seven. Guessing high does not make
a panel safer, it makes it shorter than asked: browse came up two rows shy of
the screen it was told to fill.

**The panel's width is a constraint, not a `setContentSize` argument.** Its
content view's constraints determine its size, so autolayout owns the width; a
`setContentSize` that disagrees is overruled on the next pass and the panel
snaps to the narrowest its content allows. Browse found that out by coming up
at 445 points instead of 1040, having been asked for 1040 and told it got it.

### The screen behind the palette is dimmed

The palette floats over whatever the user was doing, and over a busy screen it
competes with it: a page of text behind a page of text. `Backdrop` is one
borderless panel covering every screen, black at 28%, one level below the
palette, faded in and out with it. Two screens matter: a second display left
bright beside a dimmed one reads as a glitch rather than as focus.

**It never takes a click.** `ignoresMouseEvents` is the whole safety argument:
this is a window covering every screen the user owns, and a wash that swallowed
clicks would, if it ever failed to disappear, be a locked machine. One that does
not is a tint, and everything under it stays reachable. It is shown in `present`
and hidden in `hide`, which is the single door every dismissal already goes
through.

The wash is painted in `draw`. Two tidier-looking ways of tinting a window were
tried first and **both failed in exactly the same silent way** — the window came
up on screen, full size, at alpha 1, and perfectly transparent:

- `view.wantsLayer = true` followed by `view.layer?.backgroundColor = …` does
  nothing when the layer is not ready on the very next line, and the optional
  chaining swallows it.
- `window.backgroundColor` with an alpha needs a display pass that
  `setFrame(_:display: false)` never asks for.

`CGWindowListCopyWindowInfo` is what settled it, by reporting the window as
on-screen at alpha 1 while the screenshot showed nothing: that ruled out the
level, the frame and the fade in one reading, and left the drawing. A `draw`
that fills its rect cannot be skipped and cannot be a no-op.

## Global shortcut

`RegisterEventHotKey` (Carbon), the API launchers use: no permission
needed, consumes the keystroke. Unlike Eyesaver it stays registered for the
whole session: a clipper is asked for at any moment. Conflicts cannot be
detected (macOS accepts a duplicate registration silently); the menu bar
item is the way in when the key seems dead, and the preset list avoids
combinations the system uses.

## Two audiences, two files

`AGENTS.md` is written into the nuts folder and describes the folder:
an agent that opens it needs nothing else. `skills/nutip/SKILL.md` is shipped
with the app and describes the CLI: it is loaded before the agent has seen the
folder at all, and it is what makes "save this" and "what did I save about X"
work without the user explaining anything. Keeping them apart is deliberate,
since one travels with the nuts and the other with the tool.

## The CLI is the same binary

`main.swift` calls `CLI.run` before `NSApplication` exists. With arguments,
the process prints and exits; without, it becomes the menu bar app.
`Bundle.main` still resolves to the `.app`, so preferences are shared.
`nutip extract` spins a run loop around the same `Extractor`, which is how the
Markdown output is tested without the GUI. `nutip add` does not extract a page
unless asked with `-x`: the GUI can hide a fetch behind a closed palette, a
command cannot, so a script pays for it only when it wants it. `nutip rm`
exists so an agent tidying the folder does not leave the indexes behind.

## Settings are reachable from the command line

`nutip folder <path>` and `nutip tags add|rm` exist for one reason: an agent
installing Nutip could do everything except the one decision that matters, the
folder, because it was only in a window. It had to write `UserDefaults` behind
the app's back, which the app then overwrote. The two commands close that hole,
and `DistributedNotificationCenter` tells a running app to re-read its
preferences (`UserDefaults.didChangeNotification` does not cross processes).

## What v1 leaves out, on purpose

- **AI inside the app.** Summaries, auto-tags, suggested destinations.
  The folder is built so any agent can do that from outside.
- **An MCP server.** The folder plus `nutip search --json` is the
  interface; a server is a second deliverable.
- **Images, screenshots, PDFs.** Text only.
- **iOS / Share Sheet.** Put the folder in iCloud Drive and this becomes
  possible later; nothing in the format prevents it.
- **Git.** The folder is often a repo; Nutip never runs `git`.
