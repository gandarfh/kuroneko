import Foundation

/// Whether someone is talking right now, from the loudness of what the mic
/// and the system tap are writing. A level meter, not the VAD: cheap enough
/// for every buffer, so any loud sound counts. Drives the typing cat and the
/// level bars of the menu.
public final class SpeechMeter: @unchecked Sendable {
    public enum Channel: Sendable {
        case mic, system
    }


    /// dBFS above which a buffer counts as speech.
    public static let threshold: Float = -45
    /// How long it stays speaking after the last loud buffer, so the pauses
    /// between words don't flicker it off.
    public static let hold: TimeInterval = 0.6

    /// How long a channel's last level stands for it: buffers arrive every
    /// ~100 ms, so a silent channel stops being drawn soon after.
    public static let freshness: TimeInterval = 0.3

    private let lock = NSLock()
    private var lastLoud: Date?
    private var levels: [Channel: (level: Float, at: Date)] = [:]

    public init() {}

    public func hear(level: Float, from channel: Channel = .system, at date: Date = Date()) {
        lock.withLock {
            levels[channel] = (level, date)
            if level >= Self.threshold { lastLoud = date }
        }
    }

    public func isSpeaking(at date: Date = Date()) -> Bool {
        lock.withLock {
            guard let lastLoud else { return false }
            return date.timeIntervalSince(lastLoud) <= Self.hold
        }
    }

    /// The last level heard on the channel, in dBFS; -infinity when it went
    /// quiet (or never spoke).
    public func level(of channel: Channel, at date: Date = Date()) -> Float {
        lock.withLock {
            guard let last = levels[channel], date.timeIntervalSince(last.at) <= Self.freshness else { return -.infinity }
            return last.level
        }
    }

    public func reset() {
        lock.withLock {
            lastLoud = nil
            levels = [:]
        }
    }

    /// 0…1 for a bar: -60 dBFS (room noise) is empty, -10 dBFS (loud speech)
    /// is full.
    public static func loudness(_ level: Float) -> Double {
        guard level.isFinite else { return 0 }
        return Double(min(max((level + 60) / 50, 0), 1))
    }

    /// RMS level in dBFS; -infinity for silence.
    public static func level(of samples: UnsafeBufferPointer<Int16>) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        var sum: Float = 0
        for s in samples {
            let x = Float(s) / Float(Int16.max)
            sum += x * x
        }
        return 10 * log10(sum / Float(samples.count))
    }
}

/// The last few loudness readings of a channel, oldest first: the bars of the
/// menu, which move from right to left as new readings arrive.
public struct LevelTrail: Equatable, Sendable {
    public private(set) var values: [Double]

    public init(count: Int) {
        values = Array(repeating: 0, count: count)
    }

    public mutating func push(_ value: Double) {
        guard !values.isEmpty else { return }
        values.removeFirst()
        values.append(min(max(value, 0), 1))
    }
}
