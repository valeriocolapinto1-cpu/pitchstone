import Foundation

/// Regole della sezione 7: i dati di salute restano solo sull'iPad.
public enum Privacy {
    /// Un nodo è sensibile se è di tipo `health` o nell'area `salute`.
    public static func isSensitive(_ node: NodeRecord) -> Bool {
        node.type == .health || node.area == .salute
    }

    /// Un arco va al server solo se entrambi gli estremi esistono e non sono sensibili.
    @MainActor
    public static func isSyncable(_ edge: EdgeRecord, in store: SyncStore) -> Bool {
        guard let source = store.node(edge.sourceID), let target = store.node(edge.targetID) else { return false }
        return !isSensitive(source) && !isSensitive(target)
    }
}
