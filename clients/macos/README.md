# Ember for Mac

A native macOS client for Ember, written in SwiftUI. It talks to any Ember deployment through the same
`/api/*` routes and WebSockets the web app uses, so the Worker needs no changes.

## Build and run

Requires macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
cd clients/macos
./scripts/bundle.sh          # builds build/Ember.app (universal, ad-hoc signed)
open build/Ember.app
```

`swift run` also works while developing, but without an app bundle macOS gives it no notifications.

The app icon (`Resources/AppIcon.icns`) is made from Ember's flame logo
(`apps/web/public/logos/app-icon.png`, copied to `Sources/EmberDesktop/Resources/ember-logo.png`).
To regenerate it after the logo changes, run:

```sh
swift scripts/make-icon.swift Sources/EmberDesktop/Resources/ember-logo.png Resources
```

Sign in with your Ember's address (for example `chat.example.com` or `ember.<you>.workers.dev`), and
the email and password you use on the web.

## What it does

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
- **Notifications.** When a room turns unread while the app is in the background, it posts a local
  notification. Clicking it opens that room.

Not yet: uploads, search, message permalinks, workspace administration, and huddles.

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

The frame types are mirrored in `Sources/EmberDesktop/Frames.swift`. If `packages/protocol` changes a
frame or bumps `ROOM_PROTOCOL`, update that file to match. Unknown frame types are ignored, so a newer
server won't break an older client.

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

The live test signs in, loads the sidebar, opens a room, sends a message, reacts to it, and deletes it.
