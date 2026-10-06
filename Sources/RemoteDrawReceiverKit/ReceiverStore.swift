import Foundation
import Combine

/// Polling cadence, ported from `createReceiverStore` in `@remotedraw/client`.
public enum RemoteDrawReceiverCadence: Sendable {
  public static let idleMs: Double = 1000
  /// Dropped to whenever a draft is live, so ink under the finger keeps up.
  public static let draftingMs: Double = 250

  /// The interval to use for the next poll.
  public static func intervalMs(hasDrafts: Bool, idle: Double = idleMs, drafting: Double = draftingMs)
    -> Double
  {
    guard hasDrafts else { return idle }
    return min(idle, drafting)
  }
}

public enum RemoteDrawReceiverStatus: Equatable, Sendable {
  case idle
  case polling
  case stopped(RemoteDrawReceiverError)
}

/// The receiver state machine: fetch, admit, publish, re-arm.
///
/// A faithful port of `packages/client/src/receiverStore.ts`, which has already
/// solved the parts of this that are easy to get subtly wrong. Two of them are
/// worth restating because they look arbitrary in isolation:
///
/// 1. **Drafts are fetched before drawings, sequentially.** The server deletes a
///    draft in the transaction that commits its stroke; a polling receiver sees
///    the two through separate requests. Reading drafts first means a commit
///    landing mid-poll can only ever produce a draft that is *also* already
///    committed — which the admission filter drops — instead of a stroke that
///    is in neither list and visibly blinks out for a cycle.
///    A sync revision can predate that commit, so a disappeared displayed draft
///    also forces the drawings read even when that revision was unchanged.
/// 2. **Staleness is re-evaluated on a timer, not only on fetch.** A poll that
///    returns an unchanged stale draft must still expire it, otherwise a sender
///    that vanishes mid-stroke leaves a ghost on screen forever.
///
/// This implementation serialises polls with an `await` loop rather than the
/// TypeScript version's interval-plus-queue. The effect is the same guarantee —
/// one batch in flight, never overlapping — with the difference that the
/// interval here is measured between the *end* of one poll and the start of the
/// next, so a slow network stretches the cadence instead of stacking requests.
@MainActor
public final class RemoteDrawReceiverStore: ObservableObject {
  @Published public private(set) var snapshot = RemoteDrawReceiverSnapshot()
  @Published public private(set) var status: RemoteDrawReceiverStatus = .idle
  @Published public private(set) var lastError: RemoteDrawReceiverError?
  /// Set once the session is no longer worth polling: ended, expired, or the
  /// token was revoked.
  @Published public private(set) var isTerminated = false

  public var credentials: RemoteDrawReceiverCredentials? { activeCredentials }

  /// True while any admitted draft is on screen. Drives the fast cadence and,
  /// in the desktop app, the edge glow's emphasis.
  public var isDrawing: Bool { !snapshot.drafts.isEmpty }

  private let transport: RemoteDrawReceiverTransport
  private let now: @Sendable () -> Date
  private let idleIntervalMs: Double
  private let draftIntervalMs: Double
  private var syncRevisions: RemoteDrawSyncRevisions?
  private var syncCredentials: RemoteDrawReceiverCredentials?
  private var activeCredentials: RemoteDrawReceiverCredentials?
  private var pollTask: Task<Void, Never>?
  private var generation: UInt = 0
  private var fetchingGeneration: UInt?
  private var expiryTask: Task<Void, Never>?

  public init(
    transport: RemoteDrawReceiverTransport,
    idleIntervalMs: Double = RemoteDrawReceiverCadence.idleMs,
    draftIntervalMs: Double = RemoteDrawReceiverCadence.draftingMs,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.idleIntervalMs = idleIntervalMs.isFinite ? max(50, idleIntervalMs) : 1000
    self.draftIntervalMs = draftIntervalMs.isFinite ? max(50, draftIntervalMs) : 250
    self.now = now
  }

  deinit {
    pollTask?.cancel()
    expiryTask?.cancel()
  }

  // MARK: Lifecycle

  public func start(credentials: RemoteDrawReceiverCredentials) {
    stop()
    activeCredentials = credentials
    isTerminated = false
    lastError = nil
    status = .polling
    pollTask = Task { [weak self] in await self?.pollLoop() }
    expiryTask = Task { [weak self] in await self?.expiryLoop() }
  }

  public func stop() {
    generation &+= 1
    pollTask?.cancel()
    pollTask = nil
    expiryTask?.cancel()
    expiryTask = nil
    syncRevisions = nil
    syncCredentials = nil
    activeCredentials = nil
    status = .idle
    snapshot = RemoteDrawReceiverSnapshot()
  }

