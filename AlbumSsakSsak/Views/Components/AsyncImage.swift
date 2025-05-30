import SwiftUI
import Photos

struct SsakSsakAsyncImage: View {
    let asset: PHAsset
    let size: CGSize
    @State private var image: UIImage?
    
    private static let cachingManager = PHCachingImageManager()
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit() // 비율 유지
            } else {
                ProgressView()
                    .frame(width: size.width, height: size.height)
                    .overlay(
                        Color.gray.opacity(0.2)
                            .overlay(Text("Loading...").foregroundColor(.white).font(.caption))
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear {
            loadImage()
            cacheImage()
        }
        .onDisappear {
            Self.cachingManager.stopCachingImages(for: [asset], targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: nil)
        }
    }
    
    private func loadImage() {
        let scale = UIScreen.main.scale // @2x, @3x 고려
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit, // 비율 유지
            options: options
        ) { result, info in
            if let result = result, info?[PHImageResultIsDegradedKey] as? Bool == false {
                DispatchQueue.main.async {
                    self.image = result
                    print("Loaded high-quality image for asset \(asset.localIdentifier), size: \(result.size)")
                }
            } else if let error = info?[PHImageErrorKey] as? Error {
                print("Image load error for asset \(asset.localIdentifier): \(error)")
            }
        }
    }
    
    private func cacheImage() {
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        
        Self.cachingManager.startCachingImages(
            for: [asset],
            targetSize: targetSize,
            contentMode: .aspectFit, // 비율 유지
            options: options
        )
    }
}
