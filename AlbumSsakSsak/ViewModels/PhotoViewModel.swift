import SwiftUI
import Photos
import Combine

@MainActor
class PhotoViewModel: ObservableObject {
    @Published var albums: [Album] = []
    @Published var favorites: [String] = []
    @Published var trash: [String] = []
    @Published var selectedAlbum: String?
    @Published var startDate: Date?
    @Published var endDate: Date?
    @Published var monthlyPhotos: [PhotoGroup] = []
    @Published var hasMore: Bool = true
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading: Bool = false
    @Published var photos: [Photo] = []
    @Published var favoritePhotos: [Photo] = []
    @Published var trashPhotos: [Photo] = []
    @Published var filteredPhotos: [Photo] = []
    @Published var isFavoritesMain: Bool = false
    @Published var isTrashMain: Bool = false
    @Published var viewMode: ViewMode = .month
    @Published var selectedFolder: String?
    @Published var stateHash: UUID = UUID()
    @Published var shouldResetNavigation: Bool = false

    private var currentPhotoPage: Int = 1
    private var currentFolderPage: Int = 1
    private let pageSize: Int = 50
    private let favoriteAlbumTitle = "Favorites"
    private let trashAlbumTitle = "Trash"
    private var yearMonthKeys: [String] = []

    enum ViewMode {
        case month
        case folder
    }

    struct PhotoGroup: Hashable, Identifiable {
        let id: String
        let year: Int
        let month: Int
        let photos: [Photo]

        init(year: Int, month: Int, photos: [Photo]) {
            self.id = "\(year)-\(month)"
            self.year = year
            self.month = month
            self.photos = photos
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: PhotoGroup, rhs: PhotoGroup) -> Bool {
            lhs.id == rhs.id
        }
    }

