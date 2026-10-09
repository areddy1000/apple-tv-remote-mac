import Testing
@testable import AppleTVKit

@Test func latencyProbeEnds() {
    let probe = LatencyProbe("test")
    probe.end()
}
