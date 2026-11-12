import Foundation

/// Last actual device inputs, never host commands. Restored entries are history, not
/// current observations. Route and TX channel must match before a host presents them.
/// This is a fallback; full startup readback capability remains unverified.
public struct HardwareValueCache: Codable, Equatable, Sendable {
    public struct Reading: Codable, Equatable, Sendable {
        public let value: UInt8
        public let timestamp: Date
    }

    public let inputID: Int32
    public let transmitChannel: UInt8
    public private(set) var lastInputLayer: CompactLayer?
    public private(set) var faders: [Int: Reading] = [:]
    public private(set) var encoders: [CompactLayer: [Int: Reading]] = [:]

    public init(inputID: Int32, transmitChannel: UInt8) {
        self.inputID = inputID
        self.transmitChannel = transmitChannel
    }

    public mutating func record(_ input: CompactInput, at date: Date) {
        guard input.value < 128, date.timeIntervalSince1970.isFinite else { return }
        lastInputLayer = input.layer
        let reading = Reading(value: input.value, timestamp: date)
        switch input.control {
        case let .fader(index) where (1 ... 9).contains(index): faders[index] = reading
        case let .encoder(index) where (1 ... 16).contains(index): encoders[input.layer, default: [:]][index] = reading
        default: break // Never restore touches, held buttons, presses or LED commands.
        }
    }

    public mutating func invalidateFader(_ index: Int) {
        faders.removeValue(forKey: index)
    }

    public func validate() throws {
        guard transmitChannel < 16,
              faders.allSatisfy({ (1 ... 9).contains($0.key) && $0.value.value < 128 && $0.value.timestamp.timeIntervalSince1970.isFinite }),
              encoders.values.allSatisfy({ $0.allSatisfy { (1 ... 16).contains($0.key) && $0.value.value < 128 && $0.value.timestamp.timeIntervalSince1970.isFinite } })
        else { throw HardwareValueCacheError.invalidData }
    }
}

public enum HardwareValueCacheError: Error { case invalidData }
