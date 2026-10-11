# Design library and duplication review, 2026-10-09

The question: is Peel's UI drifting into one-off, inconsistent pieces,
and what component library would stop it? Shadcn is the model Tom named:
a small set of components with variants, so a screen is assembled, not
rebuilt.

Base: `origin/main` at `e998ae2` (#129). Paths are under `Sources/`.

Method:

- A duplicate-code scan of `PeelCore`, `PeelApp` and `peel` (generated
  `Sphinxrs` left out): `jscpd` 4 through `npx`, then a throwaway script
  that hashes windows of five normalised lines (strings and numbers
  blanked, comments and lone braces dropped).
- An inventory of every UI building block by search, with counts, then
  reading each variant.
- The logic that is computed or worded in more than one place, read
  side by side.
- No app was launched and no code was changed. Visual claims come from
  reading the view code. "(Not rendered)" marks a claim no render has
  checked.

Sizes: S is an afternoon, M a day or two, L more.

## Verdict

Peel is not copy-paste slop. The scan finds almost no repeated code:
0.18% of lines, and none of it more than eleven lines long. The drift is
in the design system, not the code. The form system (`FormKit`) is the one
shared library, and it covers forms only. Everything outside a form is
drawn by hand: four button styles and two icon-button types for one job,
two panel boxes, three "label and value" rows, three card boxes, four
close buttons, ten corner radii and fourteen avatar sizes. Each piece was
reasonable alone; together they make the same thing look different on
two screens, as Copy link and Leave tribe do in one footer. Three things
are real bugs, not taste: the members panel's Copy link is the system
button (batch 4b), tribe details call a 3-sat message "Free" (batch 6),
and about thirty error lines show a lowercase fragment as a sentence
(batch 7). The fix is a small library in `Sources/PeelApp/UI/`, built
from `FormKit`'s tokens and grown out to buttons, panels, the composer
and the rest, in fifteen small PRs, buttons and the panel first.

## Batch plan

Each batch is one PR with the full review chain (`/code-review`,
`/simplify`, `/security-review`). Each takes before and after renders of
the screens it touches with the app's offscreen render mode once that
lands (it is not on `main` yet). Batches run in order. Batches 5, 6 and 9
touch disjoint files and may run in parallel once 4b has merged. No other
two may.

| # | Batch | Size | Files | Fixes a bug? |
|---|---|---|---|---|
| 1 | `PeelButton` style: `FormButtonStyle` becomes the one style, with sizes and a `link` variant | M | new `PeelApp/UI/Button.swift`; `Theme`, `FormKit`, `ButtonStyles` (`buttonProgress` moves); the 43 `FormButtonStyle` call sites in `AccountView`, `ContactsViews`, `PayInvoicePane`, `PaymentViews`, `PictureField`, `ReceivePane`, `SidebarForms`, `TimeZoneViews`, `TribeDetails`, `TribeViews` | No (no visual change) |
| 2 | Retire `GhostButtonStyle`, `PrimaryButtonStyle`, `SecondaryButtonStyle`, `LinkButton` and the hand-styled text buttons | M | `ButtonStyles` (deleted), `Controls`, `CallViews`, `ImageViewer`, `LinkCards`, `MediaViews`, `Notifier`, `PaymentPanes`, `ThreadViews`, `WebPane`, `OnboardingView`, `PayInvoicePane`, `AttachmentViews`, `CallWindow`, `ReceivePane`, `ContactsViews`, `PaymentRows`, `Sidebar`, `PaymentsView`; `docs/design/README.md`, `AGENTS.md` | "Try Again" and "Try again"; stale README |
| 3 | `IconButton`: `HoverIconButton` and `HeaderButton` become one, hand-drawn icon buttons move onto it | M | new `UI/IconButton.swift`; `Controls`, `ConversationView`, `ChatSearch`, `ThreadViews`, `PaymentPanes`, `CallViews`, `FormKit`, `ImageViewer`, `WebPane`, `AttachmentViews`, `CallWindow` (keep on top only), `CopyFeedback`, `MessageViews`, `Sidebar`, `MediaViews` | Header icons get a hover state |
| 4a | `Panel` shell from `FormPopover`; every panel draws one box | M | new `UI/Panel.swift`; `FormKit`, `MenuPresenter`; the seven `FormPopover` users in `ContactsViews`, `PaymentViews`, `TribeDetails`, `SidebarForms`, `TribeViews` | No |
| 4b | The five hand-drawn panels onto `Panel`, with the placement rule | M | `ConversationView` (`TribeMembersPanel`), `TimeZoneViews` (`ChatInfoPanel`, its switch), `PaymentChatRows` (`BoostersPanel`), `Sidebar` (`ConnectionCard`), `AccountView` (`ZonePicker`), `TribeDetails` (footer and Copy link); `docs/design/README.md` | Copy link drawn as the system button |
| 5 | Composer: attach, the bolt and send inside the rounded field | M | `ComposerView`, `AttachmentViews` (the tray's padding only); `docs/design/README.md` | No |
| 6 | Tribe prices: one meaning per label | S | `PeelCore/Tribe.swift`, `PeelApp/TribeDetails.swift`, `PeelApp/ConversationView.swift` (header subtitle), `PeelApp/SidebarForms.swift`, `peel/Commands+Tribes.swift`, `Tests/PeelCoreTests/TribeTests.swift` | "Per message: Free" for a 3-sat message |
| 7 | Problem lines: one helper for "Could not …" | S | `Formatting` and the 62 `PeelError.readable` call sites in 20 files (section 3); runs alone | About 30 lowercase fragments |
| 8 | One owner each: a sender's name, a tribe's pages, Leave | S | `ConversationView`, `Notifier`, `TribeViews`, `PaymentItem+Display`, `WebPane`, `TribeDetails`, `Sidebar` (`ConversationMenu`) | Page order differs between More and details |
| 9 | Keys: named key codes, one written Escape order (in `KeyMonitor`'s doc comment) | S | `PeelMenu` (`KeyMonitor`), `MenuPresenter`, `ChatSearch`, `ImageViewer`, `Sidebar` | No (a risk, see below) |
| 10 | `SectionHeader`, `Card`, `Callout` | M | new `UI/Section.swift`, `UI/Card.swift`; `Styles`, `FormKit`, `TribeViews`, `AccountView`, `PaymentsView`, `ConversationView`, `PaymentPanes`, `WebPane`, `CallViews`, `LinkCards`, `PaymentChatRows`, `TimeZoneViews`, `ContactsViews`, `OnboardingView`, `SidebarForms`, `TribeDetails` | No |
| 11 | `Badge` and `Chip` | S | new `UI/Badge.swift`; `Controls`, `ContactsViews`, `MoneyArrivals`, `ConversationView`, `MediaViews`, `TribeDetails`, `PaymentChatRows`, `Sidebar` | No |
| 12 | `FactList` and `ListRow` | M | new `UI/Rows.swift`; `TribeDetails`, `AccountView`, `PaymentPanes`, `PaymentRows`, `ConversationView`, `ChatSearch`, `ContactsViews`, `TribeViews`, `PaymentChatRows`, `ReceivePane`, `PayInvoicePane` | Three different "selected" fills |
| 13 | `EmptyState` | S | new `UI/EmptyState.swift`; `MainView`, `PaymentsView`, `ThreadViews`, `AccountView`, `WebPane`, `TribeViews` | No |
| 14 | Tokens sweep: radii, type, muted text, avatar sizes, plurals and dates | M | most of `PeelApp`; runs last and alone | No |

## 1. Mechanical duplication

`jscpd` (`--min-lines 4 --min-tokens 40 --mode weak`) found 8 clones in
29,461 lines of `Sources`: 54 lines, 0.18%. The window script found the
same plus a few shorter ones. The real ones, grouped:

| What | Where | Lines | Fix |
|---|---|---|---|
| Save a setting, show the problem or the help under it | `PeelApp/AccountView.swift:300-313`, `:735-748`, `PeelApp/PaymentViews.swift:306-319` | 10 × 3 | A `SettingRow` caption that takes the setter (batch 14) |
| The attach and bolt buttons, drawn twice | `PeelApp/ComposerView.swift:93-104`, `:106-117`; the tray's "+" tile copies the first, `PeelApp/AttachmentViews.swift:438-448` | 7 × 3 | `IconButton` inside the field (batch 5) |
| A small grey icon button, by hand | `PeelApp/CallViews.swift:299-306`, `PeelApp/ComposerView.swift:188-195` | 8 × 2 | `IconButton` (batch 3) |
| A hovered row as a plain button | `PeelApp/AccountView.swift:646-652`, `PeelApp/ChatSearch.swift:308-314`, `PeelApp/PaymentRows.swift:69-75`, `PeelApp/PaymentsView.swift:227-233` | 7 × 4 | `ListRow` (batch 12); `@State private var hovering` is declared 23 times in 13 files |
| A name over a muted line | `PeelApp/Sidebar.swift:293-301`, `PeelApp/ThreadViews.swift:71-79` | 9 × 2 | `ListRow` (batch 12) |
| `private func note(_:)`, the muted caption | `PeelApp/AccountView.swift:543-548`, `PeelApp/ContactsViews.swift:412-417`, `PeelApp/TimeZoneViews.swift:302-308` | 6 × 3 | A `.muted` text style (batch 14). The same four modifiers are written inline at 58 more sites (12 pt, `secondaryText`) |
| A muted line in a card | `PeelApp/AccountView.swift:393-397`, `PeelApp/ContactsViews.swift:469-473`, `PeelApp/TribeDetails.swift:187-191` | 5 × 3 | Same |
| A chat row's padding, chrome and hover | `PeelApp/PaymentChatRows.swift:258-264`, `:321-327` | 7 × 2 | Leave: two row kinds sharing `rowChrome` already |
| A setting through the confirmation gate | `PeelApp/AppModel+Payments.swift:41-52`, `:71-83` | 9 × 2 | Leave, or let `setBoostAmount` call `pay` (one line) |

Ignored: `Storage+Migrations.swift` repeats itself on purpose (shipped
migrations are frozen); the CLI's `pay` and `request` cases
(`peel/Commands+Money.swift:22-27`, `:96-101`); two `init`s with the
same shape (`AccountView.swift:784-790`, `FormKit.swift:91-97`).

So the code is not copied. It is re-drawn: the same thing written fresh
with different numbers each time. A clone detector cannot see that. The
inventory below can.

## 2. Component inventory

What exists today: `FormKit.swift` (form popover, sections, items, text
and number fields, field chrome, switch row, `FormButtonStyle`, the
destructive section, `InlineConfirm`), `Controls.swift` (`MenuButton`,
`HoverIconButton`, `PeelDropdown`, `LinkButton`, `.hiddenShortcut`,
`UnreadBadge`, `ProblemText`, `FormFooter`), `ButtonStyles.swift`
(`GhostButtonStyle`, `PrimaryButtonStyle`, `SecondaryButtonStyle`,
`buttonProgress`), `Styles.swift` (`panelBoxed`, `cardBoxed`,
`menuBoxed`, `dropdownBoxed`), `PeelMenu.swift` and `MenuPresenter.swift`
(the one menu, panels, hover cards, `KeyMonitor`), `CopyFeedback.swift`
(`CopyButton`), `Theme.swift` (every colour). Menus are in good shape:
there is no native `Menu`, `Picker`, `.alert`, `.sheet` or `.popover`
anywhere in `PeelApp`. Fields are too: every input uses `FieldChrome`.

### Buttons

| Variant | Uses | Look | Examples |
|---|---|---|---|
| `FormButtonStyle()` (outline) | 30 | 32 tall, radius 7, `fieldFill`, `inputBorder`, hover | `TribeDetails.swift:179`, `:206` |
| `FormButtonStyle(kind: .primary)` | 12 | 32 tall, filled `button` | `ReceivePane.swift:86`, `PaymentViews.swift:72` |
| `FormButtonStyle(kind: .ghost)` | 1 | no border, hover fill | `TribeDetails.swift:317` |
| `FormButtonStyle` inside `InlineConfirm` | 2 | Cancel and the action | `FormKit.swift:445`, `:508` |
| `GhostButtonStyle()` | 17 | about 28 tall, radius 6, `divider` border, no fill, no hover | `LinkCards.swift:57`, `ImageViewer.swift:153`, `WebPane.swift:818` |
| `GhostButtonStyle(prominent: true)` | 5 | filled `button`, 13 medium | `LinkCards.swift:61`, `CallViews.swift:126`, `Notifier.swift:396` |
| `PrimaryButtonStyle` | 4 | 14 bold, 22 × 11 padding, radius 8 | `OnboardingView.swift:57`, `:148`, `:224`, `:259` |
| `SecondaryButtonStyle` | 1 | 14, full width, radius 8, `divider` border | `OnboardingView.swift:59` |
| `LinkButton` | 6 | `Theme.link` text | `ReceivePane.swift:148`, `LinkCards.swift:110` |
| Hand-styled link or accent text | 7 | `Theme.link` or `Theme.accent`, by hand | `ContactsViews.swift:211-220`, `PaymentRows.swift:156-166`, `OnboardingView.swift:423-433`, `Sidebar.swift:560-563`, `TribeViews.swift:276-282` |
| `HeaderAction` (Payments header) | 2 | radius 7, `divider` border, lit while open | `PaymentsView.swift:223-249` |
| System default (no style set) | 1 | the native bordered push button | `ConversationView.swift:350` |

The names collide. `GhostButtonStyle` draws a bordered button, which
shadcn calls *outline*; `FormButtonStyle(kind: .ghost)` draws shadcn's
ghost. The two outlined buttons differ in height, radius, border colour,
fill and hover. A chat card's Join
(`GhostButtonStyle`) and a panel's Join (`FormButtonStyle`) are different
buttons. A text button is `Theme.link` in some places (`Controls.swift:112`,
`ContactsViews.swift:220`, `PaymentRows.swift:164`) and `Theme.accent` in
others (`OnboardingView.swift:433`, `Sidebar.swift:563`,
`TribeViews.swift:279`, `ConversationView.swift:613`).

`.buttonStyle(.plain)` appears 51 times in 23 files:

- 7 inside the shared pieces themselves (`Controls.swift:47`, `:90`,
  `:110`; `FormKit.swift:313`, `:446`, `:505`, `:543`). These stay.
- 13 make a whole row, card or chip clickable (`ChatSearch.swift:345`,
  `PaymentRows.swift:103`, `ThreadViews.swift:84`, `:225`,
  `AccountView.swift:671`, `MainView.swift:216`, `Sidebar.swift:250`,
  `:343`, `MessageViews.swift:1141`, `ImageViewer.swift:74`,
  `AttachmentViews.swift:154`, `PaymentChatRows.swift:114`,
  `TribeDetails.swift:372`). These become `ListRow` or `Chip`.
- 19 are hand-drawn icon buttons (`ComposerView.swift:103`, `:116`,
  `:141`, `:195`; `ConversationView.swift:178`, `:286`;
  `CallViews.swift:306`, `:427`; `CallWindow.swift:299`, `:316`, `:349`,
  `:363`; `ImageViewer.swift:190`; `MediaViews.swift:227`, `:409`;
  `MessageViews.swift:613`; `AttachmentViews.swift:433`, `:448`;
  `Sidebar.swift:530`).
- 12 are hand-drawn text or bordered buttons (`AccountView.swift:514`,
  `CallViews.swift:294`, `ContactsViews.swift:218`,
  `ConversationView.swift:628`, `OnboardingView.swift:219`, `:432`,
  `PaymentRows.swift:166`, `PaymentViews.swift:226`,
  `PaymentsView.swift:246`, `Sidebar.swift:561`, `TribeViews.swift:282`,
  `:344`).

### Icon buttons and close buttons

| Kind | Uses | Look |
|---|---|---|
| `HoverIconButton` | 11 | 28 × 26, radius 5, lights under the pointer (`Controls.swift:31-52`) |
| `HeaderButton` | 8 | 28 × 28, radius 6, lit only while its thing is open, no hover (`ConversationView.swift:268-290`) |
| Hand-drawn | 19 | sizes 22, 24, 26, 28, 30, 32, 36, 44 and 48 wide |

A panel's close button is drawn four ways: `HoverIconButton`
(`FormKit.swift:23`, `ImageViewer.swift:178`, `WebPane.swift:866`),
`HeaderButton` (`ThreadViews.swift:22`, `PaymentPanes.swift:13`,
`ChatSearch.swift:221`), a bare 10 pt cross (`ConversationView.swift:173-178`)
and a 22 × 22 cross (`ComposerView.swift:188-195`). The hand-rolled
panels have none.

### Panels

`FormPopover` (`FormKit.swift:11-49`) is the panel shell: a 15 pt bold
title, a close button, a body, a footer, 372 or 320 wide, radius 12, on
`Theme.sidebar` with `formEdge` and `popoverShadow`. Seven panels use it
(Add contact, Invite someone, an invite, Send sats, Tribe details, Join a
tribe, Create or Edit tribe).

Five draw their own, and the presenter wraps them in a different box
(`MenuPresenter.swift:478-491`: radius 8, `Theme.menu`, `divider`, black
25% shadow):

| Panel | Title | Width | Padding | Close |
|---|---|---|---|---|
| `TribeMembersPanel` (`ConversationView.swift:326-367`) | 15 bold | 300 | 16 | none |
| `ChatInfoPanel` (`TimeZoneViews.swift:185-231`) | none (the name, 16 bold, centred) | 300 | 16 | none |
| `BoostersPanel` (`PaymentChatRows.swift:130-176`) | 14 bold | 260 | 14 | none |
| `ConnectionCard` (`Sidebar.swift:539-568`) | 14 medium | 260 | 14 | none |
| `ZonePicker` (`AccountView.swift:596-630`) | none | 320 | 8 | none |

So a contact's details and a tribe's details, the same kind of panel,
differ in background, radius, border, shadow, width, title, hero layout
(centred 64 pt icon against a left-aligned 56 pt one) and where Remove or
Leave sits. Their dates are worded differently too ("Contact since 3
October 2026", `TimeZoneViews.swift:203`; "Created 3 Oct 2026",
`TribeDetails.swift:103`). The contact's time zone switch is the system
switch (`TimeZoneViews.swift:281-288`); the tribe form's switches are
Peel's own (`FormKit.swift:293-319`, used at `TribeViews.swift:133-134`).

Side panes have their own header: `PaneFrame` (`PaymentPanes.swift:5-27`)
and `ThreadPanel` (`ThreadViews.swift:19-25`) both use `DetailHeader`
with a `HeaderButton` close. That pair is consistent and stays.

### Footers and the Copy link case

`TribeMembersPanel`'s footer (`ConversationView.swift:348-359`) puts
`CopyButton("Copy link")` with no button style beside
`InlineConfirm(trigger: "Leave tribe")`. Every other `CopyButton` gets a
style from itself or its stack (`AccountView.swift:124`,
`ContactsViews.swift:481`, `TimeZoneViews.swift:364`,
`TribeDetails.swift:195`, `ReceivePane.swift:86-88`,
`ImageViewer.swift:173`, `PaymentPanes.swift:87`). This one falls back to
the native bordered button: the small filled grey one Tom saw, beside a
32 pt outline Leave tribe. (Not rendered; read from the code.)

Leave is offered in three places, each with its own wrapper and wording:
the More menu (`Sidebar.swift:495`, `ConversationMenu.leave`), the
members panel ("Leave #hive?") and the details footer (no prompt,
`TribeDetails.swift:212`). Copy link is in all three too.

### Section headers

| Kind | Look | Where |
|---|---|---|
| `SectionLabel` | 12 medium, secondary | `TribeViews.swift:235-245`, 5 uses |
| `FormSection` title | 12 semibold, secondary | `FormKit.swift:98-102` |
| `SettingsSection` title | 11 semibold, secondary | `AccountView.swift:791-794` |
| Payments day heading | 12 semibold, secondary | `PaymentsView.swift:162-167` |
| `SidebarSection` | 13 medium, collapsible | `Sidebar.swift:315-349` |

### Cards and boxes

| Helper | Fill | Radius | Border | Uses |
|---|---|---|---|---|
| `formCard()` | `menu` | 9 | `formEdge` | 11 (`FormKit.swift:76-83`) |
| `cardBoxed()` | `quote` | 10 | `divider` | 4 (`Styles.swift:14-17`) |
| `panelBoxed()` | `panel` | 8 | `divider` | 2 (`Styles.swift:7-10`) |
| `menuBoxed()` | `menu` | 8 (or 7, 10, 16, 18) | `divider` + shadow | 8 |
| By hand | `quote` | 14 | none | `AttachmentViews.swift:358` (file card) |
| By hand | `attention` 7% | 9 | `attention` 28% | `PaymentPanes.swift:121-122` (`AttentionNote`) |
| By hand | `panel` or `hover` | 8 | `divider` | `ThreadViews.swift:221-222` (`ThreadCard`) |

Notes and bars are four more shapes of one thing: `NoticeBar`
(`ConversationView.swift:159-185`), `AttentionNote`
(`PaymentPanes.swift:98-123`), `DownloadBar` (`WebPane.swift:828-874`)
and `ConnectionCard`.

### Chips and badges

| Kind | Where |
|---|---|
| `UnreadBadge` (count, accent capsule) | `Controls.swift:134-163`; also "New" (`ContactsViews.swift:23-28`) and "+350" (`MoneyArrivals.swift:239-240`) |
| Tag chip (capsule, selectable) | `TribeDetails.swift:381-397` |
| Boost chip (capsule, bolt, avatars) | `PaymentChatRows.swift:43-120` |
| Day divider label (outline capsule) | `ConversationView.swift:547-555` |
| Video duration (black 55% capsule) | `MediaViews.swift:257-263` |
| "Copied" toast pill | `CopyFeedback.swift:155` |

### List rows

`MemberRow` (`ConversationView.swift:481-504`), `ZoneRow`
(`AccountView.swift:642-675`), `SearchResultRow` (`ChatSearch.swift:303`),
`PaymentListRow` (`PaymentRows.swift:62-104`), `InviteRow`
(`ContactsViews.swift:42`), `MentionRow` (`TribeViews.swift:455`), the
boosters' rows (`PaymentChatRows.swift:148-167`), `MenuRow`
(`MenuPresenter.swift:398`) and the sidebar's `SidebarRowStyle`
(`Sidebar.swift:606`). The selected fill is `Theme.selection` in the
sidebar and search results, `Theme.accent` at 14% in Payments
(`PaymentRows.swift:98`), and `Theme.selection` as a *hover* in the zone
picker (`AccountView.swift:668`).

"Label and value" rows are written three times: `DetailRow`
(`TribeDetails.swift:251-278`), `SettingsRow` (`AccountView.swift:812-841`)
and `KeyValues` (`PaymentPanes.swift:54-95`).

### Empty states

`EmptyPlace` (`MainView.swift:261-274`, used for the start screen and
Mentions, `TribeViews.swift:427`) and two copies of its body:
`PaymentsView.swift:150-155` and `ThreadViews.swift:134-138`. Smaller
ones: "No time zone matches." (`AccountView.swift:619-624`) and
the web pane's failed page with Try Again (`WebPane.swift:802-824`; its
sibling in a link card says "Try again", `LinkCards.swift:110`).

### Inline confirms

`InlineConfirm` is the one owner, with 11 uses, and it holds. One copy
remains: a failed payment's row re-draws `PayButton`'s armed state as
text with its own Cancel (`ConversationView.swift:596-606`, against
`PaymentViews.swift:61-81`).

### Text fields

All good: `FormTextField` (16 uses), `FormNumberField` (3), and the four
special fields (search bar, web address, PIN, words) all wear
`FieldChrome`. The chat search bar (`ChatSearch.swift:187-213`) is
`FormTextField` with a trailing count; a `trailing:` slot would absorb it.

### Avatars

`Avatar`, `TribeIcon` and `ConversationIcon` are shared (26 `Avatar`
uses). Their sizes are not: 16, 18, 20, 22, 24, 28, 30, 32, 34, 36, 48,
56, 64 and 88.

### Spacing, radii, type and colour

- Corner radii in use: 5, 6, 7, 8, 9, 10, 12, 14, 16 and 18, with
  `.continuous` and `.circular` mixed.
- `Theme.font` sizes: 10, 11, 12, 12.5, 13, 13.5, 14, 15, 16, 20, 24, 28
  (12.5 and 13.5 at 15 sites, for example `PaymentRows.swift:82`,
  `CallViews.swift:97`, `TimeZoneViews.swift:120`). 72 more set
  `.font(.system(size:))` directly, mostly for SF Symbols.
- Colour: every base colour is a `Theme` token. Outside `Theme` there
  are about 20 ad-hoc opacities of tokens (`Theme.accent.opacity(0.14)`,
  `Theme.confirmed.opacity(0.16)`, `Theme.secondaryText.opacity(0.4)`)
  and two shadows that are not `popoverShadow` (`Styles.swift:27`,
  `MessageViews.swift:602`). White and black over photos and video
  (`ImageViewer`, `MediaViews`, `AttachmentViews.swift:102`) are right
  as they are. `PaidAttachmentViews.swift:123-124` keeps its own palette
  for blurred previews; fine, but it belongs in `Theme`.

## 3. Ownership drift

| What | Owners today | Right owner | Batch |
|---|---|---|---|
| A tribe's per-message price | `pricePerMessageMsat` in details, `messageAmountMsat` in the header | See below | 6 |
| A tribe's join price | `priceToJoin ?? 0` in details ("Free"), `joinAmountMsat` in the Join form ("1 sat") | `joinAmountMsat` | 6 |
| A sender's name | `Sender` and `model.sender(of:)`; 8 sites write `message.senderAlias ?? Sender.unnamed` (`ConversationView.swift:518`, `:524`, `Notifier.swift:202`, `:263`, `:273`, `:293`, `TribeViews.swift:307`, `:334`) | `Sender` (first review row 6, still open) | 8 |
| A tribe's pages (app, second brain) | `WebMenuEntries` (`WebPane.swift:501-517`: Second brain first, opened through `openURL`) and `TribeDetails.swift:162-182` (Tribe app first, `model.web.open`) | One list in `WebMenuEntries`, used by both | 8 |
| Leave a tribe | The menu calls `model.leave` (`AppModel+Chat.swift:173`), which words its own failure; the members panel (`ConversationView.swift:471-478`) and the details (`TribeDetails.swift:212-219`) call `leaveTribe` and word theirs; three confirm wordings | `model.leave` and one confirm wording | 8 (wording), 4b (place) |
| Error lines | `PeelError.readable` at 62 sites: bare at about 30, after "Could not …: " at 22, capitalised by hand once (`AppModel+Calls.swift:159`); `Formatting.sentence` at 8 more; "Couldn't open" once (`WebPane.swift:809`) | One `Formatting.problem` | 7 |
| Plurals | `Formatting.replies`, `people`; inline at `PaymentChatRows.swift:123`, `ChatSearch.swift:36`, `CallViews.swift:410`, `AccountView.swift:532`, `TribeDetails.swift:159`, `:246`, `MessageViews.swift:584`, `PaidAttachmentViews.swift:152` | `Formatting` | 14 |
| Dates | `Formatting` owns times and relative dates; inline at `TribeDetails.swift:103`, `TimeZoneViews.swift:203`, `ContactsViews.swift:526`, `PayInvoicePane.swift:156`, `:161`, `ReceivePane.swift:118` | `Formatting` | 14 |
| Escape | `MenuPresenter.swift:302`, `:309`, `ChatSearch.swift:250`, `ImageViewer.swift:115`, `Sidebar.swift:164`, `CallWindow.swift:74`, `WebPane.swift:669`, `PaymentsView.swift:92`, the composer (`ComposerField.swift:166`) | One written order, named key codes | 9 |
| Raw key codes | 53, 123–126, 36, 76, 49 in four `KeyMonitor` handlers | A `KeyCode` enum beside `KeyMonitor` | 9 |
| Sats | `Sats.format`, `number`, `signed` (47 uses); healthy | — | — |
| Member counts | `TribeMembers.countLabel` since #128; healthy | — | — |
| Link parsing | `MessageMarkup`, `MessageLink`, `ContactCode`, `WebPage`, `CallLink` in `PeelCore`; no URL is parsed in a view; healthy | — | — |
| ⌘F, ⌘I, panel anchors | One owner each since #128 and #129; healthy | — | — |

### The two per-message prices

They are not two copies of one field. `Tribe.pricePerMessageMsat`
(`PeelCore/Tribe.swift:15`) is the owner's setting, the registry's
`price_per_message`. `Tribe.messageAmountMsat` (`Tribe.swift:69-71`) is
what a member's message actually sends: price plus escrow, at least
3 sats, as the official apps send (`Tribe.swift:87-90`). The engine
charges the second (`Engine+Messages.swift:202`, `Engine+Tribes.swift:121`).

So the header is right about what you pay: "3 sats a message"
(`ConversationView.swift:207`). The details are right about the owner's
price and wrong as an answer: "Per message: Free" (`TribeDetails.swift:116`)
reads as "messages cost nothing", and every message sends 3 sats. The same
split exists for joining: details say "Price to join: Free"
(`TribeDetails.swift:115`, the raw `priceToJoin`), the Join form says
"Joining costs 1 sat" (`SidebarForms.swift:49`, `joinAmountMsat`,
`Tribe.swift:359-362`). The CLI repeats it: `tribes` prints the amount
sent, `tribe-info` the raw price (`peel/Commands+Tribes.swift:15`, `:49`).

Fix (batch 6): what a person pays is the one number shown, everywhere.
Details read "Each message: 3 sats" and "To join: 1 sat", from
`messageAmountMsat` and `joinAmountMsat`, with the breakdown under them
only when it differs ("Price 0 · escrow 0 · 3-sat minimum"). One
formatter, `Tribe.costLines`, or a `Formatting` function, used by the
header, the details, the Join form and the CLI. Keep both fields; the
form edits the price, the engine sends the amount.

Done (batch 6, 2026-10-09): `TribePrice` in `Tribe.swift`, one per
price (`Tribe.messagePrice`, `TribeInfo.joinPrice` and `messagePrice`,
`TribeSettings` for the owner's form). `messageAmountMsat` and
`joinAmountMsat`, which the engine sends, are its `msat`. The details
read "To join: 1 sat, the minimum" and "Each message: 25 sats,
including 5 sats escrow"; the owner's edit form keeps the typed price
with "Members pay 3 sats, the minimum." under it when that differs;
`tribe-info` prints "you pay" beside the owner's prices. Prices are
exact (`Sats.exact`: "0.5 sats", "3.5 sats" where `Sats.format` would
drop the fraction) in the details, the header, the link card, the Join
form and the CLI's tribe lines. The 1-sat join floor is the Mac app's (`nonZeroPriceToJoin`
in `GroupsManager`); the tribes server checks only `price_to_join`.

## 4. The Peel component library

Everything lives in `Sources/PeelApp/UI/`. `Theme` stays the only source
of colours and gains a handful of size tokens. `FormKit`'s fields,
`FieldChrome`, `InlineConfirm`, `PeelMenu` and `CopyButton` stay where
they are; they already work this way. Names follow shadcn so the
mapping is obvious.

### Tokens (batch 1, finished in 14)

```swift
extension Theme {
    enum Radius { static let control = 7.0, card = 9.0, panel = 12.0 }  // capsule for chips
    enum Space  { static let xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 20.0 }
}
```

Ten radii become three and a capsule. Type sizes drop 12.5 and 13.5. A
text style replaces the 58 hand-set captions:
`Text(note).muted()` is 12 pt `secondaryText`, wrapping (shadcn's
`text-muted-foreground text-sm`). Avatars take a size scale: 16, 20, 24,
32, 48, 64.

### `PeelButton` (batches 1–2)

```swift
Button("Save") { … }.buttonStyle(.peel(.primary))
Button("Join") { … }.buttonStyle(.peel(.outline, size: .sm))
Button("Show in Finder") { … }.buttonStyle(.peel(.link))
// variant: .primary .secondary .outline .ghost .destructive .link
// size:    .sm (28) .md (32, default) .lg (40, onboarding)
// fill:    replaces primary's colour (the armed money button)
```

shadcn's `Button` with `variant` and `size`. It is `FormButtonStyle`
grown up: the same drawing, plus sizes and `link`. `buttonProgress` and
`filledButton` move into the same file.

```
 primary    secondary   outline     ghost      destructive   link
[▓ Save ▓] [░ Copy ░]  [  Copy  ]   Copy      [▓ Leave ▓]   Show in Finder
```

Replaces `FormButtonStyle` (43 call sites), `GhostButtonStyle` (22),
`PrimaryButtonStyle` (4), `SecondaryButtonStyle` (1), `LinkButton` (6),
`HeaderAction` (2), 7 hand-styled link buttons and about 10 of the
hand-drawn text buttons. About 95 call sites. Chat cards use `.sm`,
panels and forms `.md`, onboarding `.lg`.

### `IconButton` (batch 3)

```swift
IconButton("xmark", help: "Close")                     // ghost, 28 × 28
IconButton("ellipsis", help: "More", lit: menuOpen)
IconButton("phone", help: "Start a call", working: starting)
IconButton("arrow.up", help: "Send", variant: .primary, size: .sm)  // the composer
```

shadcn's `<Button variant="ghost" size="icon">`. It always sets `help`
and the accessibility label, has a hover state, and takes `lit` and
`working`. Replaces `HoverIconButton` (11), `HeaderButton` (8) and about
12 of the 19 hand-drawn icon buttons. Stays apart: the call window's
control bar (`CallWindow.swift`, its own `segment` and `pill`) and controls
drawn over media (`ImageViewer.swift:182-194`, `MediaViews.swift:219-227`),
which get an `.overlay` variant only if a third one appears.

### `Panel` (batches 4a and 4b)

```swift
Panel("Tribe details", close: done) {
    body
} actions: {                       // top right, before the close button
    IconButton("link", help: "Copy link") { … }   // a CopyButton, icon only
} footer: {
    Button("Members", action: members).buttonStyle(.peel(.outline))   // leading: navigation
    Spacer()
    InlineConfirm(trigger: "Leave tribe", prompt: "Leave #hive?", confirm: "Leave") { … }
}
```

shadcn's `Card` with `CardHeader`, `CardTitle`, `CardAction`,
`CardContent` and `CardFooter`, shown in a popover.

```
┌──────────────────────────────────────────┐
│ Tribe details                     🔗   ✕ │  title; utility actions top right
│──────────────────────────────────────────│
│ body                                      │
│──────────────────────────────────────────│
│ [Members] [Edit tribe…]      [Leave tribe]│  navigation left; commit or destructive right
└──────────────────────────────────────────┘
```

The placement rule, written into `docs/design/README.md`:

- A panel's own utility actions (Copy link, Copy key) go top right,
  beside the title, as icon buttons.
- Navigation (Members, Edit tribe…, Back) goes bottom left.
- The commit (Save, Send, Join) or the destructive action (Leave, Remove
  contact…) goes bottom right. One of them, never both.
- Every panel has a title and a close button, the same box, and one of
  two widths (372, or 320 with `compact`).

`FormPopover` becomes `Panel`; `FormFooter` becomes its footer's
trailing side. `DrawsOwnPanelBox` and the presenter's second box
(`MenuPresenter.swift:478-491`) go: every panel draws one box. Call
sites: 7 `FormPopover` users and the 5 hand-drawn panels. The contact's
and the tribe's details share a hero (`PanelHero`: icon, name, one muted
line), Remove contact… moves to the footer's right like Leave tribe, and
the contact's switch becomes `FormSwitchRow`.

### `Composer` (batch 5)

Tom: the send button goes inside the field, as the attachment should.

```
today
 (📎) (⚡)  ╭──────────────────────────────╮  (⬆)
            │ Message Bob                   │
            ╰──────────────────────────────╯

proposed
 ╭───────────────────────────────────────────╮
 │ ┌ Replying to Ann · "see you there"   ✕ ┐ │  reply bar and file tray, as now
 │ Message Bob                               │
 │ 📎 ⚡                                   ⬆ │  icons on the field's last line
 ╰───────────────────────────────────────────╯
```

shadcn's `InputGroup` with an `InputGroupAddon` at `block-end`. The
field keeps its radius-18 shape (`ComposerView.swift:135-136`) and now
holds everything. Attach and the bolt (Send or request sats, in a direct
message only) are ghost `IconButton`s at the
bottom left; send is a small primary `IconButton` at the bottom right,
filled when there is something to send and muted otherwise. One row of
icons under the text keeps the text's left edge still and leaves room
for eight lines. `MentionSuggestions`' fixed `.padding(.leading, 62)`
(`ComposerView.swift:158`), which assumes two buttons outside, aligns to
the field instead. The tray's "+" tile (`AttachmentViews.swift:438-448`)
stays. One file, `ComposerView.swift`, plus the tray's padding.

### `SectionHeader` (batch 10)

```swift
SectionHeader("Members")                       // 12 semibold, secondary
SectionHeader("Pending", trailing: { Badge("3") })
```

shadcn has no component; its blocks use `text-sm font-medium
text-muted-foreground`. Replaces `SectionLabel` (5), the `FormSection` and
`SettingsSection` titles and the Payments day heading. `SidebarSection`
keeps its own, collapsible, built on it.

### `Card` and `Callout` (batch 10)

```swift
Card { … }               // raised: formCard today
Card(.inset) { … }       // in a chat: cardBoxed today
Callout(.attention, "Not enough sats", detail: "…") { actions }
```

shadcn's `Card` and `Alert`. Card replaces `formCard` (11), `cardBoxed`
(4), `panelBoxed` (2) and the three hand-drawn boxes, at one radius.
`Callout` replaces `NoticeBar`, `AttentionNote` and `DownloadBar`'s
shell. `menuBoxed` stays for menus and the hover bar.

### `Badge` and `Chip` (batch 11)

```swift
Badge(count: 12)                         // ( 12 )   accent, the unread count
Badge("New")  Badge("+350", .success)    // ( New )  ( +350 )
Badge("Today", .outline)                 // the day divider
Chip("design", selected: $on)            // ( ✓ design )  a tag
```

shadcn's `Badge` (default, secondary, outline) and `Toggle`. Replaces
`UnreadBadge` (5 uses), `NewContactBadge`, the day divider label and the
tag chip. The boost chip keeps its content (bolt, total, faces) inside
`Chip`'s capsule. The video duration stays as it is, on the picture.

### `ListRow` and `FactList` (batch 12)

```swift
ListRow(selected: isOn, action: open) {
    Avatar(…)                  // leading
} title: { Text(name) } detail: { Text("2 min ago") } trailing: { … }

FactList {
    Fact("Owner") { … }
    Fact("Each message") { Text("3 sats") }
}
```

shadcn's `Item` and a description list. `ListRow` owns hover and the
selected fill (`Theme.selection`, one value). It replaces `MemberRow`,
`ZoneRow`, `SearchResultRow`, `InviteRow`, `MentionRow`, the boosters'
rows and `PaymentListRow`'s shell (7 views). `FactList` replaces
`DetailRow`, `SettingsRow` and `KeyValues` (3).

### `EmptyState` (batch 13)

```swift
EmptyState("Payments you send and receive show up here.")
EmptyState("Could not load the page.", systemImage: "wifi.slash") {
    Button("Try again", action: retry).buttonStyle(.peel(.outline))
}
```

shadcn's `Empty`. Replaces `EmptyPlace` and the four other empty states
listed above.

## 5. Bugs, not style

1. **Copy link is the system button** in the members panel
   (`ConversationView.swift:350`): no style is set. Batch 4b. Fixed in
   4b (rendered before and after).
2. **"Per message: Free" for a 3-sat message, and "Price to join: Free"
   for 1 sat** (`TribeDetails.swift:115-116`). Batch 6.
3. **Lowercase fragments as sentences.** `PeelError.readable` returns
   words that start a sentence ("the server could not be reached").
   About 30 places show them bare, with no capital and no full stop:
   18 problem lines (`AccountView.swift:192`, `:305`, `:740`,
   `AppModel.swift:250`, `:312`, `ContactsViews.swift:252`,
   `LockView.swift:88`, `OnboardingView.swift:211`,
   `PayInvoicePane.swift:62`, `PaymentViews.swift:187`, `:311`,
   `PaymentsView.swift:67`, `:145`, `ReceivePane.swift:36`, `:73`,
   `SidebarForms.swift:104`, `TribeViews.swift:217`, `:449`), the
   window's notices (`AppModel.swift:1078-1187`, nine of them, and
   `AppModel+Calls.swift:55`), and money refusals shown under a Pay
   button (`AppModel+Payments.swift:50`, `:81`). Batch 7.
4. **Header icons have no hover state** (`HeaderButton`,
   `ConversationView.swift:268-290`), while every other icon button
   lights up. Batch 3.
5. **The design README is stale on buttons.** It says the popover forms'
   commit buttons and inline confirms are `GhostButtonStyle(prominent:
   true)` (`docs/design/README.md`, "A button while it works"); they are
   `FormButtonStyle`. Batch 2.

A risk, not a bug (batch 9): four `KeyMonitor`s (`ChatSearch`,
`ImageViewer`, `Sidebar`, `MenuPresenter`) can be live at once, each
reading raw key codes, and eight places handle Escape. Each guards its own
case today (the sidebar defers to an open menu or the viewer,
`Sidebar.swift:136`; the viewer ignores the call window,
`ImageViewer.swift:113`). Nothing written down says who wins when two
want the same key, so the next one added can break it.

## What is healthy

So the next review does not redo it: menus (no native ones anywhere),
fields (`FieldChrome` everywhere), `InlineConfirm`, `CopyButton`'s
feedback, `Sats` formatting, member counts, link parsing in `PeelCore`,
`Theme` as the colour source, and ⌘F and ⌘I with one owner each. The
code itself is DRY by a clone detector's measure; what it lacks is a
library outside forms.

## Progress

- **Batch 1, `PeelButton` (2026-10-09).** Built as
  `PeelApp/UI/PeelButton.swift` (not `Button.swift`: the name says what
  it is beside SwiftUI's `Button`). `FormButtonStyle` is gone. Its 43
  call sites and `InlineConfirm`'s two now use `.peel(...)`, mapped 1:1
  (outline, primary, ghost, and primary with `fill`), and the default
  drawing is `FormButtonStyle`'s. `buttonProgress` and `filledButton`
  moved with it. `Theme.Radius` (`control`, `card`, `panel`) is in, and
  `PeelButton` and `FormKit` use it. `Theme.Space` waits for a consumer
  (batch 14). New: sizes (`sm` 28, `md` 32, `lg` 40) and the `link`
  variant, at regular weight. There is no full-width option: a label
  with `.frame(maxWidth: .infinity)` does it, as Receive's Done and New
  invoice already did.
  - Focus styling was left out. It is unverified, it may double the
    system's focus effect, and `isFocused` lights up for any focusable
    ancestor, such as the sidebar's scroll view. It comes in a later
    batch, checked with keyboard navigation on.
  - Renders: the screens rendered before and after match pixel for pixel
    where buttons moved. The Payments list rows differ, but those are
    not buttons. Not rendered after: the armed Send button (only a forced
    gallery shows `fill`), tribe details' Revert and Save (below the
    panel's scroll), and Pay an invoice's buttons (they need a real
    invoice, and the loopback stack has no Lightning). Hover and pressed
    were never rendered in the app, because the offscreen app is never
    active. A temporary gallery forced them through the real drawing
    code instead.
- **Batch 2, the older buttons onto `PeelButton` (2026-10-10).**
  `ButtonStyles.swift` is deleted: `GhostButtonStyle`, `PrimaryButtonStyle`
  and `SecondaryButtonStyle` are gone, and `LinkButton` left `Controls`.
  Their call sites and the hand-styled text buttons in the batch's files
  use `.peel(...)`: `GhostButtonStyle()` is `.outline` `.sm` (17 sites),
  `prominent` is `.primary` `.sm` (5), `PrimaryButtonStyle` `.primary`
  `.lg` (4), `SecondaryButtonStyle` `.outline` `.lg` with a full-width
  label (1), `LinkButton` and the hand-styled links `.link` at the size
  of their text (11), the Payments header's `HeaderAction` `.outline`
  `.sm`, `.secondary` while open, and onboarding's Back `.ghost` `.lg`.
  The web pane's "Try Again" is "Try again".
  - Not 1:1, the closest chosen: the old outline buttons (chat cards,
    bars, headers) were 13 regular, radius 6, a `divider` border, no fill
    and no hover; they are now 12 medium, radius 7, `inputBorder` on
    `fieldFill`, with hover, and about 3 pt narrower; the filled ones were 13 medium
    and are 12 medium. Onboarding's buttons
    were 14 bold (primary) and 14 regular (secondary); both are 14 medium,
    and Restore gains the outline's fill. Back was 14 regular
    `secondaryText` with no box; it is `.ghost`: `text` colour, medium, 16
    pt in from the edge, with a hover fill. Paste twelve words and
    Reconnect now were `accent`; they are `link` blue, as every other text
    action. Show in Finder, Try again, Reconnect now and the scan zone's
    Paste and Choose picture… were medium; `.link` is regular. The
    Payments header buttons were 13 regular and 26 tall; they are 12
    medium and 28, and the open one loses its border (`PeelButton` has
    no selected state). A squeezed label now truncates on one line, as
    every `PeelButton` does, where the old styles wrapped it (the image
    viewer's Download broke as "Downl / oad" in a narrow gallery).
  - Left by hand: the call header's split Join and chevron (batch 3, with
    the icon buttons), and the small text actions inside rows (Approve
    and Decline, Unpin, a payment row's Retry and Cancel; muted or
    `accent` 11–12 pt with a mini spinner), which have no variant yet
    (batch 12).
  - Renders: the welcome screen on a new development profile, and a
    temporary gallery (not committed) of every moved call site, drawn
    before on `origin/main` and after, in light and dark. The screens
    themselves need a chat with cards, a call, Payments or the web pane,
    which the loopback stack was not run for. Hover and pressed were not
    rendered (the offscreen app is never active).
- **Batch 3, `IconButton` (2026-10-11).** Built as
  `PeelApp/UI/IconButton.swift`. `HoverIconButton` (`Controls`) and
  `HeaderButton` (`ConversationView`) are gone, and so is the web pane's
  `ToolbarIcon` wrapper. Their call sites use `IconButton`: the chat
  header's search, call and More, the search bar's newer, older and close,
  the thread and Payments panes' close, `FormPopover`'s close, the image
  viewer's close, the web pane's toolbar and download bar, a file card's
  globe and download, the hover bar's Reply and Boost, `MenuButton` (so
  every message and web More), `CopyButton`'s icon-only form and the call
  window's keep-on-top pin. Moved from hand-drawn: the notice bar's
  dismiss (`.sm`), the sidebar's connection bolt (`.sm`, lit while its
  card is open) and the sidebar call bar's microphone (`.outline`). The
  call header's split Join is one outline box (`fieldFill`,
  `inputBorder`, radius `control`) holding a `.peel(.ghost, size: .sm)`
  Join and a ghost `IconButton` chevron, with an `inputBorder` line between.
  `HeaderMoreButton` is a `MenuButton` with its details popover and ⌘I.
  - The bug: header icons now light under the pointer. Every icon button
    that opens a menu is lit while it is open (`MenuButton` reads the
    presenter's source, as `HeaderButton` did for More): a message's
    More, the web pane's ⋮ and the header's call button and chevron gain
    it.
  - Not 1:1, the closest chosen: header icons were 14 pt and are 13, as
    every other icon button was. The hover square is 28 × 28 at radius 7
    (was 28 × 26 at radius 5 for the hover buttons, 28 × 28 at radius 6
    for the header), so `FormPopover`'s title row and the hover bar are 2
    pt taller. Disabled is 50% opacity everywhere (the search bar's arrows
    were 40%, the web toolbar's 35%). The notice bar's dismiss was a bare
    10 pt semibold cross; it is the 13 pt regular cross on a 24 square,
    and the bar keeps its height to within a point. The split Join's text was 13 semibold
    and is 12 medium, its border `divider` and now `inputBorder` on
    `fieldFill`, its chevron cell 24 wide and now 28, and each half has a
    hover. The microphone was 30 square with a `divider` border and no
    fill; it is 28, the height of Return to call beside it, as an outline.
    The bolt gains a hover fill. VoiceOver now reads the tooltip as the
    label where the two differed: "Mute (⌘⇧A)" for "Mute", "Start a new
    call" for "More call options".
  - Review, applied: a disabled button never draws lit, and drops a hover
    it may never hear end. Not applied: the split Join's halves draw their
    hover on their own rounded shape, so it does not meet the divider
    square (a group variant with inner corners squared waits for a second
    split button); its outline box is drawn by hand from the same tokens
    as `.outline`, for the same reason; VoiceOver's "Mute (⌘⇧A)" (one
    label for tooltip and VoiceOver keeps `IconButton` simple, and the
    header buttons already read their shortcuts). `/simplify`, applied:
    one `MenuPresenter.isOpen(from:)` for "this button opened the open
    menu" (`MenuButton`, the call header), `.md` reads `PeelButton`'s `.sm`
    height. Not applied: folding `IconButton`'s chrome into `PeelButton` as
    an icon size, so hover, pressed and disabled have one owner (it
    changes `PeelButton`, which this batch leaves as batch 2 shipped it;
    worth doing with the focus styling); a disabled `PeelButton` keeps a
    stale hover as `IconButton` did before its fix, for the same reason.
  - Stay apart, as section 4 says: the call window's control bar,
    controls over a picture or video, the jump to newest button, and the
    composer's attach, bolt, send, reply close and file tray (batch 5).
  - Renders: a new development profile with a contact and a tribe seeded
    as local rows (no server), before (`origin/main`) and after: the main
    window, a contact's chat, the search bar, Send sats, a tribe's chat;
    and a temporary gallery (not committed) of the icon buttons at rest,
    lit, working and disabled, the notice bar and a live call's split
    Join, in light and dark, with hover forced through the real drawing
    code after. Not rendered at their sites: the hover bar, a file card,
    the web pane, the image viewer, the thread and Payments panes, the
    call window and the sidebar call bar (they need media, a thread, a
    page or a call). Hover and pressed were not rendered in the app (the
    offscreen app is never active).
- **Batch 4a, the `Panel` shell (2026-10-11).** Built as
  `PeelApp/UI/Panel.swift`: `FormPopover` moved out of `FormKit` and
  renamed, `Panel("Title", compact:, close:) { body } footer: { … }`
  (the title unlabelled, as SwiftUI's own views take theirs). Its
  drawing is unchanged, and `DrawsOwnPanelBox` moved with it. The seven
  `FormPopover` users are on it: Add contact, Invite someone and an
  invite (`ContactsViews`), Send or request sats (`PaymentViews`), Tribe
  details (`TribeDetails`), Join a tribe (`SidebarForms`), Create and
  Edit tribe (`TribeViews`). `MenuPresenter` changed only in `PanelBox`'s
  comment.
  - Left for 4b, which needs them: the `actions` slot (no panel in 4a
    has a top-right action yet), and retiring `DrawsOwnPanelBox` and the
    presenter's menu box, which the five hand-drawn panels still use
    until they move onto `Panel`. `FormFooter` stays a separate piece: it
    is also the footer of Receive, Pay an invoice and the Account's name,
    none of them panels. The tribe header in `ConversationView` has a
    `private enum Panel` (members, details, edit) that hides the struct
    inside that type; 4b renames it when it puts a `Panel` there. 4b
    also adds a `Panel` with no footer, for the panels that have none.
    (The review asked for both now; left, since 4b owns those files.)
  - Renders: a new development profile on the loopback stack (a contact
    and a tribe of its own, an invite of 500 sats, funded by the Bank),
    before (`origin/main`) and after, offscreen, the same drive file:
    the main window, Send sats, Tribe details, Edit #Hive, Add contact,
    Invite someone, the invite's detail, Create a tribe and Join a tribe.
    All 19 snapshots (ten of the main window, nine of the panel's own
    window) match pixel for pixel. A temporary driver step (not
    committed) opened the panels with no shortcut. Not rendered: Add
    contact's "Sent to" state, Request sats (its title is the call
    site's only other string), an invite still loading.
  - Seen while checking, not changed: ⌘I (Tribe details) opened the
    panel on the first run of a fresh profile, then did nothing on later
    runs in both builds (the composer held the keyboard; the cause was
    not looked into). The title click's path (`panel = .details`)
    opened it each time. Worth a look with batch 9 (keys).
- **Batch 4b, the five panels onto `Panel` (2026-10-11).** The members
  panel, a contact's Details, Boosts, Connection and the Account's Time
  zone picker are `Panel`s, so every popover is one box. `Panel` gained
  the `actions` slot (top right, before the close button) and inits with
  no actions, or none and no footer; a footer whose condition is false
  takes no room. `PanelHero` (picture, name, muted lines) is the top of
  both details panels. `DrawsOwnPanelBox` and the presenter's `PanelBox`
  are gone. `TribeHeader`'s `private enum Panel` is `HeaderPanel`.
  - The bug: the members panel's Copy link (not Tribe details' footer, as
    the brief said: that footer never had one) was the system button,
    confirmed in the before render. It is now an icon `CopyButton` top
    right. Tribe details keeps Copy link and Copy QR image in its share
    card, beside the QR code, rather than a second Copy link top right;
    a contact's Copy key and Copy QR stay in their key card likewise.
  - The placement rule, applied: Tribe details' Edit tribe… moves left,
    beside Members; Leave tribe stays right. Remove contact… leaves the
    body for the footer's right, an outline button (red only once
    confirming, as Leave tribe), its explanation above Cancel and Remove.
    Reconnect now is the Connection footer's outline button. Edit tribe's
    Delete stays the last card of its body, since Save holds the footer.
  - Every visual difference, before (`origin/main`) to after: all five
    gain the panel box (radius 12 not 8, `sidebar` fill not `menu`,
    `formEdge` hairline, `popoverShadow`), a 15 pt bold title and a ✕.
    Widths: members 300 to 320, Boosts 260 to 320, Connection 260 to 320,
    Details 300 to 372, Time zone 320 (unchanged). Members: Copy link from
    the system button bottom left to an icon top right; no divider over
    the footer; the owner's panel has no footer (it had a divider and Copy
    link); a problem shows in the footer's left. Details: titled
    "Details"; the hero is left-aligned with a 56 pt picture (was centred,
    64), the name may wrap to two lines; the switch is `FormSwitchRow`
    (Peel's switch in a card, its note inside the card at 11 pt, was the
    system switch with a 12 pt note under it). Boosts: title 15 bold (was
    14), the total moves from top right (13 semibold) to a muted line
    under the title, "63 sats from 3 boosts". Connection: titled
    "Connection"; the state is 13 regular (was 14 medium) and 4 pt
    further from the error line; Reconnect now is an outline `.md` button
    at the footer's right (was a `.link` under the error). Time zone:
    titled, the field 10 pt below the title and 12 pt above the list (8
    before), the field inset 18 (was 8); the rows keep their old place
    against the field. A title's minimum gap to the buttons beside it is
    16 pt (about 24 before), which a long title in Edit #… may use. Main windows: unchanged (the renders differ only in a
    time-stamped error notice).
  - Renders: new development profiles b4b-alice and b4b-bob on the
    loopback stack, funded by the Bank (a temporary test, not committed),
    a DM, a tribe each owns and has joined, and Bob's boosts on Alice's
    post (forwarded boosts failed on the stack with a CLTV error, so the
    Boosts panel is drawn from Bob's side, his own). Before and after,
    offscreen, the same drive file: Connection, Details, Boosts, Members
    as owner and member, Tribe details as owner and member, Time zone.
    Tribe details as a member matches pixel for pixel; as owner only the
    footer differs. Remove contact's confirm drawn once after. A
    temporary driver step and hooks (not committed) opened the panels.
  - Idle: Connection open for a minute, 0.0 to 0.2% CPU.
  - Not rendered: Connection offline (countdown and Reconnect now), the
    members panel's problem line, Leave's confirm, Light mode. Hover and
    clicks were not driven (the offscreen app is never active).
  - Independent review, not applied: a click on the zone picker's list
    outside a row (the divider, the heading, "No time zone matches.") now
    ends editing in its search field, through `Panel`'s
    `endsEditingOnClick` (a row click is unaffected); a tribe header
    with no stored tribe can open an empty, now boxless, popover; the
    members footer can crowd when a problem shows while Leave asks; Remove
    contact leaves the panel to close with its chat, as before.
- **Batch 5, the composer (2026-10-10).** Attach, the bolt (a direct
  message's Send or request sats) and send are inside the one rounded
  field, on a row under the text: attach and the bolt at the left, send at
  the right. The reply bar and the file tray stay at the field's top, as
  before. Only `ComposerView` changed; the tray's padding in
  `AttachmentViews` did not need to.
  - Attach and the bolt are ghost `IconButton`s (28 square); the bolt is
    `lit` while its panel is open, drawn as under the pointer, where it
    was `attention` amber before. Send is `PeelButton` `.sm`, a
    28 pt square: `.primary` when there is something to send, `.ghost`
    and disabled otherwise (a half-opacity arrow, no fill). The old one
    was a 28 pt `accent` circle, muted grey when empty; the new one is
    `button` blue in a rounded square. Its label is framed to `.sm`'s
    height less its padding, so it is square: `IconButton` has no primary
    variant, so send stays a `PeelButton` until a second filled icon
    button wants one.
  - New: a click anywhere in the field that no button or the text takes
    puts the cursor in the text (a tap on its background, hidden from
    VoiceOver), and so does a click on the reply bar outside its ✕.
    Before, only a click on the text itself did.
  - The field keeps radius 18 but is now `.continuous`, like the reply
    bar's top corners: with the button row it is always taller than twice
    the radius, which was the reason for `.circular`.
  - The mention suggestions line up with the field's left edge (the
    composer's 20 pt inset) instead of a fixed 62 that assumed the
    buttons outside.
  - Unchanged: Return sends, Shift- and Option-Return add a line, Escape
    stops replying then closes the thread, the `@` keys, focus, drafts,
    the paid attachment's price, the eight-line limit and the
    placeholder. `ComposerField` is untouched. There is no edit banner
    in Peel to keep (editing a sent message is not built).
  - Renders: before (`origin/main`) and after, offscreen on new
    development profiles on the loopback stack (a DM with Bob, a tribe
    at 3 sats a message), drawn at the same window width: empty, one
    line, several lines, a picture in the tray with a 50-sat price,
    replying, Send sats open, and the narrowest window (760, the
    window's minimum). A temporary driver step (not committed) set the
    reply, the tray and the width, which no key reaches.
  - Real keys: typing, Shift-Return for a new line, Return sending (one
    two-line message, confirmed by the server, and the field cleared) and
    Escape ending the reply, in both builds. The timeline stayed drawn
    while Shift-Return grew the field, its last message moving up with
    the field's top, with no blank or jump. Idle with the
    composer focused and text in it: 0.0% CPU over 40 seconds (before:
    0 to 1.4%).
  - Not checked: the pointer (hover, the click in the field's empty
    part), since the offscreen app is never active and has no mouse
    step; the thread composer; light mode.
