import Testing
import Foundation
import Synchronization
@testable import CodecCore

@Suite("SystemReading")
struct SystemReadingTests {
    private func sample(busy: UInt64 = 0, total: UInt64 = 0, used: UInt64 = 0, memory: UInt64 = 100,
                        received: UInt64 = 0, sent: UInt64 = 0, time: TimeInterval = 0) -> SystemSample {
        SystemSample(cpuBusyTicks: busy, cpuTotalTicks: total, memoryUsed: used, memoryTotal: memory,
                     networkReceived: received, networkSent: sent, time: time)
    }

    @Test func computesUsageAndRatesFromDeltas() {
        let before = sample(busy: 100, total: 1000, used: 10, received: 1_000, sent: 500, time: 10)
        let after = sample(busy: 350, total: 2000, used: 40, received: 5_000, sent: 1_500, time: 12)
        let reading = SystemReading(from: before, to: after)
        #expect(reading.cpu == 0.25)
        #expect(reading.memory == 0.4)
        #expect(reading.memoryUsed == 40)
        #expect(reading.downloadRate == 2_000)
        #expect(reading.uploadRate == 500)
    }

    @Test func treatsCounterResetsAsZero() {
        let before = sample(busy: 500, total: 2000, received: 9_000, sent: 9_000, time: 1)
        let after = sample(busy: 10, total: 100, received: 100, sent: 100, time: 2)
        let reading = SystemReading(from: before, to: after)
        #expect(reading.cpu == 0)
        #expect(reading.downloadRate == 0)
        #expect(reading.uploadRate == 0)
    }

    @Test func guardsAgainstZeroElapsedTimeAndMemory() {
        let reading = SystemReading(from: sample(memory: 0, received: 0, time: 5),
                                    to: sample(memory: 0, received: 100, time: 5))
        #expect(reading.downloadRate == 0)
        #expect(reading.memory == 0)
    }

    @Test func clampsToOne() {
        let reading = SystemReading(from: sample(busy: 0, total: 0, used: 0),
                                    to: sample(busy: 20, total: 10, used: 500, memory: 100))
        #expect(reading.cpu <= 1)
        #expect(reading.memory == 1)
    }
}

@Suite("HostSampler")
struct HostSamplerTests {
    @Test func readsPlausibleHostCounters() throws {
        let sampler = HostSampler()
        let first = try #require(sampler.sample())
        #expect(first.cpuTotalTicks > 0)
        #expect(first.cpuBusyTicks <= first.cpuTotalTicks)
        #expect(first.memoryTotal == ProcessInfo.processInfo.physicalMemory)
        #expect(first.memoryUsed > 0 && first.memoryUsed <= first.memoryTotal)
        Thread.sleep(forTimeInterval: 0.05)
        let second = try #require(sampler.sample())
        #expect(second.time > first.time)
        #expect(second.cpuTotalTicks >= first.cpuTotalTicks)
        #expect(second.networkReceived >= first.networkReceived)
        let reading = SystemReading(from: first, to: second)
        #expect((0...1).contains(reading.cpu))
        #expect((0...1).contains(reading.memory))
    }
}

/// Returns queued samples in order.
private final class ScriptedSampler: SystemSampling {
    private let samples: Mutex<[SystemSample]>
    init(_ samples: [SystemSample]) { self.samples = Mutex(samples) }
    func sample() -> SystemSample? {
        samples.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@Suite("SystemMonitor")
@MainActor
struct SystemMonitorTests {
    private func sample(busy: UInt64, total: UInt64, time: TimeInterval) -> SystemSample {
        SystemSample(cpuBusyTicks: busy, cpuTotalTicks: total, memoryUsed: 50, memoryTotal: 100,
                     networkReceived: 0, networkSent: 0, time: time)
    }

    @Test func publishesAReadingFromTwoSamples() {
        let monitor = SystemMonitor(sampler: ScriptedSampler([
            sample(busy: 0, total: 100, time: 0),
            sample(busy: 50, total: 200, time: 1),
        ]))
        monitor.update()
        #expect(monitor.reading == .zero)
        monitor.update()
        #expect(monitor.reading.cpu == 0.5)
        #expect(monitor.reading.memory == 0.5)
    }

    @Test func runsWhileAnyClientNeedsIt() {
        let monitor = SystemMonitor(sampler: ScriptedSampler([]), interval: 60)
        #expect(!monitor.isRunning)
        monitor.start()
        monitor.start()
        #expect(monitor.isRunning)
        monitor.stop()
        #expect(monitor.isRunning)
        monitor.stop()
        #expect(!monitor.isRunning)
        monitor.stop()
        #expect(!monitor.isRunning)
    }

    @Test func ignoresMissingSamples() {
        let monitor = SystemMonitor(sampler: ScriptedSampler([]))
        monitor.update()
        #expect(monitor.reading == .zero)
    }
}

@Suite("ProcessInspector")
struct ProcessInspectorTests {
    @Test func namesTheCurrentProcess() throws {
        let name = try #require(ProcessInspector.name(of: getpid()))
        #expect(!name.isEmpty)
    }

    @Test func readsTheCurrentWorkingDirectory() throws {
        let directory = try #require(ProcessInspector.workingDirectory(of: getpid()))
        #expect(URL(fileURLWithPath: directory).standardizedFileURL.path
                == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path)
    }

    @Test func handlesInvalidInput() {
        #expect(ProcessInspector.foregroundProcess(ptyFD: -1) == nil)
        #expect(ProcessInspector.name(of: -42) == nil)
        #expect(ProcessInspector.workingDirectory(of: -42) == nil)
    }
}
