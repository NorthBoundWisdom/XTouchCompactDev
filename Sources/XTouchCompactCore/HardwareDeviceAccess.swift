import Foundation

/// Immutable process-start selection. Disabled access never calls the enabled transport factory.
public enum HardwareDeviceAccess: String, Sendable {
    case enabled, disabled

    public enum SelectionError: Error { case disabledRejectsTestInjection }

    public func make<Transport>(testInjectionRequested: Bool, disabled: () throws -> Transport,
                                enabled: () throws -> Transport) throws -> Transport
    {
        if self == .disabled {
            guard !testInjectionRequested else { throw SelectionError.disabledRejectsTestInjection }
            return try disabled()
        }
        return try enabled()
    }
}
