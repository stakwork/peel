# Message lists: where you land (review, 2026-10-14)

Why opening, closing and arriving in a chat jitters, goes blank or lands in
the wrong place, and the design that replaces the patches. Read-only review
of `4fb944e`; nothing changed in code.

## The short version

Peel has three message lists: the Mac chat (also its threads), the agent
chat and the iPhone list (also its thread sheet). Each holds its place with
its own set of reactive rules on a SwiftUI `LazyVStack`. The chat journal
records 19 list failures (F1–F19) between 8 and 14 October. Most of their
fixes are workarounds: timers, retries, capped step loops and a 400 ms hide.

Two causes sit under nearly all of them.

1. **We fight the lazy stack.** A `LazyVStack` sizes the rows it has not
   drawn from the average of those it has, and when an estimate corrects it
   keeps the *topmost* visible row still (WWDC26-321). A chat wants its
   *bottom* held. Every correction moves the list one way and our re-pin
   moves it back, a frame or more later. Blanks are scrolls into estimated
   space where no row exists; wrong landings are `scrollTo` of a row that
   is only estimated.
2. **We throw the list away.** No list has a position anyone keeps. A chat
   switch tears the scroll view down twice (`.id(messages.isEmpty ? nil :
   chat)`), a narrow window removes the chat column while a thread is open,
   and the iPhone clears a chat's rows the moment you leave it. Each rebuild
   replays the whole opening sequence.

The thread-close jitter is both at once.

## Thread close, confirmed in code

- **Narrow window** (detail column under ~681 pt): `SidePanelSplit` draws
  the chat only `if !isOpen || both` (`ConversationView.swift:60`). Opening
  the thread removes the chat's `MessageList`; closing it makes a new one,
  which hides for up to 400 ms, scrolls to the estimated end and re-pins.
  If the chat still has "New messages" (`AppModel.newMessages` lasts the
  visit), it lands there instead, not where you were. A resize across the
  threshold does the same mid-drag; the web pane's split does it to the
  whole detail.
- **Wide window:** the close is animated (`withAnimation(.easeIn(duration:
  0.15))`), so the chat column widens over several frames. Every row
  re-wraps, the content height changes, and `repin: resized` fires while the
  width is still moving. Scrolled up, nothing holds the row you were
  reading (no size anchor, `ScrollPosition` used only for y offsets), so it
  slides as the text above it re-wraps.

## Other findings

Mac chat:
- Coming back to a chat never restores where you were.
- The jump button inside a jump's window reloads the list rather than
  scrolling it.
- A reply you send from the thread panel makes the chat beside it jump to
  its newest message, even if you were scrolled up (`MessageViews.swift:329`).
- The 400 ms reveal fires whatever state the list is in, so a list still
  stepping becomes visible mid-move.
- Re-pins run during `.animating`, so they can fight `scrollToNewest` and
  `go(to:)`.
- Threads are revealed before they are placed and inherit the chat's "New
  messages".
- **The Mac never loads older history.** `loadOlder` is wired up only on the
  iPhone, so scrolling up stops at 200 messages.
- Turning the timeline log on enables `scrollTargetLayout`, which changes
  scroll behaviour.

iPhone:
- The thread sheet slides down blank (its rows clear when `openThread`
  goes nil) and slides up blank until the thread loads.
- Back and tab switch clear the chat's rows, so the screen is blank during
  the pop animation and reopens at the newest message.
- None of the Mac's defences are there (`ListEnd` is not in the iOS target).
- It does not track content height, so an image loading at the bottom
  slides the newest message under the composer.
- The keyboard re-pin snaps while the keyboard animates.

Agent chat:
- A reduced fork of the Mac logic, without its last-row fallback.
- A streaming reply follows in 20–100 ms steps.
- Expanding a tool row near the bottom pushes it out of view.
- The narrow-window teardown applies here too.

Shared:
- About ten functions are copied between the Mac and iPhone lists, with
  drifted timings.
