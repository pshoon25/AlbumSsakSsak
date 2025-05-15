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

    private var currentPhotoPage: Int = 1 // 전체 사진 페이지
    private var currentFolderPage: Int = 1 // 폴더 사진 페이지
    private let pageSize: Int = 50 // 한 번에 로드할 사진 수

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
            await groupPhotosByMonth()
            await loadAlbums()
            await loadPhotos()
            loadFavorites()
            loadTrash()
            print("Initialization complete: Photos: \(photos.count), Albums: \(albums.count), Monthly groups: \(monthlyPhotos.count)")
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
    
    // 사진 로드 (페이지네이션 적용)
    func loadPhotos(append: Bool = true) async {
        await checkPhotoLibraryPermission()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            print("Photo library access denied: \(authorizationStatus)")
            return
        }
        
        await MainActor.run { isLoading = true }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = pageSize // 페이지당 50장
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        
        var loadedPhotos: [Photo] = []
        assets.enumerateObjects { (asset, _, _) in
            loadedPhotos.append(Photo(
                id: asset.localIdentifier,
                asset: asset,
                isFavorite: self.favorites.contains(asset.localIdentifier),
                isDeleted: self.trash.contains(asset.localIdentifier),
                albumName: "All Photos",
                timestamp: asset.creationDate ?? Date()
            ))
        }
        
        print("Fetched assets count: \(assets.count), Loaded photos: \(loadedPhotos.count)")
        
        await MainActor.run {
            if append {
                self.photos.append(contentsOf: loadedPhotos)
            } else {
                self.photos = loadedPhotos
            }
            self.updateFilteredPhotos()
            self.hasMore = loadedPhotos.count == pageSize
            isLoading = false
            self.objectWillChange.send()
        }
        await groupPhotosByMonth()
    }

    // 월별 그룹화 (수정)
    func groupPhotosByMonth() async {
        let photoMap = await Task {
            var map: [String: [Photo]] = [:]
            for photo in self.photos {
                let date = photo.timestamp
                let year = Calendar.current.component(.year, from: date)
                let month = Calendar.current.component(.month, from: date)
                let key = "\(year)-\(month)"
                map[key, default: []].append(photo)
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
    
    // 무한 스크롤: 메인 이미지 섹션에서 오른쪽 스와이프 시 사진 로드
    func loadMorePhotosIfNeeded(currentPhoto: Photo?) async {
        guard let currentPhoto = currentPhoto,
              let currentIndex = photos.firstIndex(where: { $0.id == currentPhoto.id }),
              currentIndex >= photos.count - 10, // 마지막 10장 근처에서 로드
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
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].isFavorite.toggle()
            if photos[index].isFavorite {
                favorites.append(photoId)
            } else {
                favorites.removeAll { $0 == photoId }
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
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].isDeleted = true
            trash.append(photoId)
            saveTrash()
            await MainActor.run {
                self.updateFilteredPhotos()
                self.objectWillChange.send()
            }
        }
    }
    
    // 사진 복원
    func restorePhoto(photoId: String) async {
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].isDeleted = false
            trash.removeAll { $0 == photoId }
            saveTrash()
            await MainActor.run {
                self.updateFilteredPhotos()
                self.objectWillChange.send()
            }
        }
    }

    // 영구 삭제
    func permanentlyDeletePhoto(photoId: String) async {
        photos.removeAll { $0.id == photoId }
        trash.removeAll { $0 == photoId }
        favorites.removeAll { $0 == photoId }
        saveTrash()
        saveFavorites()
        await MainActor.run {
            self.updateFilteredPhotos()
            self.objectWillChange.send()
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

    // 폴더 사진 로드 (페이지네이션 적용)
    func loadFolderPhotos(folderId: String, page: Int = 1, append: Bool = false) async {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [folderId], options: nil).firstObject else {
            print("Folder not found: \(folderId)")
            return
        }
        await MainActor.run { isLoading = true }
        
        // 폴더가 바뀌었거나 새로 로드하는 경우 페이지와 필터 초기화
        if !append || selectedFolder != folderId {
            currentFolderPage = 1
            filteredPhotos.removeAll()
            selectedFolder = folderId
        }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = pageSize * page
        if let start = startDate, let end = endDate {
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
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
              currentIndex >= filteredPhotos.count - 10, // 마지막 10장 근처에서 로드
              hasMore,
              !isLoading else { return }
        
        currentFolderPage += 1
        await loadFolderPhotos(folderId: folderId, page: currentFolderPage, append: true)
    }
}