    init() {
        Task {
            await checkPhotoLibraryPermission()
            guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                print("Photo library access denied: \(authorizationStatus)")
                return
            }
            loadFavorites()
            loadTrash()
            await createSystemAlbumsIfNeeded()
            await loadAlbums()
            await loadPhotos(append: false, loadAll: true) // 전체 사진 로드
            await MainActor.run {
                self.updateFilteredPhotos()
                self.stateHash = UUID()
                print("Initialization complete: Photos: \(photos.count), Albums: \(albums.count), Monthly groups: \(monthlyPhotos.count)")
            }
        }
    }

    func checkPhotoLibraryPermission() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
            self.stateHash = UUID()
            print("Authorization status updated: \(status)")
        }
    }

    func updateFilteredPhotos() {
        favoritePhotos = photos.filter { favorites.contains($0.id) && !$0.isDeleted } // 수정: isFavorite -> favorites.contains
        trashPhotos = photos.filter { $0.isDeleted }
        // filteredPhotos가 비어 있지 않다면 상태 동기화
        filteredPhotos = filteredPhotos.map { photo in
            if let updatedPhoto = photos.first(where: { $0.id == photo.id }) {
                return updatedPhoto
            }
            return photo
        }
        stateHash = UUID()
        print("Updated filteredPhotos: \(filteredPhotos.count), favoritePhotos: \(favoritePhotos.count), trashPhotos: \(trashPhotos.count)")
    }

    func loadPhotos(append: Bool = true, loadAll: Bool = false) async {
        await checkPhotoLibraryPermission()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            print("Photo library access denied: \(authorizationStatus)")
            return
        }
        
        await MainActor.run { isLoading = true }
        
        var photoIdSet: Set<String> = append ? Set(photos.map { $0.id }) : []
        var loadedPhotos: [Photo] = []
        var tempYearMonthKeys: Set<String> = Set(yearMonthKeys)
        var allPhotos: [Photo] = []
        
        // 즐겨찾기/휴지통 사진 로드
        let allPhotoIds = Array(Set(favorites + trash))
        if !allPhotoIds.isEmpty {
            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "localIdentifier IN %@", allPhotoIds)
            let assets = PHAsset.fetchAssets(with: fetchOptions)
            assets.enumerateObjects { (asset, _, _) in
                let photoId = asset.localIdentifier
                if !photoIdSet.contains(photoId) {
                    let photo = Photo(
                        id: photoId,
                        asset: asset,
                        isFavorite: self.favorites.contains(photoId), // 수정: PHAsset.isFavorite -> favorites.contains
                        isDeleted: self.trash.contains(photoId),
                        albumName: "All Photos",
                        timestamp: asset.creationDate ?? Date()
                    )
                    loadedPhotos.append(photo)
                    allPhotos.append(photo)
                    photoIdSet.insert(photoId)
                    
                    let date = photo.timestamp
                    let year = Calendar.current.component(.year, from: date)
                    let month = Calendar.current.component(.month, from: date)
                    let key = "\(year)-\(month)"
                    tempYearMonthKeys.insert(key)
                }
            }
            print("Loaded favorites/trash photos: \(loadedPhotos.count)")
        }
        
        // 전체 사진 로드
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if !loadAll {
            fetchOptions.fetchLimit = self.pageSize
        }
        if !photoIdSet.isEmpty {
            fetchOptions.predicate = NSPredicate(format: "NOT (localIdentifier IN %@)", Array(photoIdSet))
        }
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        
        assets.enumerateObjects { (asset, _, _) in
            let photoId = asset.localIdentifier
            if !photoIdSet.contains(photoId) {
                let photo = Photo(
                    id: photoId,
                    asset: asset,
                    isFavorite: self.favorites.contains(photoId), // 수정: PHAsset.isFavorite -> favorites.contains
                    isDeleted: self.trash.contains(photoId),
                    albumName: "All Photos",
                    timestamp: asset.creationDate ?? Date()
                )
                loadedPhotos.append(photo)
                allPhotos.append(photo)
                photoIdSet.insert(photoId)
                
                let date = photo.timestamp
                let year = Calendar.current.component(.year, from: date)
                let month = Calendar.current.component(.month, from: date)
                let key = "\(year)-\(month)"
                tempYearMonthKeys.insert(key)
            }
        }
        
        // 스마트 앨범 사진 로드
        let collectionFetchOptions = PHFetchOptions()
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: collectionFetchOptions)
        collections.enumerateObjects { (collection, _, _) in
            let assetFetchOptions = PHFetchOptions()
            assetFetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if loadAll {
                assetFetchOptions.fetchLimit = 0
            } else {
                assetFetchOptions.fetchLimit = self.pageSize
            }
            let allAssets = PHAsset.fetchAssets(in: collection, options: assetFetchOptions)
            allAssets.enumerateObjects { (asset, _, _) in
                let photoId = asset.localIdentifier
                if !photoIdSet.contains(photoId) {
                    let photo = Photo(
                        id: photoId,
                        asset: asset,
                        isFavorite: self.favorites.contains(photoId), // 수정: PHAsset.isFavorite -> favorites.contains
                        isDeleted: self.trash.contains(photoId),
                        albumName: "All Photos",
                        timestamp: asset.creationDate ?? Date()
                    )
                    allPhotos.append(photo)
                    photoIdSet.insert(photoId)
                    
                    let date = photo.timestamp
                    let year = Calendar.current.component(.year, from: date)
                    let month = Calendar.current.component(.month, from: date)
                    let key = "\(year)-\(month)"
                    tempYearMonthKeys.insert(key)
                }
            }
        }
        
        print("Fetched assets count: \(assets.count), Total loaded photos: \(loadedPhotos.count), All photos: \(allPhotos.count)")
        
        await MainActor.run {
            if append {
                self.photos.append(contentsOf: loadedPhotos)
            } else {
                self.photos = loadedPhotos
            }
            self.yearMonthKeys = Array(tempYearMonthKeys).sorted { $0 > $1 }
            self.updateFilteredPhotos()
            self.hasMore = loadAll ? false : (assets.count >= self.pageSize)
            isLoading = false
            self.stateHash = UUID()
            print("Photos loaded, total: \(self.photos.count), yearMonthKeys: \(self.yearMonthKeys.count)")
        }
        await groupPhotosByMonth(photos: allPhotos)
    }

    func groupPhotosByMonth(photos: [Photo] = []) async {
        let photoMap = await Task {
            var map: [String: [Photo]] = [:]
            for photo in photos.isEmpty ? self.photos : photos {
                let date = photo.timestamp
                let year = Calendar.current.component(.year, from: date)
                let month = Calendar.current.component(.month, from: date)
                let key = "\(year)-\(month)"
                map[key, default: []].append(photo)
            }
            // 모든 년월 키 포함
            for key in self.yearMonthKeys {
                if map[key] == nil {
                    map[key] = []
                }
            }
            print("Photo map keys: \(map.keys.sorted()), photo counts: \(map.mapValues { $0.count })")
            return map
        }.value

        let grouped = groupAndSortPhotos(from: photoMap)
        await MainActor.run {
            self.monthlyPhotos = grouped
            // filteredPhotos 동기화
            if !filteredPhotos.isEmpty, let firstPhoto = filteredPhotos.first {
                let year = Calendar.current.component(.year, from: firstPhoto.timestamp)
                let month = Calendar.current.component(.month, from: firstPhoto.timestamp)
                let key = "\(year)-\(month)"
                if let selectedGroup = grouped.first(where: { $0.id == key }) {
                    self.filteredPhotos = selectedGroup.photos.filter { !$0.isFavorite && !$0.isDeleted }
                }
            }
            self.stateHash = UUID()
            print("Monthly photos updated: \(grouped.count) groups, counts: \(grouped.map { "\($0.id): \($0.photos.count)" })")
        }
    }
    
    func loadMorePhotosIfNeeded(currentIndex: Int, totalCount: Int) async {
        guard currentIndex >= totalCount - 5,
              hasMore,
              !isLoading else { return }
        
        currentPhotoPage += 1
        await loadPhotos(append: true)
    }

    private func groupAndSortPhotos(from photoMap: [String: [Photo]]) -> [PhotoGroup] {
        let mapped = photoMap.map { (key, photos) in
            let components = key.split(separator: "-").compactMap { Int($0) }
            guard components.count == 2 else {
                return PhotoGroup(year: 0, month: 0, photos: photos)
            }
            return PhotoGroup(year: components[0], month: components[1], photos: photos)
        }

        return mapped.sorted { a, b in
            a.year == b.year ? a.month > b.month : a.year > b.year
        }
    }

    func loadFavorites() {
        if let saved = UserDefaults.standard.array(forKey: "favorites") as? [String] {
            favorites = saved
        }
    }

    func saveFavorites() {
        UserDefaults.standard.set(favorites, forKey: "favorites")
    }

    func loadTrash() {
        if let saved = UserDefaults.standard.array(forKey: "trash") as? [String] {
            trash = saved
        }
    }

    func saveTrash() {
        UserDefaults.standard.set(trash, forKey: "trash")
    }

    func toggleFavorite(photoId: String) async {
        guard let photo = photos.first(where: { $0.id == photoId }) else {
            print("Photo not found for photoId: \(photoId)")
            return
        }
        
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            print("Cannot toggle favorite: Photo library access denied (\(authorizationStatus))")
            return
        }
        
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].isFavorite.toggle()
            let isFavorite = photos[index].isFavorite
            
            if isFavorite {
                if !favorites.contains(photoId) {
                    favorites.append(photoId)
                }
                print("Added photo \(photoId) to favorites array")
            } else {
                favorites.removeAll { $0 == photoId }
                print("Removed photo \(photoId) from favorites array")
            }
            
            saveFavorites()
            await MainActor.run {
                if let filteredIndex = filteredPhotos.firstIndex(where: { $0.id == photoId }) {
                    filteredPhotos[filteredIndex].isFavorite = isFavorite
                } else if !isFavorite && !photos[index].isDeleted {
                    filteredPhotos.append(photos[index])
                }
                self.updateFilteredPhotos()
                self.stateHash = UUID()
                self.objectWillChange.send()
                print("Toggled favorite for \(photoId), favorites count: \(favorites.count)")
            }
            await groupPhotosByMonth()
        }
    }
    
    func deletePhoto(photoId: String) async {
        guard let photo = photos.first(where: { $0.id == photoId }),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else {
            print("Photo or asset not found for photoId: \(photoId)")
            return
        }
        
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            print("Cannot delete photo: Photo library access denied (\(authorizationStatus))")
            return
        }
        
        do {
            if let index = photos.firstIndex(where: { $0.id == photoId }) {
                photos[index].isDeleted = true
                if !trash.contains(photoId) {
                    trash.append(photoId)
                }
                try await addAssetToAlbum(asset: asset, albumTitle: trashAlbumTitle)
                saveTrash()
                await MainActor.run {
                    filteredPhotos.removeAll { $0.id == photoId }
                    self.updateFilteredPhotos()
                    self.stateHash = UUID()
                    self.objectWillChange.send() // UI 갱신 보장
                    print("Deleted photo \(photoId), trash count: \(trash.count)")
                }
                await groupPhotosByMonth()
            }
        } catch {
            print("Error adding photo \(photoId) to Trash: \(error.localizedDescription)")
            await MainActor.run {
                self.stateHash = UUID()
                self.objectWillChange.send()
            }
        }
    }
    
    func restorePhoto(photoId: String) async {
        guard let photo = photos.first(where: { $0.id == photoId }),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else {
            print("Photo or asset not found for photoId: \(photoId)")
            return
        }
        
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            print("Cannot restore photo: Photo library access denied (\(authorizationStatus))")
            return
        }
        
        do {
            if let index = photos.firstIndex(where: { $0.id == photoId }) {
                photos[index].isDeleted = false
                trash.removeAll { $0 == photoId }
                try await removeAssetFromAlbum(asset: asset, albumTitle: trashAlbumTitle)
                saveTrash()
                await MainActor.run {
                    if !photos[index].isFavorite && !filteredPhotos.contains(where: { $0.id == photoId }) {
                        filteredPhotos.append(photos[index])
                    }
                    self.updateFilteredPhotos()
                    self.stateHash = UUID()
                    self.objectWillChange.send() // UI 갱신 보장
                    print("Restored photo \(photoId), trash count: \(trash.count)")
                }
                await groupPhotosByMonth()
            }
        } catch {
            print("Error restoring photo \(photoId) from Trash: \(error.localizedDescription)")
            await MainActor.run {
                self.stateHash = UUID()
                self.objectWillChange.send()
            }
        }
    }
    
    func permanentlyDeletePhoto(photoId: String) async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else { return }
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            photos.removeAll { $0.id == photoId }
            trash.removeAll { $0 == photoId }
            favorites.removeAll { $0 == photoId }
            saveTrash()
            saveFavorites()
            await MainActor.run {
                self.updateFilteredPhotos()
                self.stateHash = UUID()
            }
            await groupPhotosByMonth()
        } catch {
            print("Error permanently deleting photo: \(error)")
        }
    }

    func updatePhotos() async {
        let favorites = self.favorites
        let trash = self.trash

        let updatedPhotos = await Task {
            self.photos.map { photo in
                let isFavorite = favorites.contains(photo.id)
                let isDeleted = trash.contains(photo.id)
                return Photo(
                    id: photo.id,
                    asset: photo.asset,
                    isFavorite: isFavorite,
                    isDeleted: isDeleted,
                    albumName: photo.albumName,
                    timestamp: photo.timestamp
                )
            }
        }.value

        photos = updatedPhotos
        await groupPhotosByMonth()
        stateHash = UUID()
    }

    func loadFolderPhotos(folderId: String, page: Int = 1, append: Bool = false) async {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [folderId], options: nil).firstObject else {
            print("Folder not found: \(folderId)")
            return
        }
        await MainActor.run { isLoading = true }
        
        if !append || selectedFolder != folderId {
            currentFolderPage = 1
            filteredPhotos.removeAll()
            selectedFolder = folderId
        }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = pageSize * page
        if let startDate = startDate, let endDate = endDate {
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", startDate as NSDate, endDate as NSDate)
        }
        let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        var newPhotos: [Photo] = []

        assets.enumerateObjects { (asset, _, _) in
            let albumName = collection.localizedTitle?.isEmpty ?? true ? "Unnamed Album" : collection.localizedTitle!
            let photoId = asset.localIdentifier
            if let existingPhoto = self.photos.first(where: { $0.id == photoId }) {
                newPhotos.append(existingPhoto)
            } else {
                let newPhoto = Photo(
                    id: photoId,
                    asset: asset,
                    isFavorite: self.favorites.contains(photoId),
                    isDeleted: self.trash.contains(photoId),
                    albumName: albumName,
                    timestamp: asset.creationDate ?? Date()
                )
                newPhotos.append(newPhoto)
                self.photos.append(newPhoto)
            }
        }

        print("Fetched folder assets count: \(assets.count), Loaded folder photos: \(newPhotos.count), folderId: \(folderId)")
        await MainActor.run {
            self.hasMore = newPhotos.count == pageSize * page
            if append {
                self.filteredPhotos.append(contentsOf: newPhotos)
            } else {
                self.filteredPhotos = newPhotos
            }
            self.updateFilteredPhotos()
            isLoading = false
            self.stateHash = UUID()
            print("Folder photos updated, filteredPhotos: \(self.filteredPhotos.count)")
        }
        await groupPhotosByMonth()
    }
    
    func loadMoreFolderPhotosIfNeeded(folderId: String, currentPhoto: Photo?) async {
        guard let currentPhoto = currentPhoto,
              let currentIndex = filteredPhotos.firstIndex(where: { $0.id == currentPhoto.id }),
              currentIndex >= filteredPhotos.count - 10,
              hasMore,
              !isLoading else { return }
        
        currentFolderPage += 1
        await loadFolderPhotos(folderId: folderId, page: currentFolderPage, append: true)
    }

    private func addAssetToAlbum(asset: PHAsset, albumTitle: String) async throws {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumTitle)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        guard let collection = collections.firstObject else {
            print("Album \(albumTitle) not found, creating it")
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            }
            // 재시도
            let retryCollections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
            guard let newCollection = retryCollections.firstObject else {
                throw NSError(domain: "PhotoViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create or find album \(albumTitle)"])
            }
            try await PHPhotoLibrary.shared().performChanges {
                if let changeRequest = PHAssetCollectionChangeRequest(for: newCollection) {
                    changeRequest.addAssets([asset] as NSArray)
                }
            }
            print("Created and added asset to \(albumTitle)")
            return
        }
        
        try await PHPhotoLibrary.shared().performChanges {
            if let changeRequest = PHAssetCollectionChangeRequest(for: collection) {
                changeRequest.addAssets([asset] as NSArray)
            }
        }
        print("Added asset to \(albumTitle)")
    }
    
    private func removeAssetFromAlbum(asset: PHAsset, albumTitle: String) async throws {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumTitle)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        guard let collection = collections.firstObject else {
            print("Album \(albumTitle) not found")
            throw NSError(domain: "PhotoViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Album \(albumTitle) not found"])
        }
        
        try await PHPhotoLibrary.shared().performChanges {
            if let changeRequest = PHAssetCollectionChangeRequest(for: collection) {
                changeRequest.removeAssets([asset] as NSArray)
            }
        }
        print("Removed asset from \(albumTitle)")
    }

    func saveChanges() async {
        await MainActor.run {
            self.isLoading = true
            print("saveChanges started, isLoading: \(self.isLoading)")
        }
        
        do {
            // 권한 확인
            await checkPhotoLibraryPermission()
            guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                print("Cannot save changes: Photo library access denied (\(authorizationStatus))")
                await MainActor.run {
                    self.isLoading = false
                    self.stateHash = UUID()
                    self.objectWillChange.send()
                }
                return
            }
            
            // photoId 목록으로 PHAsset 일괄 조회
            let allPhotoIds = photos.map { $0.id }
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: allPhotoIds, options: nil)
            var assetMap: [String: PHAsset] = [:]
            fetchResult.enumerateObjects { asset, _, _ in
                assetMap[asset.localIdentifier] = asset
            }
            
            var photoChangeRequests: [() -> Void] = []
            var assetsToDelete: [PHAsset] = []
            
            // 즐겨찾기 동기화 (추가만 수행)
            for photo in photos {
                guard let asset = assetMap[photo.id] else {
                    print("Asset not found for photoId: \(photo.id)")
                    continue
                }
                if favorites.contains(photo.id) && !asset.isFavorite {
                    photoChangeRequests.append {
                        let request = PHAssetChangeRequest(for: asset)
                        request.isFavorite = true
                    }
                    try await addAssetToAlbum(asset: asset, albumTitle: favoriteAlbumTitle)
                    print("Added photo \(photo.id) to iOS Favorites and Favorites album")
                }
            }
            
            // 휴지통 처리
            for photoId in trash {
                if let asset = assetMap[photoId] {
                    assetsToDelete.append(asset)
                }
            }
            
            // 사진 라이브러리 변경
            try await PHPhotoLibrary.shared().performChanges {
                for changeRequest in photoChangeRequests {
                    changeRequest()
                }
                if !assetsToDelete.isEmpty {
                    PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
                    print("Moved \(assetsToDelete.count) photos to iOS Recently Deleted")
                }
            }
            
            // 상태 갱신
            await MainActor.run {
                // 삭제된 사진 제거
                self.photos.removeAll { self.trash.contains($0.id) }
                // 즐겨찾기와 휴지통 초기화
                self.favorites.removeAll()
                self.trash.removeAll()
                self.saveFavorites()
                self.saveTrash()
                self.updateFilteredPhotos()
                self.isLoading = false
                self.selectedFolder = nil
                self.selectedAlbum = nil
                self.shouldResetNavigation = true
                self.stateHash = UUID()
                self.objectWillChange.send()
                print("Photos updated, count: \(self.photos.count), favorites: \(self.favorites.count), favoritePhotos: \(self.favoritePhotos.count)")
            }
            
            // 변경된 사진만 갱신
            await loadPhotos(append: false, loadAll: true)
            await updatePhotos()
            print("saveChanges completed")
            
        } catch {
            print("Error in saveChanges: \(error.localizedDescription)")
            await MainActor.run {
                self.isLoading = false
                self.selectedFolder = nil
                self.selectedAlbum = nil
                self.shouldResetNavigation = true
                self.stateHash = UUID()
                self.objectWillChange.send()
                print("Error handled, maintaining favorites: \(self.favorites.count), trash: \(self.trash.count)")
                // 사용자에게 에러 알림 표시 (옵션)
                // 예: UIAlertController를 사용하거나 SwiftUI Alert를 트리거
            }
            await loadPhotos(append: false, loadAll: true)
            await updatePhotos()
        }
    }
    
    func loadAlbums() async {
        isLoading = true
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            print("Album loading denied: \(status)")
            isLoading = false
            return
        }

        let fetchResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albumList: [Album] = []

        fetchResult.enumerateObjects { (collection, _, _) in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            var photos: [Photo] = []
            assets.enumerateObjects { (asset, _, _) in
                let albumName = collection.localizedTitle?.isEmpty ?? true ? "Unnamed Album" : collection.localizedTitle!
                photos.append(Photo(
                    id: asset.localIdentifier,
                    asset: asset,
                    isFavorite: self.favorites.contains(asset.localIdentifier),
                    isDeleted: self.trash.contains(asset.localIdentifier),
                    albumName: albumName,
                    timestamp: asset.creationDate ?? Date()
                ))
            }
            if !photos.isEmpty {
                let albumName = collection.localizedTitle?.isEmpty ?? true ? "Unnamed Album" : collection.localizedTitle!
                albumList.append(Album(
                    id: collection.localIdentifier,
                    name: albumName,
                    coverAsset: assets.firstObject,
                    count: photos.count,
                    photos: photos
                ))
            }
        }

        print("Loaded albums count: \(albumList.count)")
        await MainActor.run {
            self.albums = albumList
            self.selectedAlbum = albumList.first?.id
            isLoading = false
            self.stateHash = UUID()
        }
    }

    private func createSystemAlbumsIfNeeded() async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@ OR title = %@", favoriteAlbumTitle, trashAlbumTitle)
        let existingAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        var favoriteAlbumExists = false
        var trashAlbumExists = false
        
        existingAlbums.enumerateObjects { (collection, _, _) in
            if collection.localizedTitle == self.favoriteAlbumTitle {
                favoriteAlbumExists = true
            } else if collection.localizedTitle == self.trashAlbumTitle {
                trashAlbumExists = true
            }
        }
        
        do {
            if !favoriteAlbumExists {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: self.favoriteAlbumTitle)
                }
                print("Created Favorites album")
            }
            if !trashAlbumExists {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: self.trashAlbumTitle)
                }
                print("Created Trash album")
            }
        } catch {
            print("Error creating system albums: \(error)")
        }
    }
}
