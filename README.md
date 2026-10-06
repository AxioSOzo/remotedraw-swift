# RemoteDraw for Swift

RemoteDraw's Swift package. Three libraries, one package, no external
dependencies:

| Product | For | Platforms |
| --- | --- | --- |
| `RemoteDrawSenderKit` | The phone side: capture a stroke, put it on a board. | iOS 17+ (headless core also macOS 14+) |
| `RemoteDrawReceiverKit` | The surface side: show a session's ink, pair phones, undo/clear/end. | macOS 14+, iOS/iPadOS 17+ |
| `RemoteDrawInk` | The shared ink renderer both kits draw with. Re-exported by both. | macOS 14+, iOS 17+ |

## Install

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/AxioSOzo/remotedraw-swift.git", from: "0.4.0"),
],
targets: [
  .target(name: "MyApp", dependencies: [
    .product(name: "RemoteDrawSenderKit", package: "remotedraw-swift"),    // phone
    .product(name: "RemoteDrawReceiverKit", package: "remotedraw-swift"),  // surface
  ]),
]
```

In Xcode: *File → Add Package Dependencies…*, paste the URL, and link the
product(s) you need. `package:` is the repository basename (`remotedraw-swift`),
not a module name. Both kits re-export `RemoteDrawInk`, so an app that imports
both sees one set of ink types — no module qualification needed.

`from: "0.4.0"` is SwiftPM's up-to-next-major range; use
`.upToNextMinor(from: "0.4.0")` to stay on `0.4.x` while the API is `0.x`.

The receiver is documented [below](#receiver-remotedrawreceiverkit). Everything
until then is the sender.

## Sender: `RemoteDrawSenderKit`

The RemoteDraw sender. Capture a stroke, put it on a board.

Two ways in, and you can stop at either.

**The whole board, in one modifier.** The drawing surface the first-party
RemoteDraw app shows — paper and its tooth, sixteen instruments, the one-handed
control cluster, the long-press tool fan, shape snapping, and a map board's
geography — presented full screen with a way out:

```swift
Button("Draw") { drawing = true }
  .remoteDrawSurface(isPresented: $drawing, senderToken: token) { outcome in
    switch outcome {
    case .submitted(let receipt):     record(receipt)
    case .left:                       dismissBanner()
    case .expired:                    refreshSession()      // board over, or timed out
    case .credentialLost:             refreshToken()        // token died, board did not
    case .unsupportedSurface(let it): open(it.hostedSenderURL)
    case .failed(let error):          report(error)
    }
  }
