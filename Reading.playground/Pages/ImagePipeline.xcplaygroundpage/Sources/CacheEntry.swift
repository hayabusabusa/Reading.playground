import Foundation

public struct CacheEntry {
    /// 画像を取得してきた URL.
    public let url: URL
    /// 画像のバイナリデータ.
    public let data: Data
    /// 拡張子？
    public let contentType: String?
    /// 有効期間.
    public let timeToLive: TimeInterval?
    /// 作成日時.
    public let creationDate: Date
    /// 変更日時？
    public let modificationDate: Date
    
    public init(url: URL,
                data: Data,
                contentType: String?,
                timeToLive: TimeInterval?,
                creationDate: Date,
                modificationDate: Date) {
        self.url = url
        self.data = data
        self.contentType = contentType
        self.timeToLive = timeToLive
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

extension CacheEntry: Equatable {
    public static func == (lhs: CacheEntry, rhs: CacheEntry) -> Bool {
        // 比較の際には URL とバイナリデータを比較する.
        return lhs.url == rhs.url && lhs.data == rhs.data
    }
}
