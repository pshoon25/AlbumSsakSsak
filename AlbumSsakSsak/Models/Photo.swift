import Foundation
import Photos

struct Photo: Identifiable, Equatable {
    let id: String
    let asset: PHAsset
    var isFavorite: Bool
    var isDeleted: Bool
    var albumName: String?
    let timestamp: Date
    
    init(id: String, asset: PHAsset, isFavorite: Bool = false, isDeleted: Bool = false, albumName: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.asset = asset
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
        self.albumName = albumName
        self.timestamp = timestamp
    }
    
    // Equatable 구현
    static func == (lhs: Photo, rhs: Photo) -> Bool {
        lhs.id == rhs.id
    }
}