```

**That is the whole integration.** There is no configure step: `RemoteDraw.shared`
installs production defaults the first time anything reads it. Call
`RemoteDraw.configure(_:)` from your `App.init` only to *override* something —
the API base URL, an anonymous device description, a token provider:

```swift
@main struct MyApp: App {
  init() { RemoteDraw.configure(.init(tokenProvider: mintSenderToken)) }
  …
}
```

This used to trap. `RemoteDraw.shared` called `preconditionFailure` when
`configure` had not run, from inside the modifier's own `.task` — and a trap is
not an `Error`, so the `catch` beside it could not turn a missing line of setup
into anything the host could see. It was a crash on the user's tap. If you want
the strict behaviour back, `try RemoteDraw.requireConfigured()` throws
`RemoteDrawError.notConfigured` and never auto-configures.

`RemoteDrawSurface` is the same board as a plain `View`, for a host that wants
it inside its own layout rather than over it; `RemoteDrawTakeover` is that view
plus the cover, the scene-phase wiring and the exit.

## Map boards, and bringing your own ground

A `kind: "map"` session draws **the geography** behind the ink, from the board's
own `coordinateSpace.bounds`, through the same board↔geography transform as
`@remotedraw/geometry` — checked vector by vector against the shared table in
`Tests/…/Fixtures/mapBoardGeometryVectors.json`. Nothing to wire: the modifier
above is already a map sender.

Points leave a map board in **board space with no `phoneProjection`**, which is
the server's native-map contract, and the camera is re-read continuously — so ink
lands on the geography actually on screen rather than the geography something
asked for.

Two things worth knowing when you create the session:

- **`coordinateSpace.bounds` is a hard fence, fixed for the life of the
  session.** No route changes it afterwards. Size it larger than the camera you
  open on — `RemoteDrawMapBounds.padded(by:)` is the same one-liner as the
  TypeScript's `padMapBounds`.
- **Omit it and there is no geography to draw.** The phone shows a flat map tone
  rather than guessing at a city, which is what the web fallback does.

### `background:` — your own cartography, or your own ground entirely

```swift
.remoteDrawSurface(isPresented: $drawing, senderToken: token) { ground in
  MapboxView(bounds: ground.mapBounds)                       // or Google Maps, or a floor plan
    .onCameraIdle { ground.reportViewport(currentBoardRectangle()) }
} onOutcome: { outcome in
  …
}
```

**Precedence, highest first:**

1. `background:` — wins on every board kind, and replaces the whole layer. This
   is how you keep your own basemap instead of Apple's; a customer whose board is
   a satellite view should not get a street map on the phone.
2. The built-in MapKit ground — `kind: "map"` with `coordinateSpace.bounds`.
3. The canvas's own ground — paper, whiteboard or a flat tone, from
   `RemoteDrawAppearance.ground` or the board's `target.kind`.

A ground that **moves** owes the surface one call:
`RemoteDrawGroundContext.reportViewport(_:)`, saying which board rectangle it is
currently showing. Every stroke is re-projected through it. A ground that does
not move calls nothing and every stroke stays in surface space.

The built-in map is deliberately **not** pannable — every touch belongs to the
canvas, the way the first-party board ships. Pass your own `MapInteractionModes`
to `RemoteDrawMapBoardGround`, or supply an interactive map through
`background:`, if you want the person to move the camera.

## What this SDK will not draw: streaming boards

A session created with `senderIntegrationMode: "streaming"`, or whose receiver
publishes `visualContext.enabled`, expects the sender to show the receiver's
screen live under the ink. **This package cannot.** It has no WebRTC, no video
decoder and no `WKWebView`, by the same decision that keeps its dependency count
at zero.

It now says so. The surface shows the reason instead of an empty pad, and the
host is handed `.unsupportedSurface(_:)` carrying a `hostedSenderURL` — the
hosted `/join` pad, already holding this sender's credential, which *is* an
implemented streaming consumer. Present it in a `WKWebView` and streaming works
today.

Previously this SDK did not decode either field, so a customer who asked for
streaming got **no behaviour change whatsoever** and a white screen with their
own ink on it.

**Or the headless core** — the wire, not the UI: a session, a capture layer that
keeps pressure and tilt, a renderer that draws RemoteDraw's ink, and nothing
that decides what your screen looks like.

```swift
import RemoteDrawSenderKit
import SwiftUI

struct BoardView: View {
  @StateObject private var model = BoardModel()

