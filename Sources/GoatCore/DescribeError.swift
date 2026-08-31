import Foundation
import FountainKit

/// One table from error to user copy — the pattern every Fountain app keeps.
/// Show the real error; a generic "could not be reached" hides the cause.
public func describe(_ error: any Error) -> String {
    guard let fountainError = error as? FountainError else {
        return (error as NSError).localizedDescription
    }
    switch fountainError.code {
    case "environment_not_allowed":
        return "This agent doesn't allow that environment."
    case "runner_offline":
        return "The runner this teammate lives on is offline."
    case "no_runner_online":
        return "No self-hosted runner is online."
    case "team_comms_not_enabled":
        return "Team contact features aren't enabled on this deployment."
    case "api_key_invalid":
        return "That API key isn't valid on this server."
    case "api_key_expired":
        return "That API key has expired — mint a new one."
    case "api_key_revoked":
        return "That API key was revoked."
    case "billing_disabled":
        return "Billing is off on this deployment."
    default:
        return fountainError.description
    }
}
