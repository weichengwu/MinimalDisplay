import Foundation

/// Identity lookup seam: disabled displays can lose their public UUID mapping.
struct DisplayIdentityResolver {
    var uuidForID: (UInt32) -> String?
    var idForUUID: (String) -> UInt32?
    var isOnline: (UInt32) -> Bool

    func resolve(_ saved: SavedDisplay, required: Bool, allowOfflineID: Bool) throws -> UInt32? {
        let currentUUID = uuidForID(saved.id)
        if currentUUID == saved.uuid { return saved.id }
        if let id = idForUUID(saved.uuid), uuidForID(id) == saved.uuid { return id }
        // CGS-disabled displays disappear from UUID lookup. Only journaled offline IDs
        // from this boot may be used; never override a different or online identity.
        if allowOfflineID, currentUUID == nil, !isOnline(saved.id) { return saved.id }
        if required { throw DisplayFailure("无法确认原显示器身份，恢复记录已保留。") }
        return nil
    }
}