  var body: some View {
    ZStack {
      RemoteDrawInkCanvas(
        strokes: model.session?.strokes ?? [],
        live: model.session?.live,
        predicted: model.predicted,
        ground: .paper
      )
      RemoteDrawStrokeCapture(
        onBegin: { model.session?.begin(stroke: $0, tool: .freehand) },
        onSamples: { model.session?.append($0) },
        onPredicted: { model.predicted = $0 },
        onEnd: { id, reason in
          Task {
            guard let session = model.session else { return }
            if reason == .finished {
              try await session.end(stroke: id)
            } else {
              await session.cancelStroke()
            }
          }
        }
      )
    }
    .task { model.session = try? await RemoteDraw.shared.join(rawToken: model.token) }
  }
}
```

## What the host has to add to `Info.plist`

**Nothing.** This package opens no camera and advertises on no network. A token
comes in as a string and strokes go out over HTTPS.

That is worth protecting as the SDK grows: it is the difference between a
two-hour integration and a two-week one. The surface did not cost you a key
either — it stores five preferences (handedness, instrument, thickness, colour,
fill) in your app's own defaults, which needs a privacy-manifest entry and no
usage description. Anything that *would* need one is opt-in and says so in its
own type.

## What it does for you

| | |
| --- | --- |
| **Codec** | Points travel as `packedPoints` — base64url columnar delta + zigzag varint, ~13x smaller than the JSON array it replaces. There is no plain-points path, on purpose. |
| **Cadence** | One draft frame every 32 ms, carrying the newest state of the whole stroke. Append as fast as the hardware produces samples. |
| **Budgets** | 180 points per draft, 1200 per commit, applied by decimating the settled head and sending the tail verbatim — never by truncating, which throws away where the stroke began. |
| **Sequence** | Seeded from the server's `lastSequence` and healed from a `stale_sequence` rejection without a second round trip. |
| **Idempotency** | Commits are keyed by `clientStrokeId` and submissions by `clientSubmissionId`, so a request lost to a flaky radio is retried rather than duplicated. |
| **Credential** | A rejected sender token is rotated through `POST /v1/sender/refresh`, which leaves every other sender on the board alone. |
| **Presence** | A 5 s heartbeat while the surface is up, and a real disconnect on `leave()` — presence is a heartbeat, not a leave signal. |
| **Ink** | Tapered dynamic ribbons driven by pressure, tilt and velocity. `RemoteDrawInk` is the one renderer — the first-party app compiles it too — so a mark made through this SDK is the same mark. |
| **Capture** | Every sample UIKit saw, from `coalescedTouches` — not the one-per-refresh a `DragGesture` reports, which throws away three samples in four on a Pencil. |
| **Geography** | `RemoteDrawMapGeometry` — the board↔Web-Mercator transform, bit-identical to `@remotedraw/geometry` and pinned to its vectors. |

## Tokens

Two kinds, and the difference matters:

- `rd_send_…` — a **sender token**, minted by *your backend* through
  `POST /v1/sessions/direct-sender`. Joining is already done and nobody else on
  the board is disturbed. This is the normal case.
- `rd_join_…` — a **join token**, from a QR code or a link. Spending it mints a
  sender token *and revokes every other active sender on that session*. One live
  sender per board.

`POST /v1/sessions/direct-sender` needs your API key. **Never call it from the
app.** Mint the token on your server and hand the string to the SDK.

## Outcomes

`RemoteDrawOutcome` is a **closed** enum, so a non-exhaustive `switch` is a
compiler error rather than a silent path:

| Case | What happened | What to do |
| --- | --- | --- |
| `.submitted(RemoteDrawReceipt)` | The drawing was submitted. | Record the receipt. Call `session.submit(metadata:)` yourself if you need the server's own ids — a submit from the SDK's controls reports a placeholder. |
| `.left` | The person left. Anything drawn is on the board. | Nothing. |
| `.expired` | The board finished, or the session timed out. | Create a new session. Terminal. |
| `.credentialLost(RemoteDrawError?)` | The **token** stopped working while the board carried on. | Get a fresh token from `POST /v1/sessions/direct-sender` and present again — or supply `tokenProvider` and the SDK does it before you ever see this. |
| `.unsupportedSurface(RemoteDrawUnsupportedSurface)` | The board wants something this SDK has no renderer for. | Read `hostedSenderURL`. **The cover stays up** showing the reason — this is a message, not an ending. |
| `.failed(RemoteDrawError)` | Anything else. | `error.shouldReJoin` and `error.isRetriable` answer what to do next. |

`.credentialLost` was folded into `.expired` and should not have been: one is
terminal and one is recoverable, and reporting a live board as expired sent
hosts to create a second session for a board that was still running.

**There is no `.revoked`.** `/v1/join` revokes every other sender on the session,
so a second device scanning the QR does knock this one off — but the API answers
a revoked, an unknown and a malformed token with one `invalid_sender_token`, on
purpose, because the token is the whole credential. Only a genuine expiry of a
still-wanted token is distinguishable (`sender_token_expired`), and that
distinction travels in the error attached to `.credentialLost`. Reporting a
`.revoked` we cannot actually observe would be a guess with a confident name.

## Capabilities

A session grants what a sender may do. `undo`, `clear`, `submit`,
`viewExisting` and `moveViewport` are checked before a request goes out, and a
missing grant throws `RemoteDrawError.notPermitted(_:)` rather than costing a
round trip. Hide the control or add the capability where you create the session;
a client can never grant itself more than the board allows.

## Theming, and where the line is

Three tiers, and the line is drawn at **anything that changes what goes on the
wire**.

**Values.** `RemoteDrawAppearance` — accent, ink, ground, field guide, corner,
Dynamic Type ceiling, handedness — and `RemoteDrawStrings`, which is every
user-facing word the surface can say.

**Two chrome slots.** A header and a footer, and deliberately not a general
"override any subview" API: slot count is the maintenance budget, and two
survive a redesign of the middle.

**Bring your own ground.** The `background:` builder above, on both
`RemoteDrawSurface` and the modifier.

**Bring your own UI.** `RemoteDrawSenderSession` is public, along with
`RemoteDrawBoardCanvas` (the board's whole paint pass as a placeable `View`),
`RemoteDrawInkCanvas`, `RemoteDrawStrokeCapture`, `RemoteDrawMapBoardGround` and
`RemoteDrawMapGeometry`. You get correct wire behaviour and own everything else.

**Not settable, ever:** draft cadence, point budgets, the codec, token storage,
the sequence counter. Those are protocol, and they are `public let` on the
session so you can read them.

## Privacy

`PrivacyInfo.xcprivacy` ships as a resource on the SDK target and is merged into
your app's privacy report. It declares three collected data types — the drawing
(other user content), the vendor device ID, and the screen geometry the receiver
needs — all **unlinked**, because this SDK authenticates no end user and holds no
account to link them to.

Two required-reason APIs: system boot time (`35F9.1`, the monotonic clock behind
each point's `t`) and user defaults (`CA92.1`, the surface's five preferences).
Neither adds anything to the collected-data list — a person's choice of pencil
never leaves the device.

The device ID is an opt-out with a real API behind it:

```swift
RemoteDraw.configure(.init(
  apiBaseURL: .production,
  device: .anonymous(aspectRatio: 393.0 / 852.0)
))
```

which omits the key from the request body entirely, and lets you delete that
entry from your own report.

`RemoteDrawReceiverKit` and `RemoteDrawInk` ship no privacy manifest of their
own: they use no required-reason APIs and collect nothing. The receiver only
reads a session your backend created, with a scoped receiver token.

<a id="receiver-remotedrawreceiverkit"></a>

## Receiver: `RemoteDrawReceiverKit`

The surface side: a Mac (or iPad) that shows what phones draw. An HTTP receiver
transport, an observable polling store, pairing (code, link and an on-device QR
code) and a SwiftUI board that paints with the same `RemoteDrawInk` renderer the
sender uses.

```swift
import RemoteDrawReceiverKit
import SwiftUI

