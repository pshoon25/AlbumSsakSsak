import SwiftUI
import Photos
import Combine

@MainActor
class PhotoViewModel: ObservableObject {
    @Published var filteredPhotos: [Photo] = []
    @Published var albums: [Album] = []
    @Published var favorites: [String] = []
    @Published var trash: [String] = []
    @Published var selectedAlbum: String?
    @Published var selectedFolder: String?
    @Published var startDate: Date?
    @Published var endDate: Date?
    @Published var viewMode: ViewMode = .month
    @Published var monthlyPhotos: [PhotoGroup] = []
    @Published var hasMore: Bool = true
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    
    @Published var photos: [Photo] = []
    @Published var favoritePhotos: [Photo] = []
    @Published var trashPhotos: [Photo] = []
    @Published var isFavoritesMain: Bool = false {
        didSet { updateCurrentIndex() }
    }
    @Published var isTrashMain: Bool = false {
        didSet { updateCurrentIndex() }
    }
    @Published var isLoading: Bool = false
    @Published var currentIndex: Int = 0

    private var currentPhotoPage: Int = 1
    private var currentFolderPage: Int = 1
    private let pageSize: Int = 50
    private let favoriteAlbumTitle = "Favorites"
    private let trashAlbumTitle = "Trash"
    private var yearMonthKeys: [String] = [] // 년/월 키 캐싱

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
            await loadPhotos(append: false)
            await MainActor.run {
                self.updateFilteredPhotos()
                print("Initialization complete: Photos: \(photos.count), Albums: \(albums.count), Monthly groups: \(monthlyPhotos.count)")
            }
        }
    }

    func checkPhotoLibraryPermission() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
            print("Authorization status updated: \(status)")
        }
    }
    
    private func updateCurrentIndex() {
        let displayPhotos = isFavoritesMain ? favoritePhotos : isTrashMain ? trashPhotos : photos.filter { !$0.isFavorite && !$0.isDeleted }
        currentIndex = displayPhotos.isEmpty ? 0 : min(currentIndex, displayPhotos.count - 1)
    }
    
    // 즐겨찾기 및 휴지통 앨범 생성
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
    
    // 앨범 로드
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
            self.objectWillChange.send()
        }
    }

    func updateFilteredPhotos() {
        favoritePhotos = photos.filter { $0.isFavorite && !$0.isDeleted }
        trashPhotos = photos.filter { $0.isDeleted }
    }
    
    // 사진 로드
    func loadPhotos(append: Bool = true) async {
        await checkPhotoLibraryPermission()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            print("Photo library access denied: \(authorizationStatus)")
            return
        }
        
        await MainActor.run { isLoading = true }
        
        // 중복 방지 및 데이터 초기화
        var photoIdSet: Set<String> = append ? Set(photos.map { $0.id }) : []
        var loadedPhotos: [Photo] = []
        var tempYearMonthKeys: Set<String> = Set(yearMonthKeys)
        var allPhotos: [Photo] = [] // 전체 사진 메타데이터용
        
        // 즐겨찾기와 휴지통 사진 로드
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
                        isFavorite: self.favorites.contains(photoId),
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
        
        // 일반 사진 로드 (페이지네이션)
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = pageSize
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
                    isFavorite: self.favorites.contains(photoId),
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
        
        // 전체 사진 메타데이터 로드 (년/월 키 생성용)
        let collectionFetchOptions = PHFetchOptions()
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: collectionFetchOptions)
        collections.enumerateObjects { (collection, _, _) in
            let assetFetchOptions = PHFetchOptions()
            assetFetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let allAssets = PHAsset.fetchAssets(in: collection, options: assetFetchOptions)
            allAssets.enumerateObjects { (asset, _, _) in
                let photoId = asset.localIdentifier
                if !photoIdSet.contains(photoId) {
                    let photo = Photo(
                        id: photoId,
                        asset: asset,
                        isFavorite: self.favorites.contains(photoId),
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
            self.yearMonthKeys = Array(tempYearMonthKeys).sorted { $0 > $1 } // 최신순 정렬
            self.updateFilteredPhotos()
            self.hasMore = assets.count >= pageSize
            isLoading = false
            self.objectWillChange.send()
        }
        await groupPhotosByMonth(photos: allPhotos)
    }

    // 월별 그룹화
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
            // 캐싱된 년/월 키 추가
            for key in self.yearMonthKeys {
                if map[key] == nil {
                    map[key] = []
                }
            }
            print("Photo map keys: \(map.keys)")
            return map
        }.value

        let grouped = groupAndSortPhotos(from: photoMap)
        await MainActor.run {
            self.monthlyPhotos = grouped
            print("Monthly photos count: \(grouped.count)")
            self.objectWillChange.send()
        }
    }

    // 무한 스크롤
    func loadMorePhotosIfNeeded(currentIndex: Int, totalCount: Int) async {
        guard currentIndex >= totalCount - 5, // 마지막 5장 근처에서 로드
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

    // 즐겨찾기 로드 및 저장
    func loadFavorites() {
        if let saved = UserDefaults.standard.array(forKey: "favorites") as? [String] {
            favorites = saved
        }
    }

    func saveFavorites() {
        UserDefaults.standard.set(favorites, forKey: "favorites")
    }

    // 휴지통 로드 및 저장
    func loadTrash() {
        if let saved = UserDefaults.standard.array(forKey: "trash") as? [String] {
            trash = saved
        }
    }

    func saveTrash() {
        UserDefaults.standard.set(trash, forKey: "trash")
    }

    // 즐겨찾기 토글
    func toggleFavorite(photoId: String) async {
        guard let photo = photos.first(where: { $0.id == photoId }),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else { return }
        
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].isFavorite.toggle()
            if photos[index].isFavorite {
                favorites.append(photoId)
                await addAssetToAlbum(asset: asset, albumTitle: favoriteAlbumTitle)
            } else {
                favorites.removeAll { $0 == photoId }
                await removeAssetFromAlbum(asset: asset, albumTitle: favoriteAlbumTitle)
            }
            saveFavorites()
            await MainActor.run {
                self.updateFilteredPhotos()
                self.objectWillChange.send()
            }
        }
    }

    // 사진 삭제
    func deletePhoto(photoId: String) async {
        guard let photo = photos.first(where: { $0.id == photoId }),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else { return }
        
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].isDeleted = true
            trash.append(photoId)
            await addAssetToAlbum(asset: asset, albumTitle: trashAlbumTitle)
            saveTrash()
            await MainActor.run {
                self.updateFilteredPhotos()
                self.objectWillChange.send()
            }
        }
    }
    
    // 사진 복원
    func restorePhoto(photoId: String) async {
        guard let photo = photos.first(where: { $0.id == photoId }),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else { return }
        
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].isDeleted = false
            trash.removeAll { $0 == photoId }
            await removeAssetFromAlbum(asset: asset, albumTitle: trashAlbumTitle)
            saveTrash()
            await MainActor.run {
                self.updateFilteredPhotos()
                self.objectWillChange.send()
            }
        }
    }

    // 영구 삭제
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
                self.objectWillChange.send()
            }
        } catch {
            print("Error permanently deleting photo: \(error)")
        }
    }

    // 사진 업데이트
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
    }

    // 폴더 사진 로드
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
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] // 오류 수정: 여분의 괄호 제거
        fetchOptions.fetchLimit = pageSize * page
        if let startDate = startDate, let endDate = endDate { // 오류 수정: 변수명 일관성 유지
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", startDate as NSDate, endDate as NSDate) // 오류 수정: Date?를 NSDate로 변환
        }
        let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        var newPhotos: [Photo] = []

        assets.enumerateObjects { (asset, _, _) in
            let albumName = collection.localizedTitle?.isEmpty ?? true ? "Unnamed Album" : collection.localizedTitle!
            newPhotos.append(Photo(
                id: asset.localIdentifier,
                asset: asset,
                isFavorite: self.favorites.contains(asset.localIdentifier),
                isDeleted: self.trash.contains(asset.localIdentifier),
                albumName: albumName,
                timestamp: asset.creationDate ?? Date()
            ))
        }

        print("Fetched folder assets count: \(assets.count), Loaded folder photos: \(newPhotos.count)")
        await MainActor.run {
            self.hasMore = newPhotos.count == pageSize * page
            if append {
                self.filteredPhotos.append(contentsOf: newPhotos)
            } else {
                self.filteredPhotos = newPhotos
            }
            isLoading = false
            self.objectWillChange.send()
        }
    }

    // 무한 스크롤: 폴더 사진 로드
    func loadMoreFolderPhotosIfNeeded(folderId: String, currentPhoto: Photo?) async {
        guard let currentPhoto = currentPhoto,
              let currentIndex = filteredPhotos.firstIndex(where: { $0.id == currentPhoto.id }),
              currentIndex >= filteredPhotos.count - 10,
              hasMore,
              !isLoading else { return }
        
        currentFolderPage += 1
        await loadFolderPhotos(folderId: folderId, page: currentFolderPage, append: true)
    }

    // 앨범에 사진 추가
    private func addAssetToAlbum(asset: PHAsset, albumTitle: String) async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumTitle)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        guard let collection = collections.firstObject else {
            print("Album \(albumTitle) not found")
            return
        }
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if let changeRequest = PHAssetCollectionChangeRequest(for: collection) {
                    changeRequest.addAssets([asset] as NSArray)
                }
            }
            print("Added asset to \(albumTitle)")
        } catch {
            print("Error adding asset to \(albumTitle): \(error)")
        }
    }

    // 앨범에서 사진 제거
    private func removeAssetFromAlbum(asset: PHAsset, albumTitle: String) async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumTitle)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        guard let collection = collections.firstObject else {
            print("Album \(albumTitle) not found")
            return
        }
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if let changeRequest = PHAssetCollectionChangeRequest(for: collection) {
                    changeRequest.removeAssets([asset] as NSArray)
                }
            }
            print("Removed asset from \(albumTitle)")
        } catch {
            print("Error removing asset from \(albumTitle): \(error)")
        }
    }
    
    func saveChanges() async {
        // 즐겨찾기 사진 처리 (이미 Favorites 앨범에 추가됨, 확인 및 유지)
        for photoId in favorites {
            guard let photo = photos.first(where: { $0.id == photoId }),
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else { continue }
            // 이미 toggleFavorite에서 Favorites 앨범에 추가됨, 중복 추가 방지
            print("Confirmed favorite photo \(photoId) in Favorites album")
        }
        
        // 휴지통 사진을 iOS '최근 삭제된 항목'으로 이동
        var assetsToDelete: [PHAsset] = []
        for photoId in trash {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject {
                assetsToDelete.append(asset)
            }
        }
        
        if !assetsToDelete.isEmpty {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
                }
                print("Moved \(assetsToDelete.count) photos to iOS Recently Deleted")
            } catch {
                print("Error moving photos to Recently Deleted: \(error)")
            }
        }
        
        // 상태 초기화
        await MainActor.run {
            self.photos.removeAll { photo in
                favorites.contains(photo.id) || trash.contains(photo.id)
            }
            self.favorites.removeAll()
            self.trash.removeAll()
            self.saveFavorites()
            self.saveTrash()
            self.updateFilteredPhotos()
            self.objectWillChange.send()
        }
        
        // 사진 목록 갱신
        currentPhotoPage = 1
        await loadPhotos(append: false)
    }
}
