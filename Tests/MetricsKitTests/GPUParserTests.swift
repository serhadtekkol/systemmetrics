import Testing
import Foundation
@testable import MetricsKit

struct GPUParserTests {
    @Test func parsesAppleSiliconKeys() throws {
        let d: [String: Any] = ["Device Utilization %": NSNumber(value: 37), "In use system memory": NSNumber(value: 324_616_192),
                                "Renderer Utilization %": NSNumber(value: 3)]
        let s = try #require(GPUStatsParser.parse(d))
        #expect(s.utilization == 0.37)
        #expect(s.memoryInUse == 324_616_192)
    }
    @Test func missingUtilizationIsNil() {
        #expect(GPUStatsParser.parse(["In use system memory": NSNumber(value: 1)]) == nil)
    }
    @Test func missingMemoryKeyDefaultsToZero() {
        #expect(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: 5)])?.memoryInUse == 0)
    }
    @Test func wrongValueTypeIsNil() {
        #expect(GPUStatsParser.parse(["Device Utilization %": "37"]) == nil)
    }
    @Test func clampsOutOfRange() {
        #expect(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: 140)])?.utilization == 1)
        #expect(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: -3)])?.utilization == 0)
    }
    @Test func samplerReturnsNilWhenSourceFails() {
        #expect(GPUSampler(read: { nil }).sample() == nil)
    }
}
