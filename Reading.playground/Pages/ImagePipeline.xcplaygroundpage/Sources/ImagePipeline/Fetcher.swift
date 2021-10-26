import Foundation

/// 実際に通信を行う部分のインターフェース.
public protocol Fetching {
    func fetch(_ url: URL, completion: @escaping (CacheEntry) -> Void, cancellation: @escaping () -> Void, failure: @escaping (Error?) -> Void)
    func cancel(_ url: URL)
    func cancelAll()
}

/// 実際に通信を行う `Fetcher`.
public final class Fetcher: Fetching {
    private let session: URLSession
    private let taskExecuter = TaskExecuter()
    
    // 通信実行用のキュー.
    // 優先度 `.userInitiated` ( ユーザーに数秒以内に処理の結果を返す必要がある ) で作成する.
    private let queue = DispatchQueue(label: "reading.image-pipeline.fetcher", qos: .userInitiated)
    
    public init() {
        // キャッシュやクッキー、クレデンシャルなどの永続的なストレージを利用しない設定.
        let configuration = URLSessionConfiguration.ephemeral
        // 1 つのTCPコネクション上で、複数のHTTPリクエストを応答を待つことなく送信する.
        configuration.httpShouldUsePipelining = true
        // 指定されたホストへの最大接続数、iOS はデフォルト 4.
        configuration.httpMaximumConnectionsPerHost = 4
        // リクエストがタイムアウトするまでの時間.
        configuration.timeoutIntervalForRequest = 30
        // リソース
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }
    
    deinit {
        // セッションをキャンセルする.
        session.invalidateAndCancel()
    }
    
    public func fetch(_ url: URL,
                      completion: @escaping (CacheEntry) -> Void,
                      cancellation: @escaping () -> Void,
                      failure: @escaping (Error?) -> Void) {
        // ここで一旦プロパティをキャプチャしておく.
        let queue = self.queue
        let taskExecuter = self.taskExecuter
        
        // キャッシュからリロードしない設定でリクエストする.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let task = session.dataTask(with: request) { data, response, error in
            queue.sync {
                taskExecuter.removeTask(for: url)
            }
            
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                cancellation()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                failure(error)
                return
            }
            
            guard let response = response as? HTTPURLResponse else {
                failure(error)
                return
            }
            
            let headers = response.allHeaderFields
            
            // ヘッダーから `Cache-Control` の情報( キャッシュディレクティブ )を抜き出す.
            // https://developer.mozilla.org/ja/docs/Web/HTTP/Headers/Cache-Control
            var timeToLive: TimeInterval? = nil
            if let cacheControl = headers["Cache-Control"] as? String {
                let directives = parseCacheControlHeader(cacheControl)
                // `max-age=60` から `60` の値を取り出す.
                if let maxAge = directives["max-age"],
                   let ttl = TimeInterval(maxAge) {
                    // キャッシュの有効期間に設定する.
                    timeToLive = ttl
                }
            }
            
            let contentType = headers["Content-Type"] as? String
            
            let now = Date()
            // 新規キャッシュを作成する
            let entry = CacheEntry(url: url, data: data, contentType: contentType, timeToLive: timeToLive, creationDate: now, modificationDate: now)
            completion(entry)
        }
        
        queue.sync {
            taskExecuter.push(DownloadTask(sessionTask: task, url: url))
        }
    }
    
    public func cancel(_ url: URL) {
        taskExecuter.cancel(for: url)
    }
    
    public func cancelAll() {
        taskExecuter.cancelAll()
    }
}

/// ダウンロードのタスクの実行を管理するクラス.
private class TaskExecuter {
    /// ダウンロードを行うタスク一覧.
    private var tasks = [DownloadTask]()
    /// 現在実行されているタスク一覧.
    private var runningTasks = [URL: DownloadTask]()
    /// 平行実行できるタスクの最大値.
    private let maxConcurrentTasks = 4
    
    /// 新しいダウンロードタスクを追加する.
    /// - Parameter task: `DownloadTask`
    func push(_ task: DownloadTask) {
        // すでに追加されているタスクの場合はキャンセルして削除する.
        if let index = tasks.firstIndex(of: task) {
            tasks.remove(at: index).sessionTask.cancel()
        }
        tasks.append(task)
        // 実行前のタスクを実行する.
        startPendingTasks()
    }
    
    func removeTask(for url: URL) {
        runningTasks.removeValue(forKey: url)?.sessionTask.cancel()
        // 実行前のタスクを実行する.
        startPendingTasks()
    }
    
    func cancel(for url: URL) {
        runningTasks.removeValue(forKey: url)?.sessionTask.cancel()
    }
    
    func cancelAll() {
        // 全ての実行前のタスク、実行中のタスクをキャンセルする.
        let allTasks = tasks + runningTasks.values
        allTasks.forEach { $0.sessionTask.cancel() }
        
        tasks.removeAll()
        runningTasks.removeAll()
    }
    
    /// 現在実行前になっているタスクを実行する.
    private func startPendingTasks() {
        // タスクが残っていて、かつ同時実行数が最大値よりも少ない限りは実行する.
        while tasks.count > 0 && runningTasks.count <= maxConcurrentTasks {
            // 一番古い実行前のタスクを取り出して、実行と実行中のタスク一覧に追加する.
            let task = tasks.removeLast()
            task.sessionTask.resume()
            runningTasks[task.url] = task
        }
    }
}

/// ダウンロードを行なっているタスクを表すクラス.
///
/// URL を持っていて、URL ごとに管理を行う.
private class DownloadTask: Hashable {
    let sessionTask: URLSessionTask
    let url: URL
    
    init(sessionTask: URLSessionTask, url: URL) {
        self.sessionTask = sessionTask
        self.url = url
    }
    
    func hash(into hasher: inout Hasher) {
        // URL ごとにハッシュ値を生成する.
        // URL を見て同じものかどうかを判断する.
        hasher.combine(url)
    }
    
    static func == (lhs: DownloadTask, rhs: DownloadTask) -> Bool {
        return lhs.url == rhs.url
    }
}

// MARK: - Helper

private let regex = try! NSRegularExpression(pattern:
    """
    ([a-zA-Z][a-zA-Z_-]*)\\s*(?:=(?:"([^"]*)"|([^ \t",;]*)))?
    """, options: [])
internal func parseCacheControlHeader(_ cacheControl: String) -> [String: String] {
    // 正規表現で `Cache-Control: public, max-age=60` のような文字列から ["max-age": "60"] のような辞書配列にパースする.
    let matches = regex.matches(in: cacheControl, options: [], range: NSRange(location: 0, length: cacheControl.utf16.count))
    return matches.reduce(into: [String: String]()) { (directives, result) in
        if let range = Range(result.range, in: cacheControl) {
            let directive = cacheControl[range]
            let pair = directive.split(separator: "=")
            if pair.count == 2 {
                directives[String(pair[0])] = String(pair[1])
            }
        }
    }
}