  // MARK: Commands

  public func undo() async {
    guard let credentials = activeCredentials else { return }
    let commandGeneration = generation
    do { try await transport.undo(credentials) } catch {
      if generation == commandGeneration { record(error) }
      return
    }
    guard generation == commandGeneration else { return }
    // Undo manifests as a row disappearing from `listDrawings`; there is no
    // event to handle, so the only correct response is to refetch.
    await refetch()
  }

  public func clear() async {
    guard let credentials = activeCredentials else { return }
    let commandGeneration = generation
    do { try await transport.clear(credentials) } catch {
      if generation == commandGeneration { record(error) }
      return
    }
    guard generation == commandGeneration else { return }
    await refetch()
  }

  // MARK: Polling

  private func pollLoop() async {
    while !Task.isCancelled {
      await refetch()
      if isTerminated { return }
      let interval = RemoteDrawReceiverCadence.intervalMs(
        hasDrafts: isDrawing,
        idle: idleIntervalMs,
        drafting: draftIntervalMs
      )
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000))
    }
  }

  /// Re-evaluates draft staleness at 1 Hz while any draft is on screen.
  private func expiryLoop() async {
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled, !snapshot.drafts.isEmpty else { continue }
      let admitted = RemoteDrawDraftAdmission.renderable(
        drafts: snapshot.drafts,
        drawings: snapshot.drawings,
        now: now().remoteDrawEpochMs
      )
      if admitted.count != snapshot.drafts.count {
        snapshot.drafts = admitted
      }
    }
  }

  /// One full poll. Public so a caller can force a refresh — and so tests can
  /// drive the store deterministically without waiting on real timers.
  @discardableResult
  public func refetch() async -> RemoteDrawReceiverSnapshot {
    guard let credentials = activeCredentials, !isTerminated else { return snapshot }
    let currentGeneration = generation
    guard fetchingGeneration != currentGeneration else { return snapshot }
    fetchingGeneration = currentGeneration
    defer { if fetchingGeneration == currentGeneration { fetchingGeneration = nil } }
    let baseline = snapshot

    do {
      let revision = try await transport.fetchRevisions(credentials)
      let previous = syncCredentials == credentials ? syncRevisions : nil
      let metadataChanged = revision == nil || previous?.metadata != revision?.metadata
      let drawingsChanged = revision == nil || previous?.drawings != revision?.drawings
      let draftsChanged = revision == nil || previous?.drafts != revision?.drafts || drawingsChanged
      let session: RemoteDrawReceiverSession
      if metadataChanged || baseline.session == nil { session = try await transport.fetchSession(credentials) }
      else { session = baseline.session! }
      let senders = metadataChanged ? try await transport.fetchSenders(credentials) : baseline.senders
      let drafts = draftsChanged ? try await transport.fetchDrafts(credentials) : baseline.drafts
      var refreshDrawings = drawingsChanged
      if draftsChanged && !drawingsChanged && !baseline.drafts.isEmpty {
        let currentDraftIDs = Set(drafts.map(\.id))
        refreshDrawings = baseline.drafts.contains { !currentDraftIDs.contains($0.id) }
      }
      let drawings = refreshDrawings ? try await transport.fetchDrawings(credentials) : baseline.drawings

      guard generation == currentGeneration, !Task.isCancelled else { return snapshot }
      syncRevisions = revision
      syncCredentials = credentials
      snapshot = RemoteDrawReceiverSnapshot(
        session: session,
        drawings: drawings,
        drafts: RemoteDrawDraftAdmission.renderable(
          drafts: drafts,
          drawings: drawings,
          now: now().remoteDrawEpochMs
        ),
        senders: senders
      )
      lastError = nil
      status = .polling

      if !session.isActive {
        terminate(with: .notFound)
      }
    } catch {
      guard generation == currentGeneration, !Task.isCancelled else { return snapshot }
      record(error)
    }

    return snapshot
  }

  private func record(_ error: Error) {
    let failure = (error as? RemoteDrawReceiverError) ?? .transport(error.localizedDescription)
    lastError = failure
    if failure.isTerminal { terminate(with: failure) }
  }

  private func terminate(with error: RemoteDrawReceiverError) {
    isTerminated = true
    snapshot.drafts = []
    status = .stopped(error)
    pollTask?.cancel()
    pollTask = nil
    expiryTask?.cancel()
    expiryTask = nil
  }
}
