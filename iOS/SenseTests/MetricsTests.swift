import XCTest
@testable import Sense

final class MetricsTests: XCTestCase {
    func testRatesUseElapsedTimeAndFirstReadingHasNoTraffic() {
        var sampler = RateSampler()
        let time = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(sampler.sample(TrafficReading(received: 1_000, sent: 100, date: time)), TrafficRate())
        let rate = sampler.sample(TrafficReading(received: 5_000, sent: 1_100, date: time.addingTimeInterval(2)))
        XCTAssertEqual(rate.download, 2_000)
        XCTAssertEqual(rate.upload, 500)
    }

    func testCounterResetAndPauseDoNotProduceFalseSpikes() {
        var sampler = RateSampler()
        let time = Date()
        _ = sampler.sample(TrafficReading(received: 9_999, sent: 5_000, date: time))
        XCTAssertEqual(sampler.sample(TrafficReading(received: 5, sent: 1, date: time.addingTimeInterval(1))), TrafficRate())
        sampler.reset()
        XCTAssertEqual(sampler.sample(TrafficReading(received: 50_000, sent: 10_000, date: time.addingTimeInterval(10))), TrafficRate())
    }

    func testMissingAndInvalidStorageCannotShowMadeUpUsage() {
        XCTAssertNil(MetricFormat.usedFraction(total: nil, free: 100))
        XCTAssertNil(MetricFormat.usedFraction(total: 0, free: 100))
        XCTAssertEqual(MetricFormat.usedFraction(total: 1_000, free: 250), 0.75)
        XCTAssertEqual(MetricFormat.usedFraction(total: 100, free: 150), 0)
        XCTAssertEqual(MetricFormat.bytes(nil), "—")
    }

    func testHistoryIsTimeLimitedAndBounded() {
        let now = Date()
        let samples = (0..<2_000).map { HistorySample(date: now.addingTimeInterval(Double($0 - 1_999)), download: 0, upload: 0) }
        XCTAssertEqual(MetricFormat.trimHistory(samples, now: now, seconds: 120).count, 121)
        XCTAssertEqual(MetricFormat.trimHistory(samples, now: now, seconds: 3_000).count, 900)
    }
}
