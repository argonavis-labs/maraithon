import Foundation

/// Controls whether `EventLog` writes entries to disk in addition to keeping
/// its in-memory ring buffer. The default keeps app launches persistent while
/// avoiding writes from XCTest processes.
enum EventLogPersistence: Equatable {
    case automatic
    case disabled
    case file(URL)
}
