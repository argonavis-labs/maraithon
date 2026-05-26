import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Pushes synced records into the system Spotlight index so the user can
/// find them via the macOS Spotlight UI alongside the rest of their Mac
/// results. Tapping a result fires an `NSUserActivity` of type
/// `CSSearchableItemActionType`; `MaraithonApp` parses the activity
/// identifier and routes to the matching source detail view (see
/// `parseActivityIdentifier(_:)`).
///
/// Domain identifier scheme: `com.maraithon.companion.<source>` — one
/// per first-party source. `unique_id` on a `CSSearchableItem` is
/// `"<source>:<guid>"` so a roundtrip through Spotlight preserves both
/// the source and the record's stable id.
///
/// The indexer is intentionally a thin facade over `CSSearchableIndex`
/// with an injectable backing index for tests. All public APIs are
/// `Sendable` and `async`, mirroring `CSSearchableIndex`'s own surface.
///
/// Indexing limits to be aware of (Apple does not publish hard numbers
/// but documents these in `CSSearchableIndex` headers + WWDC sessions):
///
///   * Items are stored on disk per-app and flushed in batches; very
///     large bursts may take a few seconds to appear in Spotlight.
///   * Each `contentDescription` is truncated by the indexer for
///     display; we cap our snippet at 400 chars before handing it over
///     so we stay well under that limit and don't ship redacted body
///     content the user already chose to keep local.
///   * The indexer rate-limits aggressive callers — a fully-spun-up
///     companion seldom pushes more than a handful of items per cycle
///     so we stay below any rate cap, but the API is `async` and may
///     suspend internally on contention.
///
/// `Sendable` and `nonisolated` throughout. The store / source layer is
/// the only thing that calls into the indexer, and it does so from
/// background tasks after a successful upload.
public struct SpotlightIndexer: Sendable {
    /// Function type for adding a batch of items to the underlying
    /// index. Injected so tests can capture round-trips without
    /// requiring an entitled Spotlight environment.
    public typealias IndexFn = @Sendable ([CSSearchableItem]) async throws -> Void
    /// Function type for deleting an entire domain (e.g. all of
    /// `com.maraithon.companion.notes`).
    public typealias DeleteDomainFn = @Sendable ([String]) async throws -> Void
    /// Function type for nuking every Maraithon-owned identifier.
    public typealias ClearFn = @Sendable () async throws -> Void

    private let indexer: IndexFn
    private let deleter: DeleteDomainFn
    private let clearer: ClearFn

    public init(
        indexer: @escaping IndexFn,
        deleter: @escaping DeleteDomainFn,
        clearer: @escaping ClearFn
    ) {
        self.indexer = indexer
        self.deleter = deleter
        self.clearer = clearer
    }

    /// Production initializer: binds to `CSSearchableIndex.default()`.
    /// `CSSearchableIndex` is process-wide, so this is safe to call
    /// from multiple call sites; each batch is independent.
    public static func systemDefault() -> SpotlightIndexer {
        SpotlightIndexer(
            indexer: { items in
                try await CSSearchableIndex.default()
                    .indexSearchableItems(items)
            },
            deleter: { domains in
                try await CSSearchableIndex.default()
                    .deleteSearchableItems(withDomainIdentifiers: domains)
            },
            clearer: {
                try await CSSearchableIndex.default()
                    .deleteAllSearchableItems()
            }
        )
    }

    /// No-op indexer for tests / launch contexts where we explicitly
    /// don't want Spotlight to be touched.
    public static let disabled = SpotlightIndexer(
        indexer: { _ in },
        deleter: { _ in },
        clearer: { }
    )

    /// Push a batch of `CSSearchableItem`s into the Spotlight index.
    /// Empty batches short-circuit so callers can hand the result of
    /// an upstream filter through without an extra guard.
    public func index(items: [CSSearchableItem]) async throws {
        guard !items.isEmpty else { return }
        try await indexer(items)
    }

    /// Delete every item under a given source-specific domain. Used by
    /// the `clearLocalState` codepath so the cloud-side delete is
    /// mirrored in Spotlight too.
    public func delete(domainIdentifier: String) async throws {
        try await deleter([domainIdentifier])
    }

    /// Nuke the entire Maraithon index. Hooked off the sign-out /
    /// reset paths.
    public func clearAll() async throws {
        try await clearer()
    }
}

/// Source-key prefix used in `domain_identifier` and the
/// `unique_identifier` parsing helper. Kept as a single source of
/// truth so the parser and the builders stay in lock-step.
public enum SpotlightDomain {
    /// All first-party identifiers live under this prefix.
    public static let prefix: String = "com.maraithon.companion"

    /// Returns `com.maraithon.companion.<source>`.
    public static func identifier(forSource source: String) -> String {
        "\(prefix).\(source)"
    }

    /// Returns `"<source>:<guid>"` — the per-item unique identifier
    /// shape carried in both `CSSearchableItem.uniqueIdentifier` and
    /// the `userInfo[CSSearchableItemActivityIdentifier]` payload
    /// sent back by `NSUserActivity` when the user taps a result.
    public static func uniqueIdentifier(source: String, guid: String) -> String {
        "\(source):\(guid)"
    }
}

/// Parsed Spotlight activity payload. Carries the source + guid the
/// user tapped on plus the constructed deep-link URL so callers don't
/// have to repeat the same `URL(string:)` boilerplate.
public struct SpotlightActivityRoute: Equatable, Sendable {
    public let source: String
    public let guid: String
    public let url: URL

    public init(source: String, guid: String, url: URL) {
        self.source = source
        self.guid = guid
        self.url = url
    }
}

/// Parse `"<source>:<guid>"` back out of a Spotlight activity
/// identifier and construct a `maraithon://open/<source>/<guid>` URL
/// for downstream routing. Returns `nil` if the identifier is not
/// well-formed or has an empty source / guid, which keeps the caller
/// path branch-free for the common "unknown activity" case.
public func parseSpotlightActivityIdentifier(_ identifier: String) -> SpotlightActivityRoute? {
    // We split on the FIRST colon only — note guids never contain a
    // colon today, but a defensive split keeps the parser robust if
    // a future source ever emits one.
    guard let colon = identifier.firstIndex(of: ":") else { return nil }
    let source = String(identifier[..<colon])
    let guid = String(identifier[identifier.index(after: colon)...])
    guard !source.isEmpty, !guid.isEmpty else { return nil }
    // Percent-encode the guid so values containing `/`, `?`, or `#`
    // survive a roundtrip through `URL`. Source identifiers are
    // hand-picked ASCII strings (`notes`, `voice_memos`, …) and don't
    // need escaping.
    let allowed = CharacterSet.urlPathAllowed
    let encoded = guid.addingPercentEncoding(withAllowedCharacters: allowed) ?? guid
    guard let url = URL(string: "maraithon://open/\(source)/\(encoded)") else {
        return nil
    }
    return SpotlightActivityRoute(source: source, guid: guid, url: url)
}
