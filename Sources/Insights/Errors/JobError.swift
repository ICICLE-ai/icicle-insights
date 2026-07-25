import Foundation

enum JobError: Error {
    case entryNotFound(id: UUID)
    case apiRequestFailed(statusCode: Int, message: String)
    case missingToken(id: UUID)

    var description: String {
        switch self {
        case .entryNotFound(let id):
            "No entry found with id \(id)"
        case .apiRequestFailed(let statusCode, let message):
            "API request failed (\(statusCode)): \(message)"
        case .missingToken(let id):
            "Account \(id) has no access token"
        }
    }
}
