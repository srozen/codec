import Foundation
import Combine
import Darwin

/// Raw counters from the host at one instant. Rates come from the difference between two samples.
public struct SystemSample: Sendable, Equatable {
    /// Cumulative CPU ticks across all cores.
    public var cpuBusyTicks: UInt64
    public var cpuTotalTicks: UInt64
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    /// Cumulative bytes over all non-loopback interfaces.
    public var networkReceived: UInt64
    public var networkSent: UInt64
    public var time: TimeInterval

    public init(cpuBusyTicks: UInt64, cpuTotalTicks: UInt64, memoryUsed: UInt64, memoryTotal: UInt64,
                networkReceived: UInt64, networkSent: UInt64, time: TimeInterval) {
        self.cpuBusyTicks = cpuBusyTicks
        self.cpuTotalTicks = cpuTotalTicks
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.networkReceived = networkReceived
        self.networkSent = networkSent
        self.time = time
    }
}

/// What the status bar shows.
public struct SystemReading: Sendable, Equatable {
    /// 0...1
    public var cpu: Double
    /// 0...1
    public var memory: Double
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var downloadRate: Double
    public var uploadRate: Double

    public init(cpu: Double, memory: Double, memoryUsed: UInt64, memoryTotal: UInt64,
                downloadRate: Double, uploadRate: Double) {
        self.cpu = cpu
        self.memory = memory
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
    }

    public static let zero = SystemReading(cpu: 0, memory: 0, memoryUsed: 0, memoryTotal: 0, downloadRate: 0, uploadRate: 0)

    /// The reading between two samples. Counters that went backwards (a reset) count as zero.
    public init(from previous: SystemSample, to current: SystemSample) {
        let ticks = current.cpuTotalTicks &- previous.cpuTotalTicks
        let busy = current.cpuBusyTicks &- previous.cpuBusyTicks
        let cpu = current.cpuTotalTicks > previous.cpuTotalTicks && current.cpuBusyTicks >= previous.cpuBusyTicks
            ? min(1, Double(busy) / Double(ticks)) : 0
        let elapsed = current.time - previous.time
        func rate(_ now: UInt64, _ before: UInt64) -> Double {
            guard elapsed > 0, now >= before else { return 0 }
            return Double(now - before) / elapsed
        }
        self.init(
            cpu: cpu,
            memory: current.memoryTotal > 0 ? min(1, Double(current.memoryUsed) / Double(current.memoryTotal)) : 0,
            memoryUsed: current.memoryUsed,
            memoryTotal: current.memoryTotal,
            downloadRate: rate(current.networkReceived, previous.networkReceived),
            uploadRate: rate(current.networkSent, previous.networkSent))
    }
}

public protocol SystemSampling: Sendable {
    func sample() -> SystemSample?
}

/// Samples the Mach host statistics and the network interface counters.
public struct HostSampler: SystemSampling {
    public init() {}

    public func sample() -> SystemSample? {
        guard let cpu = cpuTicks(), let memory = memoryUsage() else { return nil }
        let network = networkBytes()
        return SystemSample(cpuBusyTicks: cpu.busy, cpuTotalTicks: cpu.total,
                            memoryUsed: memory.used, memoryTotal: memory.total,
                            networkReceived: network.received, networkSent: network.sent,
                            time: ProcessInfo.processInfo.systemUptime)
    }

    private func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// "Memory Used" as Activity Monitor counts it: app memory + wired + compressed.
    private func memoryUsage() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    /// 64-bit interface counters via `NET_RT_IFLIST2`; `getifaddrs` only has 32-bit ones that wrap.
    private func networkBytes() -> (received: UInt64, sent: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var received: UInt64 = 0, sent: UInt64 = 0
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self) }
            guard header.ifm_msglen > 0 else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let info = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                if info.ifm_flags & IFF_LOOPBACK == 0 {
                    received &+= info.ifm_data.ifi_ibytes
                    sent &+= info.ifm_data.ifi_obytes
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return (received, sent)
    }
}

/// Publishes a `SystemReading` at a fixed interval while running.
@MainActor
public final class SystemMonitor: ObservableObject {
    @Published public private(set) var reading = SystemReading.zero

    private let sampler: any SystemSampling
    private let interval: TimeInterval
    private var previous: SystemSample?
    private var timer: Timer?
    private var clients = 0

    public init(sampler: any SystemSampling = HostSampler(), interval: TimeInterval = 2) {
        self.sampler = sampler
        self.interval = interval
    }

    /// Starts sampling for one more client. Balance with `stop()`; sampling ends when no one needs it.
    public func start() {
        clients += 1
        guard timer == nil else { return }
        update()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        timer?.invalidate()
        timer = nil
        previous = nil
    }

    public var isRunning: Bool { timer != nil }

    /// Takes a sample now. Exposed for tests; the timer calls it otherwise.
    public func update() {
        guard let sample = sampler.sample() else { return }
        if let previous {
            let next = SystemReading(from: previous, to: sample)
            if next != reading { reading = next }
        }
        previous = sample
    }
}