@MainActor
final class ReceiverModel: ObservableObject {
  let transport = RemoteDrawReceiverHTTPTransport(
    baseURL: URL(string: "https://api.remotedraw.com")!
  )
  lazy var store = RemoteDrawReceiverStore(transport: transport)
}

struct BoardScreen: View {
  @StateObject private var model = ReceiverModel()
  let sessionId: String, receiverToken: String   // from your backend

  var body: some View {
    RemoteDrawReceiverView(store: model.store, control: model.transport)
      .task { model.store.start(credentials: .init(sessionId: sessionId, receiverToken: receiverToken)) }
      .onDisappear { model.store.stop() }
  }
}
```

- **Credentials.** Your backend creates the session with the account API key and
  hands the app only the `sessionId` and the scoped `receiverToken`. Never embed
  an account key in an app.
- **Views.** `RemoteDrawReceiverBoard(store:)` is the drawing alone.
  `RemoteDrawReceiverView(store:control:)` adds pairing, connected-phone count,
  undo, clear and end session, and reports the surface size to the server after
  a resize. `RemoteDrawReceiverQRCode(url:)` renders a join URL with Core Image —
  no third-party service sees it. AppKit hosts use `NSHostingView(rootView:)`,
  UIKit hosts `UIHostingController(rootView:)`.
- **Lifecycle.** `start(credentials:)` begins polling; `stop()` disconnects
  locally; `transport.endSession(credentials)` ends the session on the server.
  Foreground/background policy is the host's.
- **Your own UI.** `RemoteDrawReceiverStore.snapshot` (session, drawings, live
  drafts, senders) is `@Published`; render it however you like, or implement
  `RemoteDrawReceiverTransport` for tests.

### What the receiver does not do yet

- **Polling only:** one second idle, 250 ms while a phone is drawing, with a
  cheap `/v1/receiver/sync` revision check first. No WebSocket or video stream;
  latency includes network round trips.
- **Normalized boards only.** The board fills the view. Map/world projection,
  image elements and aspect-preserving embedded content need a host renderer;
  hidden drawings and unsupported element types are not painted.
- **No image export** of the board.
- `RemoteDrawReceiverView`'s header still reads "RemoteDraw · In development".
  Use `RemoteDrawReceiverBoard` with your own chrome if that matters.
- The receiver API is younger than the sender's and may still change in `0.x`
  minors. Hardware acceptance on Mac and iPhone/iPad is still in progress.

## Working on it

```
bun run ios:sdk:test     # swift test — hermetic, no simulator, seconds
bun run ios:sdk:mirror   # export the public package and run its whole suite there
bun run ios:sdk:parse    # typechecks the UIKit capture layer against the iOS SDK
bun run codec:fixtures   # regenerates the golden vectors
```

`swift test` runs on macOS, so it never compiles anything inside
`#if canImport(UIKit)`. `ios:sdk:parse` is what covers the capture layer.

