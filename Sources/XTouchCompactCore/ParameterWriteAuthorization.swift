import Foundation

/// Trusted host identities. Remote clients cannot select or construct this context.
public enum ParameterWriter: String, Codable, Hashable, Sendable {
    case interface, remote, hardware, history
}

public enum ParameterWriteAuthorizationError: Error, Equatable, Sendable {
    case staleContext, identityDenied, parameterDenied(String), writesDenied
    case authorityDenied(String)
    case invalidAuthorityValue
}

/// Session policy, independent of Agent-specific capabilities and device safety policy.
/// It contains no parameter values and therefore cannot become another value authority.
public struct ParameterWriteAuthorization: Equatable, Sendable {
    public var routeGeneration: UInt64
    public var bindingGeneration: UInt64
    public var allowedWriters: Set<ParameterWriter>?
    public var allowedParameters: Set<String>?
    public var allowsValues: Bool
    public var allowsDisplay: Bool
    public var allowsMechanisms: Bool

    public init(routeGeneration: UInt64 = 0, bindingGeneration: UInt64 = 0,
                allowedWriters: Set<ParameterWriter>? = nil, allowedParameters: Set<String>? = nil,
                allowsValues: Bool = true, allowsDisplay: Bool = true, allowsMechanisms: Bool = true)
    {
        self.routeGeneration = routeGeneration; self.bindingGeneration = bindingGeneration
        self.allowedWriters = allowedWriters; self.allowedParameters = allowedParameters
        self.allowsValues = allowsValues; self.allowsDisplay = allowsDisplay; self.allowsMechanisms = allowsMechanisms
    }

    public func validate(parameterID: String, writer: ParameterWriter,
                         routeGeneration: UInt64, bindingGeneration: UInt64) throws
    {
        guard routeGeneration == self.routeGeneration, bindingGeneration == self.bindingGeneration else {
            throw ParameterWriteAuthorizationError.staleContext
        }
        guard allowedWriters?.contains(writer) != false else { throw ParameterWriteAuthorizationError.identityDenied }
        guard allowedParameters?.contains(parameterID) != false else { throw ParameterWriteAuthorizationError.parameterDenied(parameterID) }
        guard allowsValues else { throw ParameterWriteAuthorizationError.writesDenied }
    }
}