- The 24 pt "at bottom" threshold is written three times.
- There are three different composer-focus timings.
- F19, the open hang (99% CPU in the `MessageList` layout, "OnScrollGeometryChange
  tried to update multiple times per frame"), fits a feedback loop between
  the three scroll-geometry observers, the per-row frame reports and the
  state they write. Unproven, but the design below removes the loop
  either way.

The failure catalogue F1–F19 is drawn from `docs/phases/03-chat.md`
(the "Blank …" and list-end sections) and `09-agents.md`.

## How it should behave (Slack, Signal, Telegram, iMessage)

| Journey | Lands | Never |
|---|---|---|
| Open a chat, nothing unread | Newest message, bottom flush, already drawn | Visible jump or blank frame |
| Open with unread | "New messages" near the top, or newest if it all fits | Landing at the bottom with the line out of view |
| Return to a chat | Where you left it (the row you were reading, at the same place on screen); newest if you were at the bottom | Reset to newest after reading history |
| Jump to a message (search, quote, notification, Threads) | That message centred and lit; "Jump to present" shown if the window stops short of the newest | Undone by an anchor; a reload when you press the jump button |
| Open or close a thread | The chat does not move. The row you were reading stays where it is, or the bottom stays flush | Rebuild, reveal, scroll to the bottom |
| Window resize, sidebar, composer grows, search bar | Same as a thread: keep the reading row, or the bottom if following | Drift, a re-pin per frame |
| Others' message, at bottom | Follows, animated once | Steps |
| Others' message, scrolled up | Does not move; "N new" pill | Moves because a thread row re-sorted |
| You send (chat or thread) | That list goes to its newest | The *other* list moves |
| Older history | Loads above without moving what you see | A dead end at 200 (Mac today) |
| Agent reply streaming | Follows only while at the bottom; stops the moment you scroll | Fights your scroll |
| iPhone back, tab, sheet dismiss | Keeps its rows during the animation; restores the position on return | Blank during the slide |

## Rules every list holds

1. **One anchor.** The list's position is a value: `.newest` (following),
   or `.row(id, offset from the top of the view)`. Nothing else moves the
   offset. No offset maths against estimated content heights.
2. **Hold the edge the change does not touch.** Prepend: hold the reading
   row. Append while reading: hold the reading row. Append or stream while
   following: hold the newest. Resize or panel: the reading row, or the
   newest if following.
3. **Following is a latch.** Set by sending, by reaching the bottom by hand
   and by Jump to present; cleared when you start a scroll. Never inferred
   from a geometry report.
4. **"The window reaches the newest" is separate from "at the bottom".**
5. **One movement per change, in the same layout pass.** No sleeps, no
   retry loops, no step limits.
6. **Shown once placed against measured rows**, on a chat's first open
   only. Not on a timer.
7. **Never animate a list's width.** The panel slides; the chat column
   changes width once.
8. **A list's identity outlives panels, widths and navigation.** Opening a
   thread, crossing a width threshold or going back never recreates the
   scroll view. The model keeps a chat's rows until the next chat's have
   loaded, and keeps each chat's anchor.
9. **Dividers, day lines and typing rows are never anchors.**
10. **One implementation.** Following, the anchor, unread-below, the jump
    pill, jumps and the flash live once in PeelUI. The platform supplies
    only the scroll view.

## Design

### Layer 1: structure. Independent of the list engine; ships first.

These are bugs in our state and view identity, not in SwiftUI, and they are
behind the thread-close jitter and the iPhone blanks.

- `SidePanelSplit` always keeps `main()` in the hierarchy. On a narrow
  window it is covered and hidden (zero opacity, no hit testing), not
  removed. The same applies to the web pane's split and the agent's memory
  panel.
- The panel's slide is animated; the column's width is not (rule 7).
- The chat list is one per chat, made once. Drop the `.id(nil)` flip: the
  model keeps the previous chat's rows until the new chat's have loaded,
  and the list is not built until they have.
- `AppModel` keeps a `ListAnchor` per chat (and per thread), written by the
  list as you scroll and read when it is made. Returning restores it; at the
  bottom, it is `.newest`.
- "New messages" for a visit retires once the bottom has been reached.
- A thread send moves only the thread's list.
- iPhone: the conversation and thread sheet keep their rows through the
  pop or dismiss animation; `openThread` clears after the sheet is gone.

### Layer 2: one list controller, one engine. Decided by a spike.

`ChatListController` in PeelUI owns rules 1–6 and 9–10 and replaces
`ListEnd`, `ListTracking`, `MessageList`'s dozen flags and its twin on the
iPhone. `ListBottom` stays as its unread counter. The open question is the
scroll view under it:

| Engine | For | Against | Kills |
|---|---|---|---|
| **N. Native list:** `NSTableView` (Mac), `UICollectionView` (iPhone), SwiftUI cells in hosting views, row heights cached per (id, width, version), the anchor corrected inside `beginUpdates`/`performBatchUpdates` | What Signal, TelegramSwift and Discord ship. Real cell reuse, exact geometry, same-pass corrections. A bottom-origin (non-flipped) document view on the Mac. | Most work: two thin hosts, a height cache, re-plumbing hover, menus, selection and focus. Measuring SwiftUI cells is not free, so cache it. | Blanks, jitter and wrong landings by construction; scales to unbounded history |
| **W. Bounded measured window:** a plain `VStack` of a window around the anchor, paged at the edges | Simplest; one SwiftUI path | **Already measured here: 470 ms to open 200 rows against 100 ms lazy, and 550 ms for a plain tail.** Only viable with a much smaller window (~40–60) and fast paging; developers hitting the iOS 27 `scrollTo`/prepend regressions report a plain `VStack` fixed them (forum reports, unconfirmed) | Blanks and wrong landings; jitter if the per-change anchor works |
| **L. Disciplined lazy stack:** keep `LazyVStack`, but position only by id (`scrollPosition(id:anchor:)`), never by offset or estimate, with Layer 1 and the controller | Least change | Still fights the stack's top anchoring on every estimate correction; this is the road F1–F19 came down | Some; not blanks by construction |

**Recommendation: N**, checked by a spike first. The patch history is the
evidence that L does not converge, and W has already failed its speed test
at the size Peel needs. The spike measures N against today's list, on Tom's
real tribes in the offscreen driver:

- open time (first frame placed) at 200 and 1,000 rows;
- relayout time on a width change;
- frames moved on thread close and on prepend (target 0);
- blank frames (target 0).

If N's measuring cost misses (more than ~100 ms on open), fall back to W
with a small window.

### Layer 3: the journeys as checks

The offscreen driver (`OffscreenDriver.swift`) gains a probe step that
reports each list's top visible row, its offset and whether any row is in
view, logged every frame for a set time. Each row of the journey table
above becomes a script that fails on:

- any frame where the reading row moved;
- any blank frame;
- the wrong landing.

These run in `check-app.sh`, and Layer 1 is merged against them, so this
class of bug fails a check rather than reaching Tom. They replace the
diagnostic `scrollTargetLayout` switch.

## Plan

| PR | What | Deletes |
|---|---|---|
| 1 | Journey checks and the frame probe (red where today's behaviour is wrong) | — |
| 2 | Layer 1 on the Mac: column kept, no width animation, no `.id` flip, per-chat anchor, `newMessages` retired, thread send isolated. Fixes thread close. | Narrow-window teardown, `.id(nil)` |
| 3 | Layer 1 on the iPhone: rows kept through pop and dismiss, anchor restore | iPhone blanks |
| — | Spike: engine N vs today, numbers in the PR description, not committed | — |
| 4 | `ChatListController` in PeelUI and the Mac engine; chat and thread lists on it; Mac loads older history | `ListEnd`, `ListTracking`, re-pin, step loop, reveal timer, most of `MessageViews.swift`'s list state |
| 5 | Agent chat on it | The agent's fork |
| 6 | iPhone engine on it | The iPhone's copies |

PRs 2 and 3 are worth shipping on their own: they fix what Tom sees on
thread close and on the iPhone without waiting for the engine.

## Decided (Tom, 2026-10-14)

1. **Returning to a chat restores where you were**: the row you were
   reading at the same place on screen, or the newest if you were at the
   bottom.
2. **Engine: spike N** (native lists), with W as the fallback if its
   measuring cost misses.
3. **Agent streaming follows only while at the bottom**; the moment you
   scroll, it stops following and leaves you where you are.
