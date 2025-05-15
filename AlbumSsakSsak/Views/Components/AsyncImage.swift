import SwiftUI
import Photos

struct SsakSsakAsyncImage: View {
    let asset: PHAsset
    let size: CGSize
    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    
    var body: some View {
        Group {
            if let fullImage = fullImage {
                Image(uiImage: fullImage)
                    .resizable()
                    .scaledToFill()
            } else if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 2) // 썸네일 표시 시 약간의 블러 효과
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
            loadThumbnail()
            loadFullImage()
        }
    }
    
    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false // 로컬 이미지만 먼저 시도
        
        PHImageManager.default().requestImage(for: asset,
                                             targetSize: CGSize(width: size.width / 2, height: size.height / 2),
                                             contentMode: .aspectFill,
                                             options: options) { (result, info) in
            if let result = result {
                DispatchQueue.main.async {
                    self.thumbnail = result
                }
            } else if let error = info?[PHImageErrorKey] as? Error {
                print("Thumbnail load error for asset \(asset.localIdentifier): \(error)")
                // iCloud에서 재시도
                let networkOptions = PHImageRequestOptions()
                networkOptions.isSynchronous = false
                networkOptions.deliveryMode = .fastFormat
                networkOptions.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset,
                                                     targetSize: CGSize(width: size.width / 2, height: size.height / 2),
                                                     contentMode: .aspectFill,
                                                     options: networkOptions) { (result, info) in
                    if let result = result {
                        DispatchQueue.main.async {
                            self.thumbnail = result
                        }
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        print("Thumbnail network load error for asset \(asset.localIdentifier): \(error)")
                    }
                }
            }
        }
    }
    
    private func loadFullImage() {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(for: asset,
                                             targetSize: size,
                                             contentMode: .aspectFill,
                                             options: options) { (result, info) in
            if let result = result {
                DispatchQueue.main.async {
                    self.fullImage = result
                }
            } else if let error = info?[PHImageErrorKey] as? Error {
                print("Full image load error for asset \(asset.localIdentifier): \(error)")
            }
        }
    }
}
