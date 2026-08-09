import Foundation

enum JobError: Error {
  case entryNotFound(id: UUID)
  case apiRequestFailed(url: String, statusCode: Int)
  case missingToken(id: UUID)
  case decodingFailed(url: String, underlying: any Error)

  var description: String {
    switch self {
    case .entryNotFound(let id):
      "No entry found with id \(id)"
    case .apiRequestFailed(let url, let statusCode):
      "API request to \(url) failed with status \(statusCode)"
    case .missingToken(let id):
      "Account \(id) has no access token"
    case .decodingFailed(let url, let underlying):
      "Could not decode response from \(url): \(underlying)"
    }
  }
}
