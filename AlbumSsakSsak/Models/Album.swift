import Foundation
import Photos

struct Album: Identifiable {
    let id: String
    let name: String
    let coverAsset: PHAsset?
    let count: Int
    let photos: [Photo]
}
