import Foundation

struct TokenActivityStats: Equatable {
    let localRecordDays: [Date]

    static let empty = TokenActivityStats(localRecordDays: [])
}
