#if DEBUG
    import SurfaceFeedbackPlanning
    import XTouchCompactCore

    /// This value owner receives only captured display operations. Native results are
    /// passed to the comparator separately and cannot populate any proposed value.
    struct GeneratedDisplayCacheReference: Sendable {
        private struct Cache<Value: Equatable & Sendable>: Sendable {
            var requests: FeedbackRequestState<Int, Value>
            var order: [Int] = []
            var scopes: [Int: CompactResourceScope] = [:]

            init(policy: RepeatedRequestPolicy) {
                requests = .init(repeatedRequestPolicy: policy, withdrawnIntentPolicy: .discard)
            }

            mutating func propose(_ value: Value, index: Int, scope: CompactResourceScope) -> Value? {
                guard let proposal = requests.request(value, for: index) else { return nil }
                if scopes.updateValue(scope, forKey: index) == nil {
                    order.append(index)
                }
                return proposal
            }

            mutating func invalidate(_ index: Int?) {
                if let index {
                    requests.invalidate([index])
                    scopes.removeValue(forKey: index)
                    order.removeAll { $0 == index }
                } else {
                    requests.clear()
                    scopes.removeAll()
                    order.removeAll()
                }
            }

            func snapshot(_ wrap: (Value) -> CompactGeneratedDisplayValue) -> CompactGeneratedDisplaySnapshot {
                .init(orderedIndices: order, values: requests.proposed.mapValues(wrap), scopes: scopes)
            }
        }

        private var buttons: Cache<ButtonLight>
        private var rings: Cache<RingDisplay>
        private var styles: Cache<RingStyle>

        init(policy: RepeatedRequestPolicy = .suppressAfterProposal) {
            buttons = .init(policy: policy)
            rings = .init(policy: policy)
            styles = .init(policy: policy)
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
