# RemoteDrawSenderKit

The RemoteDraw sender, as a Swift package. Capture a stroke, put it on a board.

Two ways in, and you can stop at either.

**The whole board, in one modifier.** The drawing surface the first-party
RemoteDraw app shows — paper and its tooth, sixteen instruments, the one-handed
control cluster, the long-press tool fan, shape snapping — presented full screen
with a way out:

```swift
Button("Draw") { drawing = true }
  .remoteDrawSurface(isPresented: $drawing, senderToken: token) { outcome in
    switch outcome {
    case .submitted(let receipt): record(receipt)
    case .left:                   dismissBanner()
    case .expired:                refreshSession()
    case .failed(let error):      report(error)
    }
  }
```

`RemoteDrawSurface` is the same board as a plain `View`, for a host that wants
it inside its own layout rather than over it; `RemoteDrawTakeover` is that view
plus the cover, the scene-phase wiring and the exit.

**Or the headless core** — the wire, not the UI: a session, a capture layer that
keeps pressure and tilt, a renderer that draws RemoteDraw's ink, and nothing
that decides what your screen looks like.

```swift
import RemoteDrawSenderKit
import SwiftUI

@main
struct MyApp: App {
  init() { RemoteDraw.configure(.init(apiBaseURL: .production)) }
  var body: some Scene { WindowGroup { BoardView() } }
}

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
| **Ink** | Tapered dynamic ribbons driven by pressure, tilt and velocity. `RemoteDrawInk/InkRenderer.swift` is byte-identical to the first-party app's, so a mark made through this SDK is the same mark. |

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

## Capabilities

A session grants what a sender may do. `undo`, `clear`, `submit`,
`viewExisting` and `moveViewport` are checked before a request goes out, and a
missing grant throws `RemoteDrawError.notPermitted(_:)` rather than costing a
round trip. Hide the control or add the capability where you create the session;
a client can never grant itself more than the board allows.

## Theming, and where the line is

Three tiers, and the line is drawn at **anything that changes what goes on the
wire**.

**Values.** `RemoteDrawAppearance` — accent, ink, ground, corner, Dynamic Type
ceiling, handedness — and `RemoteDrawStrings`, which is every user-facing word
the surface can say.

**Two chrome slots.** A header and a footer, and deliberately not a general
"override any subview" API: slot count is the maintenance budget, and two
survive a redesign of the middle.

**Bring your own UI.** `RemoteDrawSenderSession` is public, along with
`RemoteDrawBoardCanvas` (the board's whole paint pass as a placeable `View`),
`RemoteDrawInkCanvas`, and `RemoteDrawStrokeCapture`. You get correct wire
behaviour and own everything else.

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

## Working on it

```
bun run ios:sdk:test     # swift test — hermetic, no simulator, seconds
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