The packed-point golden vectors in `Tests/…/Fixtures/pointCodecVectors.json` are
**generated** by `scripts/point-codec-fixtures.ts` from the canonical TypeScript
encoder, and `bun run test:api` fails if the committed file is stale. They used
to be hand-copied between three test suites, which is how an epoch-scale
timestamp — a value that traps Swift's `Int32` conversion — reached production
with every suite green.

If a vector disagrees with this encoder, that is a divergence between two
implementations of a wire format. Fix the code, not the fixture.

`Tests/…/Fixtures/mapBoardGeometryVectors.json` is the same idea for the map
transform, and is a verbatim copy of
`packages/geometry/tests/fixtures/mapBoardGeometryVectors.json` — copied rather
than referenced because this package is exported on its own into the public
mirror, where a path out of it would not resolve. Re-copy it when the shared
table changes:

```sh
cp packages/geometry/tests/fixtures/mapBoardGeometryVectors.json \
   apps/ios/RemoteDrawSenderKit/Tests/RemoteDrawSenderKitTests/Fixtures/
```

### HTTP draft latency

Drafts keep the latest pending stroke state and allow one outstanding HTTP call.
The 32 ms interval limits send rate; it is not a delivery guarantee. A delayed
fake transport measured about 9.5 Hz at 100 ms RTT and 4.7 Hz at 200 ms RTT on the
local test machine. Reliable commits use a newer sequence and retain their
idempotency key. Canceling a draft drain cannot clear the next stroke's drain
ownership. A persistent draft transport or bounded concurrency would need
separate ordering/recovery validation; this SDK does not add HTTP concurrency.
