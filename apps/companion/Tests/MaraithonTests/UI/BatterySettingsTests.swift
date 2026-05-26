import XCTest
@testable import Maraithon

/// Tests the "Pause syncing when on battery" preference and its
/// interaction with Low Power Mode. The probe is injected so we don't
/// have to actually flip the OS into Low Power Mode.
@MainActor
final class BatterySettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "battery-settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeRegistry() -> (SourceRegistry, FakeSource) {
        let log = EventLog()
        let registry = SourceRegistry(eventLog: log)
        let source = FakeSource(id: "a", displayName: "A", symbol: "a.circle")
        registry.register(source)
        return (registry, source)
    }

    func testTogglePersistsInDefaults() {
        let settings = BatterySettings(defaults: defaults, lowPowerModeProbe: { false })
        XCTAssertFalse(settings.pauseOnBattery)

        settings.pauseOnBattery = true
        XCTAssertTrue(defaults.bool(forKey: BatterySettings.pauseOnBatteryDefaultsKey))

        settings.pauseOnBattery = false
        XCTAssertFalse(defaults.bool(forKey: BatterySettings.pauseOnBatteryDefaultsKey))
    }

    func testPausesAllWhenToggleOnAndLowPower() {
        var lowPower = false
        let settings = BatterySettings(
            defaults: defaults,
            lowPowerModeProbe: { lowPower }
        )
        let (registry, source) = makeRegistry()
        settings.bind(sources: registry, eventLog: EventLog())

        // Toggle on but Mac not in Low Power yet — should not pause.
        settings.pauseOnBattery = true
        XCTAssertEqual(source.pauseCount, 0)

        // Mac flips into Low Power Mode.
        lowPower = true
        settings.applyCurrentState()
        XCTAssertEqual(source.pauseCount, 1)

        // Plugged back in — should resume.
        lowPower = false
        settings.applyCurrentState()
        XCTAssertEqual(source.startCount, 1)
    }

    func testToggleOffWhileInLowPowerResumesImmediately() {
        let settings = BatterySettings(
            defaults: defaults,
            lowPowerModeProbe: { true }
        )
        let (registry, source) = makeRegistry()
        settings.bind(sources: registry, eventLog: EventLog())

        settings.pauseOnBattery = true
        XCTAssertEqual(source.pauseCount, 1)

        settings.pauseOnBattery = false
        XCTAssertEqual(source.startCount, 1)
    }

    func testBindIsIdempotent() {
        let settings = BatterySettings(defaults: defaults, lowPowerModeProbe: { false })
        let (registry, source) = makeRegistry()
        let log = EventLog()
        settings.bind(sources: registry, eventLog: log)
        settings.bind(sources: registry, eventLog: log)
        // Two binds shouldn't double-pause when LowPowerMode flips.
        settings.pauseOnBattery = true
        settings._setLowPowerModeProbe({ true })
        settings.applyCurrentState()
        XCTAssertEqual(source.pauseCount, 1)
        settings.teardown()
    }

    func testToggleOnWithoutLowPowerIsNoop() {
        let settings = BatterySettings(
            defaults: defaults,
            lowPowerModeProbe: { false }
        )
        let (registry, source) = makeRegistry()
        settings.bind(sources: registry, eventLog: EventLog())

        settings.pauseOnBattery = true
        XCTAssertEqual(source.pauseCount, 0)
        XCTAssertEqual(source.startCount, 0)
    }
}
