import Foundation

public final class ImagePipeline {
    /// シングルトン.
    ///
    /// 基本的にシングルトンで作成したものを利用する.
    public static let shared = ImagePipeline()
    
    private init() {}
}
