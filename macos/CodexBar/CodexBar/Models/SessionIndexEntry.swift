import Foundation

struct SessionIndexEntry: Identifiable, Equatable {
    enum Storage: Equatable {
        case active
        case archived
    }

    let id: String
    let threadID: String?
    let title: String
    let filePath: String
    let projectPath: String?
    let modifiedAt: Date
    let fileSize: Int64
    let storage: Storage

    // Session bodies are intentionally never retained by this index.
    var body: String? { nil }
}
