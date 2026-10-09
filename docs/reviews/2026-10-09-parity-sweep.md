# Parity sweep against the official Mac app, 2026-10-09

Scope: Peel at `origin/main` `dcf79c4` (#110) against the official Mac app
in `~/Documents/sphinx-mac-v2`. Official paths are under
`com.stakwork.sphinx.desktop/`. Peel paths are under `Sources/`.

I walked the official app's `Scenes/` screen by screen: dashboard, chat
list, chat, the message menu, contacts and contact details, tribes and
tribe details, profile and settings, payments, invites, signup and restore,
notifications, the main menu and its key handling. For each feature I
searched Peel's code. Every "missing" below was checked by a search of
`PeelCore`, `PeelApp` and `peel`. Anything I did not read directly is
marked "(inferred)". Nothing was built or launched. No code was changed.

Out of v1 by Tom's decision, so not listed: People, LSATs, languages,
feeds and podcasts, Hive workspaces, the knowledge graph view (with the
official status-bar "Personal Graph" menu and its AI agent settings),
Jitsi, Tor and relay-era code, iPhone and push.

## Verdict

Peel already covers the daily loop at or past the official app: direct
messages, tribes with owner tools, threads, boosts, payments, invoices,
paid attachments, calls, invites and contacts. The official app has no
edit, forward, emoji reactions, block, archive, message info or
cross-chat message search, so none of those are parity gaps.

What is left is small. Six items are worth doing before the agent:

1. Delete a contact.
2. A Reply action on notifications.
3. Received Giphy messages, and animated GIFs.
4. `sphinx.chat` tribe and contact links in messages, as cards with Join
   or Add.
5. Search in a chat.
6. Fuller details pages for a contact and a tribe.

All are S or M. One more is a check, not a build: signing up with a fresh
invite in the app. The rest is either already planned for after the agent
in phase 10, or something Tom has decided against. Nothing is L.

The table is sorted by recommendation (before agent, after agent, skip),
then by importance for daily messaging and payments; what is built comes
last. Sizes: S is a day or less, M is a few days, L is a week or more.

## Table

| Feature | Official app (file evidence) | Peel (file evidence) | Already in a plan doc? | Size | Recommendation |
|---|---|---|---|---|---|
| Delete a contact | Right-click a chat, "Delete contact", confirmed. It deletes the server's stored messages (`Sphinx.deleteMsgs`), removes `c/<pubkey>` from core state and the local rows. Also on contact details. `Scenes/Dashboard/Chat List/View Controller/NewChatListViewController.swift:472-615`, `Crypter/SphinxOnionManager/SphinxOnionManager+ContactExtension.swift:25-66`, `+HandleStateExtension.swift:662` | Missing. No `deleteMsgs` call and no contact delete in PeelCore. The row menu says "no Delete chat: the engine cannot delete a conversation" (`PeelApp/Sidebar.swift:288-290`). | No | M | Before agent: today a contact can never be removed, and a restore must not bring one back. |
| Reply from a notification | `UNTextInputNotificationAction` "Reply" on every message notification. `Helpers/NotificationsHelper.swift:166-183` | Missing. The category has no actions (`PeelApp/Notifier.swift:75-80`); only the default click is handled (`Notifier.swift:374`). | Yes, `03-chat.md` "Notifications", "Open" | S | Before agent: a daily-use shortcut. It must refuse while Peel is locked. |
| Received Giphy messages | A type 0 message whose `content` is `giphy::` and base64 JSON; the GIF loads from Giphy's CDN. `Helpers/Giphy/GiphyHelper.swift` | Missing. No `giphy` anywhere in Sources; such a message shows the raw base64 text. | Yes, `10-v1-extras.md` item 4 ("Reading the format is needed even before the picker exists") | S | Before agent: colleagues send these and Peel shows garbage. Reading only; the picker stays after. |
| Animated GIFs | GIF attachments show a GIF overlay and play (`Scenes/Dashboard/Chat/Custom Views/Gif/GifOverlayView.swift`; playback inferred). | Partial. GIFs are recognised (`PeelCore/Media.swift:16,133`), but `ImageTile` draws one `CGImage` from `ImageCache` (`PeelApp/AttachmentViews.swift:119-160`), so only the first frame shows (inferred). | No | S | Before agent: needed for Giphy anyway; one view for both. |
| Tribe and contact links in messages | A `sphinx.chat` tribe link shows a card with the tribe's image and Join; a contact link shows a card with Add. `Scenes/Dashboard/Chat/Custom Views/New Chat View Rows/Link Previews/TribeLinkView.swift:145`, `ContactLinkView.swift:132` | Missing. Only https links are clickable (`PeelCore/MessageMarkup.swift:153-157`); a pasted tribe link is plain text. Join and Add forms exist (`PeelApp/SidebarForms.swift`, `PeelApp/ContactsViews.swift:103`). | No | M | Before agent: this is how tribes and people are shared in chat; the forms to open already exist. |
| Search in a chat | Search mode in the chat header, 3 characters minimum, a results bar with up and down. `Scenes/Dashboard/Chat/New Chat View Controller/NewChatViewController+SearchMessagesExtension.swift`, `Custom Views/Chat Search/ChatSearchResultsBar.swift` | Missing. The sidebar field filters chat names only (`PeelApp/AppModel.swift:251-258`). | Yes, `10-v1-extras.md` item 1 (planned after the agent) | M | Before agent: the one official chat feature a daily driver misses most, and the engine search it needs also serves the agent. ⌘K stays after. |
| Contact details page | Photo (click to enlarge), name, "connected since", full key with a QR, route hint, time zone sharing, Remove contact. `Scenes/Contacts/View Controllers/ContactDetailsViewController.swift:62-116` | Partial. ⌘I opens `ChatInfoPanel`: photo, name, short key, local time, time zone switch (`PeelApp/TimeZoneViews.swift:180`). No full key, QR, date or remove. | No | S | Before agent, with Delete a contact: it is where Remove belongs. |
| Tribe details page | Image, name, created date, prices, admin's name and photo, your alias and photo in the tribe, time zone, and a menu with Share (QR), Edit, Members, Delete or Exit. `Scenes/Groups/View Controllers/GroupDetailsViewController.swift:146-330` | Partial. `ChatInfoPanel` shows icon, name, public or private and the time zone (`PeelApp/TimeZoneViews.swift:180`); the header shows the summary and message price (`PeelApp/ConversationView.swift:186-200`). Members, Edit, Copy link and Leave are in the More menu. No date, admin, join price or QR. | Yes, `03-chat.md` "Tribes", parity table and "Open" | S | Before agent: small, and it rounds off the tribe screens. |
| Signing up with a fresh invite in the app | Signup with an invite code. `Scenes/Signup/View Controllers/WelcomeCodeViewController.swift` | Built, not proven in the app: the invite step exists (`PeelApp/OnboardingView.swift:68-75,201`); only the CLI was run. | Yes, `02-messaging.md` "Tasks, in order", item 3 | S | Before agent: a click-through on a throwaway invite, nothing to build. |
| Voice messages (record) | Mic button, records `audio.wav` (PCM, mono, 44.1 kHz), sent as type 6. `Helpers/Audio/AudioRecorderHelper.swift`, `Scenes/Dashboard/Chat/Custom Views/Chat View/ChatBottomView.swift:16-18` | Missing for recording. Playback is built (`PeelApp/MediaViews.swift:343`). | Yes, `10-v1-extras.md` item 3 | M | After agent: as planned; playback already covers what others send. |
| Giphy picker | Search and trending, gifs and stickers, recent. `Scenes/Dashboard/Chat/Custom Views/Giphy Search/GiphySearchView.swift`, `API/API+GiphyExtension.swift` | Missing. | Yes, `10-v1-extras.md` item 4 | M | After agent: needs Peel's own Giphy key; reading comes first. |
| Payment templates | Images to attach to a payment. `Scenes/Dashboard/Payments/PaymentTemplatesViewController.swift`, `Views/PaymentTemplatesView.swift` | Missing. | Yes, `04-money.md` "Open"; `10-v1-extras.md` status | M | After agent: as planned; rarely used. |
| Preferences sync | `/preferences` file on the memes server, encrypted. `Managers/Data Sync Manager/DataSyncManager.swift` | Missing. | Yes, `05-parity.md` "Settings sync" | M | After agent: as planned. |
| Self-hosted servers | Accepts any certificate (`allowUntrustCACertificate`). | Missing; Peel will pin a fingerprint instead. | Yes, `05-parity.md` "Self-hosted servers" | M | After agent: as planned. |
| Message search across chats | Not in the Mac app: the dashboard filters by chat name only (`ContactsService.updateChatListWith(term:)`). | Name filter built (`PeelApp/AppModel.swift:251-258`). | Yes, ⌘K in `10-v1-extras.md` item 1 | M | After agent: as planned; past parity. |
| Link previews (https) | Title, description and image under a message with a link. `Scenes/Dashboard/Chat/Custom Views/New Chat View Rows/Link Previews/NewLinkPreviewView.swift`, `Helpers/MetaDataCache.swift` | Missing. Links show their host (`PeelCore/MessageMarkup.swift:193-200`). | No | M | After agent: each preview is a fetch from your IP; decide the rule first, like the photo fetch rules of #42. |
| Per-tribe alias and photo | Set in tribe details and before joining. `Scenes/Groups/Views/TribeMemberInfoView.swift`, `GroupDetailsViewController.swift:231` | Missing. | Yes, `03-chat.md` parity table | S | After agent: few people use it. |
| Tribe image upload, tags, app URL in the form | `CreateTribeViewModel`, `Scenes/Groups/Views/TribeTagsView.swift`, `uploadPublicImage` | Partial. The form has name, summary, image link, prices, private, unlisted (`PeelApp/TribeViews.swift:94-126`). Tags and URLs are kept untouched on edit. | Yes, `03-chat.md` parity table and "Open" | S | After agent: only tribe owners need it. |
| Tribe link QR | Share in tribe details shows a QR. `GroupDetailsViewController.swift:324` | Missing. Copy tribe link is built (`PeelApp/Sidebar.swift:334`); `QRCodeTile` exists (`PeelApp/QRCode.swift`). | Yes, `03-chat.md` "Open" | S | After agent: copy covers most uses. Easy to fold into the tribe details page. |
| Pay a tribe member | Click a member's photo, popup with Send sats. `Scenes/Dashboard/Chat/Custom Views/MemberInfo/TribeMemberPopupView.swift:51` | Missing. The composer's bolt is only in direct messages (`PeelApp/ConversationView.swift:110`); boosts work in tribes. | No | S | After agent: boosts cover most of it. |
| Scroll to the message from a notification | Opens the chat. `Helpers/NotificationsHelper.swift` | Opens the chat; a message id is passed (`PeelApp/Notifier.swift:81`) but scrolling to it is still open. | Yes, `03-chat.md` "Notifications", "Open" | S | After agent: small polish. |
| Slash commands in the composer | `/` offers Giphy, audio call, video call, emoji, voice, send and request payment. `Scenes/Dashboard/Chat/Custom Views/Chat View/ChatMessageFieldView+MentionsMacrosExtension.swift:162-232` | Missing. The composer has attach and the bolt (`PeelApp/ComposerView.swift:82-118`); calls are in the header. | Partly: ⌘K actions are an open question in `10-v1-extras.md` item 1 | S | After agent: fold into ⌘K. |
| Diagnostics log window | A log view with Export and Clear. `Scenes/Diagnostics/DiagnosticsViewController.swift`, menu item in `Scenes/Dashboard/Custom Views/NewMenuListView.swift:23` | Partial. The connection card shows state, retry and the last error (`PeelApp/Sidebar.swift:357-425`). No log. | No | S | After agent: useful when the agent host misbehaves. |
| Deep links from outside Peel | `sphinx.chat` URL scheme: tribe, invite, invoice, share contact, call and more. `Info.plist:30-33`, `AppDelegate.swift:122-134`, `Helpers/DeepLinksHandlerHelper.swift:26-79` | Missing on purpose for now: no URL scheme, no `onOpenURL`. | Recorded as a security property in `reviews/2026-10-08-audit-input-web-media.md` row 1.9 | M | After agent: it opens Peel to outside input, so it needs its own security review. In-chat link cards cover the common case. |
| Sending a paid text message | Price on a text message (`sphinx/text`). `ChatBottomView.swift:161` | Partial. Buying and reading paid text is built (`PeelCore/Media.swift:9,22`); the price field is only on the files tray (`PeelApp/AttachmentViews.swift:438`). | Partly: `04-money.md` scope ("Paid messages") | S | Skip: rarely used. |
| Copy link, Copy public key in the message menu | `Scenes/Dashboard/Chat/...`; options in `CoreData/TransactionMessage/TransactionMessageInfoGetterExtension.swift:653-728` | Missing as menu items. Message text is selectable (`PeelApp/MessageViews.swift:1049`); Copy text and Copy call link are built. | No | S | Skip: selection does the job. |
| Message text size | View › Size: Big, Medium, Small. `AppDelegate.swift:593`, `Scenes/Main/Base.lproj/Main.storyboard` | Missing. | No | S | Skip unless Tom asks. |
| Appearance: System, Light, Dark | View › Appearance. `AppDelegate.swift:577` | Dark only (`PeelApp/PeelApp.swift:30`). | Decided: `design/README.md` "dark only for now" | M | Skip: decided. |
| Notification type and sound | Menus: Banner + Sound, Banner, Sound, Off; eleven sounds. `AppDelegate.swift:582-591` | Not taken; System Settings does it. | Decided: `03-chat.md` "Notifications", "Checked against the official Mac app" | — | Skip: decided. |
| Profile photo at signup | Photo step in signup. `Scenes/Signup/Custom Views/ProfileImageView.swift` | Not in onboarding; set on the Account screen (`PeelApp/AccountView.swift:79`). | No | S | Skip: one click away after signup. |
| "Share photo" and "Track actions" toggles | `Scenes/Profile/View Controllers/ProfileViewController.swift:223-247,324-363` | Missing. | Private photo is listed in `05-parity.md` "Settings sync" | S | Skip: `privatePhoto` is only ever set to false in the v2 code (`SphinxOnionManager+ContactExtension.swift:318,351`), so it changes nothing sent (inferred); tracking is analytics. |
| Camera QR scan | Signup only. `Scenes/Signup/View Controllers/QRCodeScannerViewController.swift` | Reads QR codes from pictures instead. | Decided: `05-parity.md` "Contacts" ("No camera") | — | Skip: decided. |
| Browse the tribes directory | Not in the Mac app: no directory or tribe search found in its code. | Missing. | `03-chat.md` parity table ("not checked") | — | Skip: not a parity gap. |
| Rename a contact after adding | Not in the Mac app: the edit is commented out (`Scenes/Contacts/View Controllers/NewContactViewController.swift:160-191`). A nickname is set only when adding. | Name is set when adding (`PeelApp/ContactsViews.swift:187`). | No | — | Skip: same as official. |
| Clear a chat's messages | Not on its own: only inside Delete contact and leaving or deleting a tribe (`NewChatViewController+BottomTopBarsExtension.swift:212`). | Missing. | No | — | Skip: comes with Delete a contact. |
| Block, edit, forward or share, message info, emoji reactions, archive | None in the Mac app. Its "reactions" are boosts (`Helpers/ChatHelper.swift:204-240`). | None. | No | — | Skip: not parity. |
| Message menu | Copy text, Copy link, Copy public key, Copy call link, Reply, Save file, Resend, Boost, Pin, Unpin, Delete. `TransactionMessageInfoGetterExtension.swift:653-728` | Built: Reply, Boost, Copy text, Copy image, Save as, Mark unread from here, Pin, Delete for everyone, Retry and Discard (`PeelApp/MessageViews.swift:901-972`). | `03-chat.md` | — | Built. |
| Delete a message for everyone | Delete request. `Scenes/Dashboard/Chat/View Model/NewChatViewModel+MessageMenuActionsExtension.swift:106-130` | Built: "Delete for everyone", confirmed in place (`PeelApp/MessageViews.swift:965`). | `03-chat.md` | — | Built. |
| Chat list: unread, mute, filters | Friends and Tribes tabs, unread and mention badges, Mark as read or unread, mute and notification level. `ChatListViewController+TabsExtension.swift`, `ChatListCollectionViewItem.swift`, `Scenes/Dashboard/Chat/Custom Views/Notifications/NotificationLevelView.swift` | Built: Tribes and Direct messages sections, Threads, Mentions, name filter, badges, Mark as read or unread, three levels (`PeelApp/Sidebar.swift:11-60,293-355`). | `02-messaging.md`, `03-chat.md` | — | Built. |
| Dock badge | `AppDelegate` `setBadge` | Built (`PeelApp/Notifier.swift:326-341`). | `03-chat.md` "Notifications" | — | Built. |
| Tribes: owner tools | Create, edit, delete, private approve and decline, kick, members, pin. `Scenes/Groups/` | Built (`PeelApp/TribeViews.swift`, `PeelApp/ConversationView.swift:302`). | `03-chat.md` parity table | — | Built. |
| Join a tribe with a preview | `Scenes/Groups/View Controllers/JoinTribeViewController.swift` | Built: name, summary, join and message prices (`PeelApp/SidebarForms.swift`). | `03-chat.md` | — | Built. |
| Contacts and invites | Add by contact info, invites with sats, cancel. `Scenes/Contacts/View Controllers/NewContactViewController.swift`, `NewInviteViewController.swift` | Built, plus QR from pictures and "New" for people who added you (`PeelApp/ContactsViews.swift`). | `05-parity.md` "Contacts" | — | Built. |
| Payments | Transactions, Request (invoice), Pay invoice, in-chat send and request. `Scenes/Dashboard/Payments/` | Built (`PeelApp/PaymentsView.swift`, `ReceivePane.swift`, `PayInvoicePane.swift`, `PaymentViews.swift:124`). | `04-money.md` | — | Built. |
| Paid attachments | `Scenes/Dashboard/Chat/Custom Views/New Chat View Rows/Paid Content/` | Built (`PeelApp/PaidAttachmentViews.swift`). | `04-money.md` | — | Built. |
| Files: types, players, viewer | Image, GIF, video, audio (WAV only), PDF, file; `MediaFullScreenView`. | Built: the same kinds checked by their bytes, any audio type plays, video and audio players, image viewer (`PeelCore/Media.swift`, `PeelApp/MediaViews.swift`, `PeelApp/ImageViewer.swift`). | `03-chat.md` "Attachments", "Video and audio playback" | — | Built. |
| Drag and drop, paste | `Scenes/Dashboard/Custom Views/DraggingDestinationView.swift`, `Custom Classes/PlaceHolderTextView.swift:121` | Built, including promised screenshots (`PeelApp/PasteboardFiles.swift`, `AttachmentViews.swift:511`). | `03-chat.md` "Drop and paste beyond Finder" | — | Built. |
| Web apps | `Scenes/Dashboard/WebApps/WebAppViewController.swift` | Built: the web pane (`PeelApp/WebPane.swift`); LSAT bridge out of v1. | `05-parity.md` "Web window" | — | Built. |
| Calls | `Scenes/Dashboard/Live Kit/` | Built (`PeelApp/CallWindow.swift`, `CallSession.swift`). | `06-calls.md` | — | Built. |
| Settings | Name, photo, address and QR, default boost, PIN timeout, change PIN, export keys, time zone, Logout, Remove account. `ProfileViewController.swift`, `Main.storyboard` | Built: the same on the Account screen, plus the payment confirmation threshold, server, notification text and website data (`PeelApp/AccountView.swift:17-60`). | `05-parity.md` "Account screen" | — | Built. |
| Keyboard | Escape closes things, Shift-Return for a new line, arrows and Tab in mention lists, ⌘V files. `NewChatViewController.swift:304`, `DashboardViewController.swift:852`, `PlaceHolderTextView.swift:70-134` | Built and more: ⌘, ⌘N ⌘I, R and B in the menu, ⌘↓ and End, Escape, call shortcuts (`PeelApp/PeelApp.swift:58-66`, `ConversationView.swift:296`, `MessageViews.swift:611`, `ComposerField.swift:162-176`). | `03-chat.md` "Chat UI", "Open" | — | Built. |
