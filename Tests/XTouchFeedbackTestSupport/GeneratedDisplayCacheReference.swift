#if DEBUG
    import SurfaceFeedbackPlanning
    import XTouchCompactCore

    /// The migration comparison uses the old dictionary rule. Kit strategies
    /// are available separately to the deliberate wrong-policy test.
    struct GeneratedDisplayCacheReference: Sendable {
        enum Strategy: Sendable {
            case nativeDictionary
            case kit(RepeatedRequestPolicy)
        }

        private struct Cache<Value: Equatable & Sendable>: Sendable {
            private enum Storage: Sendable {
                case nativeDictionary([Int: Value])
                case kit(FeedbackRequestState<Int, Value>)
            }

            private var storage: Storage
            var order: [Int] = []
            var scopes: [Int: CompactResourceScope] = [:]

            init(strategy: Strategy) {
                storage = switch strategy {
                case .nativeDictionary: .nativeDictionary([:])
                case let .kit(policy): .kit(.init(repeatedRequestPolicy: policy, withdrawnIntentPolicy: .discard))
                }
            }

            mutating func propose(_ value: Value, index: Int, scope: CompactResourceScope) -> Value? {
                switch storage {
                case var .nativeDictionary(values):
                    if scopes[index] != nil, values[index] == value {
                        return nil
                    }
                    values[index] = value
                    storage = .nativeDictionary(values)
                case var .kit(requests):
                    guard requests.request(value, for: index) != nil else { return nil }
                    storage = .kit(requests)
                }
                if scopes.updateValue(scope, forKey: index) == nil {
                    order.append(index)
                }
                return value
            }

            mutating func invalidate(_ index: Int?) {
                let removed: [Int]
                if let index {
                    removed = scopes.removeValue(forKey: index) == nil ? [] : [index]
                    order.removeAll { $0 == index }
                } else {
                    removed = order
                    scopes.removeAll()
                    order.removeAll()
                }
                switch storage {
                case var .nativeDictionary(values):
                    for key in removed {
                        values.removeValue(forKey: key)
                    }
                    storage = .nativeDictionary(values)
                case var .kit(requests):
                    requests.invalidate(removed)
                    storage = .kit(requests)
                }
            }

            func snapshot(_ wrap: (Value) -> CompactGeneratedDisplayValue) -> CompactGeneratedDisplaySnapshot {
                let values = switch storage {
                case let .nativeDictionary(values): values
                case let .kit(requests): requests.proposed
                }
                return .init(orderedIndices: order, values: values.mapValues(wrap), scopes: scopes)
            }
        }

        private var buttons: Cache<ButtonLight>
        private var rings: Cache<RingDisplay>
        private var styles: Cache<RingStyle>

        init(strategy: Strategy = .nativeDictionary) {
            buttons = .init(strategy: strategy)
            rings = .init(strategy: strategy)
            styles = .init(strategy: strategy)
        }

        mutating func apply(_ input: CompactGeneratedDisplayInput) throws -> (MIDIMessage?, CompactGeneratedDisplaySnapshot) {
            switch input {
            case let .request(index, .button(value), scope, map, protocolValue):
                let proposal = buttons.propose(value, index: index, scope: scope)
                return try (proposal.map { try map.buttonLight(button: index, light: $0, style: protocolValue) }, buttons.snapshot(CompactGeneratedDisplayValue.button))
            case let .request(index, .ring(value), scope, map, _):
                let proposal = rings.propose(value, index: index, scope: scope)
                return try (proposal.map { try map.encoderRingValue(encoder: index, display: $0) }, rings.snapshot(CompactGeneratedDisplayValue.ring))
            case let .request(index, .style(value), scope, map, _):
                let proposal = styles.propose(value, index: index, scope: scope)
                return try (proposal.map { try map.encoderRingStyle(encoder: index, style: $0) }, styles.snapshot(CompactGeneratedDisplayValue.style))
            case let .invalidate(.button, index):
                buttons.invalidate(index)
                return (nil, buttons.snapshot(CompactGeneratedDisplayValue.button))
            case let .invalidate(.ring, index):
                rings.invalidate(index)
                return (nil, rings.snapshot(CompactGeneratedDisplayValue.ring))
            case let .invalidate(.style, index):
                styles.invalidate(index)
                return (nil, styles.snapshot(CompactGeneratedDisplayValue.style))
            }
        }
    }
#endif
