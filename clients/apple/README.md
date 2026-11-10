# Ember for Mac and iPhone

Native Mac and iPhone clients for Ember, written in SwiftUI. It talks to any Ember deployment through the same
`/api/*` routes and WebSockets the web app uses, so the Worker needs no changes.

## Layout

- `Sources/Shared`: everything both apps use. That's the API client, the sockets, rooms and threads,
  message formatting, uploads, search, huddles, and the views that suit both (messages, files,
  sheets, search). `Platform.swift` holds the few places the platforms differ.
- `Sources/macOS`: the Mac's own screens (split view, composer with keyboard shortcuts, thread panel).
- `iOS/Sources`: the iPhone's own screens (room list, room, thread sheet, composer with photo picker).
  `iOS/project.yml` compiles them together with `Sources/Shared`.

## Build and run

Requires Xcode 16 or later (Swift 6). The Mac app needs macOS 14 or later, and the iPhone app iOS 17
or later.

**Mac:**

```sh
cd clients/apple
./scripts/bundle.sh          # builds build/Ember.app (universal, ad-hoc signed)
open build/Ember.app
```

`swift run` also works while developing, but without an app bundle macOS gives it no notifications.

**iPhone:** needs [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd clients/apple
RUN=1 ./scripts/build-ios.sh # generates iOS/EmberPhone.xcodeproj, builds, and runs it in the simulator
```

To install it on your own iPhone, open `iOS/EmberPhone.xcodeproj` in Xcode, pick your team under
Signing & Capabilities, choose your phone, and press Run. A free Apple ID works, but apps installed
that way expire after 7 days.

Sign in with your Ember's address (for example `chat.example.com` or `ember.<you>.workers.dev`), and
the email and password you use on the web.

## What it does

Both apps do all of the following. On the iPhone, message actions (reply in thread, react, copy, edit,
delete) are in the long-press menu. Swiping a room stars it or mutes it. Files come from Photos or
Files, and downloads open the share sheet.

- **Sign-in.** Email and password. The session cookie is stored in the system cookie store, so you
  stay signed in between launches.
- **Sidebar.** Starred rooms, rooms in the workspace's shared order, and DMs ordered by latest
  activity. Unread rooms are shown in bold, and the Dock badge counts them. Option-Up/Down moves
  between rooms, and adding Shift moves between unread ones.
- **Messages.** Ember's formatting is shown: bold, italic, strikethrough, code and code blocks,
  quotes, lists, links, @mentions and link previews. Images show inline, and other files are links.
- **Composer.** Light Markdown (`**bold**`, `*italic*`, `~~strike~~`, `` `code` ``, fenced code
  blocks, `> quotes`, `-`/`1.` lists). Typing `@` offers people to mention. Return sends, and
  Shift-Return or Option-Return starts a new line.
- **Threads.** Reply in a thread from a message's hover bar or right-click menu. The thread opens
  beside the room, and a reply can also be sent to the room.
- **Message actions.** Edit and delete your own messages (administrators can delete anyone's), and
  add or remove reactions.
- **DMs and rooms.** Start a DM or group DM (⌘N), create an open or private room (⇧⌘N), star rooms,
  set each room's notification level, rename it, make it private, choose its members, delete it, or
  leave it.
- **People.** A searchable directory. Each person's profile has a Message button. You can edit your
  own name, bio, email, password and photo.
- **Files.** Attach with the paperclip, drag and drop, or paste a picture or files, into a room or a
  thread. Large files upload in parts, with progress. Pictures open full size, videos play inline, and
  other files download to Downloads.
- **Search (⌘F).** The web app's filters (room, person, mentions me, has a link, has a file, in a
  thread), newest or oldest first, recent searches, and paging. A result opens its room at that
  message, or its thread.
- **Permalinks.** Copy Link on any message. Links to your Ember inside messages open in the app. A room
  opened at an older message loads newer ones as you scroll, and has a Jump to newest button.
- **Huddles.** Start or join a room's huddle from the headphones in its header. While you're in one, a
  bar in the sidebar shows who's there and has Mute (⇧⌘D) and Leave. Rooms with a huddle going on show
  headphones in the sidebar.
- **Workspace administration.** Workspace settings, custom styles, chat bots and AI agents open the
  web app's own pages inside the app, signed in with your session.
- **Notifications.** When a room turns unread while the app is in the background, it posts a local
  notification. Clicking it opens that room.

## How it talks to Ember

- **Auth.** `POST /api/session` sets an HttpOnly session cookie (`__Host-session_token` over HTTPS).
  The Worker refuses writes and socket upgrades that don't look same-origin (`isCrossSite` and
  `isSameOriginUpgrade` in `apps/worker/src/auth.ts`). To pass those checks, every request carries
  `Origin: <server>` and `Sec-Fetch-Site: same-origin`. Socket upgrades attach the cookie by hand.
- **Workspace socket** (`/api/socket`) keeps the sidebar current, using `WorkspaceServerFrame`.
- **Room sockets** (`/api/rooms/:id/socket?visible=…&protocol=4&since=…`), using `ClientFrame` and
  `ServerFrame`. On reconnect the client passes `since` (the last `seq` it saw), and the room replies
  with only what changed (`resumed`). Messages sent while disconnected are confirmed with
  `message.check`.
- **Message bodies** are sent in the plain-paragraph form (`<p>…<br>…</p>`, with `&<>` escaped) that
  `packages/richtext` stores without parsing. Messages are shown from their `plainText`.

The frame types are mirrored in `Sources/Shared/Frames.swift`. If `packages/protocol` changes a
frame or bumps `ROOM_PROTOCOL`, update that file to match. Unknown frame types are ignored, so a newer
server won't break an older client.

## Huddles

macOS has WebRTC only in WebKit, so the call runs in a hidden web view. `HuddleEngine.swift` is
`apps/web/src/lib/huddle.ts` ported to plain JavaScript. Keep the two in step. The page is loaded at
the Ember's own origin, with the app's cookies, so its socket passes the Worker's same-origin check.
The web view sets `inactiveSchedulingPolicy = .none`; without it, WebKit suspends the view (it's never
in a window) and the call drops. If the microphone permission prompt never gets an answer, the engine
joins listening only after 8 seconds.

## Push notifications

Ember's push uses Web Push (VAPID), which a native app can't receive. So the client only notifies
while it's running. Notifying while it's closed would need APNs support in the Worker.

## Tests

```sh
swift test                   # protocol encoding/decoding
```

To also run the live test against a running Ember (for example `pnpm dev` in `apps/worker`), set:

```sh
EMBER_TEST_SERVER=http://localhost:8787 EMBER_TEST_EMAIL=… EMBER_TEST_PASSWORD=… swift test
```

The live tests cover: signing in; messages, reactions and threads; DMs, rooms, stars, notification
levels and profiles (with a second person signed in as a guest, which `pnpm dev` allows); uploads and
downloads; search and jumping to messages; the admin web view's session; and the huddle socket. A
server without huddles set up answers that they're off, which the huddle test accepts.
