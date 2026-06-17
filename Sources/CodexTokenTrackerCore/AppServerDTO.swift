import Foundation

struct RPCResponse<T: Decodable>: Decodable {
    let id: Int?
    let result: T?
    let error: RPCError?
}

struct RPCError: Decodable, Error, CustomStringConvertible {
    let code: Int?
    let message: String

    var description: String {
        if let code {
            return "\(message) (\(code))"
        }
        return message
    }
}

public struct InitializeResponse: Decodable {
    public let userAgent: String
    public let codexHome: String
    public let platformFamily: String
    public let platformOs: String
}

public struct GetAccountResponse: Decodable {
    public let account: AccountDTO?
    public let requiresOpenaiAuth: Bool
}

public enum AccountDTO: Decodable {
    case apiKey
    case chatGPT(email: String?, planType: String?)
    case amazonBedrock
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "apiKey":
            self = .apiKey
        case "chatgpt":
            self = .chatGPT(
                email: try container.decodeIfPresent(String.self, forKey: .email),
                planType: try container.decodeIfPresent(String.self, forKey: .planType)
            )
        case "amazonBedrock":
            self = .amazonBedrock
        default:
            self = .unknown(type: type)
        }
    }
}

public struct GetAccountRateLimitsResponse: Decodable {
    public let rateLimits: RateLimitSnapshotDTO
    public let rateLimitsByLimitId: [String: RateLimitSnapshotDTO]?
}

public struct GetAccountTokenUsageResponse: Decodable {
    public let summary: AccountTokenUsageSummaryDTO
    public let dailyUsageBuckets: [AccountTokenUsageDailyBucketDTO]?
}

public struct AccountTokenUsageSummaryDTO: Decodable {
    public let lifetimeTokens: Int?
    public let peakDailyTokens: Int?
    public let longestRunningTurnSec: Int?
    public let currentStreakDays: Int?
    public let longestStreakDays: Int?
}

public struct AccountTokenUsageDailyBucketDTO: Decodable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int
}

public struct RateLimitSnapshotDTO: Decodable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindowDTO?
    public let secondary: RateLimitWindowDTO?
    public let credits: CreditsSnapshotDTO?
    public let planType: String?
    public let rateLimitReachedType: String?
}

public struct RateLimitWindowDTO: Decodable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?
}

public struct CreditsSnapshotDTO: Decodable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?
}
