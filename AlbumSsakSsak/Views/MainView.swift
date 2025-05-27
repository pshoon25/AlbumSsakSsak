import SwiftUI
import Photos

// 안전한 배열 인덱스 접근을 위한 확장
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct MainView: View {
    @ObservedObject var viewModel: PhotoViewModel
    @State private var isAlbumOpen = false
    @State private var currentIndex: Int = 0
    @State private var showStartPicker = false
    @State private var showEndPicker = false
    @State private var photoToDelete: String?
    @State private var showDeleteAlert = false
    @State private var selectedMonth: PhotoViewModel.PhotoGroup?
    @State private var currentDisplayPhotos: [Photo] = []

    var body: some View {
        NavigationView {
            ZStack {
                mainContent
                if isAlbumOpen {
                    albumOverlay
                }
            }
        }
        .onChange(of: viewModel.filteredPhotos) { _ in // filteredPhotos 변경 감지, 중복 제거
            updateDisplayPhotos()
            print("filteredPhotos changed, count: \(viewModel.filteredPhotos.count)")
        }
    }

    // 메인 콘텐츠
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerView
            if viewModel.authorizationStatus != .authorized && viewModel.authorizationStatus != .limited {
                permissionDeniedView
            } else if viewModel.isLoading {
                loadingView
            } else if viewModel.monthlyPhotos.isEmpty && viewModel.albums.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .onAppear {
            print("MainView appeared, Photos: \(viewModel.photos.count), Albums: \(viewModel.albums.count)")
            Task {
                await viewModel.loadAlbums()
                await viewModel.loadPhotos()
                await MainActor.run {
                    updateDisplayPhotos()
                }
            }
        }
        .onChange(of: viewModel.stateHash) { _ in
            updateDisplayPhotos()
            print("State hash changed, currentDisplayPhotos count: \(currentDisplayPhotos.count)")
        }
    }

    // 권한 거부 뷰
    private var permissionDeniedView: some View {
        VStack {
            Text("사진 라이브러리 접근 권한이 필요합니다.")
                .font(.headline)
                .foregroundColor(.gray)
                .padding()
            Button("설정으로 이동") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(Capsule())
        }
    }

    // 로딩 뷰
    private var loadingView: some View {
        VStack {
            SVGWebView()
                .frame(width: 300, height: 300)
            Text("로딩 중...")
                .font(.headline)
                .foregroundColor(.gray)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    // 빈 뷰
    private var emptyView: some View {
        Text("사진이 없습니다.")
            .font(.headline)
            .foregroundColor(.gray)
    }

    // 앨범 오버레이
    private var albumOverlay: some View {
        Group {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isAlbumOpen = false
                        selectedMonth = nil
                    }
                }
            albumSection
                .frame(width: UIScreen.main.bounds.width * 0.9, height: UIScreen.main.bounds.height * 0.6)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 10)
                .scaleEffect(isAlbumOpen ? 1 : 0.5)
                .opacity(isAlbumOpen ? 1 : 0)
                .offset(y: isAlbumOpen ? 0 : 100)
                .transition(.scale.combined(with: .opacity))
                .zIndex(1)
        }
    }

    // 헤더 뷰
    private var headerView: some View {
        HStack {
            Image("LogoIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
            Spacer()
            if !viewModel.favorites.isEmpty || !viewModel.trash.isEmpty {
                Button(action: {
                    Task {
                        await viewModel.saveChanges()
                        await MainActor.run {
                            isAlbumOpen = false
                            updateDisplayPhotos() // 사진 목록 갱신
                        }
                    }
                }) {
                    Text("저장")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(viewModel.isLoading ? Color.gray : Color.black)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .disabled(viewModel.isLoading) // 로딩 중 버튼 비활성화
            } else {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isAlbumOpen.toggle()
                    }
                }) {
                    Image("AlbumSelectIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundColor(.black)
                        .scaleEffect(isAlbumOpen ? 1.2 : 1.0)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top)
        .background(Color.white)
        .onChange(of: viewModel.shouldResetNavigation) { newValue in // iOS 14.0 이상 호환
            if newValue {
                isAlbumOpen = false // 앨범 오버레이 닫기
                currentIndex = 0 // 현재 사진 인덱스 초기화
                updateDisplayPhotos() // 사진 목록 갱신
                viewModel.shouldResetNavigation = false // 트리거 초기화
                print("Navigation reset triggered")
            }
        }
    }

    // 메인 콘텐츠 뷰
    private var contentView: some View {
        VStack(spacing: 0) {
            favoriteSection
            mainImageSection
            trashSection
            adSection
        }
    }

    // displayPhotos 업데이트
    private func updateDisplayPhotos() {
        let photosToDetermine: [Photo]
        if viewModel.isFavoritesMain {
            photosToDetermine = viewModel.favoritePhotos
        } else if viewModel.isTrashMain {
            photosToDetermine = viewModel.trashPhotos
        } else {
            let allNonSpecialPhotos = viewModel.photos.filter { !$0.isFavorite && !$0.isDeleted }
            let filteredNonSpecialPhotos = viewModel.filteredPhotos.filter { !$0.isFavorite && !$0.isDeleted }
            photosToDetermine = viewModel.filteredPhotos.isEmpty ? allNonSpecialPhotos : filteredNonSpecialPhotos
        }
        currentDisplayPhotos = photosToDetermine
        if !currentDisplayPhotos.isEmpty {
            let currentPhotoId = currentDisplayPhotos[safe: currentIndex]?.id
            if let currentPhotoId, let newIndex = currentDisplayPhotos.firstIndex(where: { $0.id == currentPhotoId }) {
                currentIndex = newIndex
            } else {
                currentIndex = 0
            }
        } else {
            currentIndex = 0
        }
        print("updateDisplayPhotos: Count: \(currentDisplayPhotos.count), currentIndex: \(currentIndex), filteredPhotos: \(viewModel.filteredPhotos.count)")
    }

    // 앨범 섹션
    private var albumSection: some View {
        VStack {
            viewModeButtons
            if viewModel.viewMode == .folder && viewModel.selectedFolder != nil {
                folderPhotosView
            } else if viewModel.viewMode == .folder {
                folderListView
            } else if selectedMonth != nil {
                monthPhotosView
            } else {
                monthListView
            }
        }
        .padding()
        .background(Color.white)
    }

    // 뷰 모드 버튼
    private var viewModeButtons: some View {
        HStack {
            Button(action: {
                withAnimation {
                    viewModel.viewMode = .month
                    selectedMonth = nil
                    viewModel.filteredPhotos = []
                    updateDisplayPhotos()
                }
            }) {
                Text("월 별")
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(viewModel.viewMode == .month && selectedMonth == nil ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundColor(viewModel.viewMode == .month && selectedMonth == nil ? .white : .black)
                    .clipShape(Capsule())
            }
            Button(action: {
                withAnimation {
                    viewModel.viewMode = .folder
                    selectedMonth = nil
                    viewModel.filteredPhotos = []
                    updateDisplayPhotos()
                }
            }) {
                Text("폴더별")
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(viewModel.viewMode == .folder ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundColor(viewModel.viewMode == .folder ? .white : .black)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 10)
    }

    // 월별 사진 뷰
    private var monthPhotosView: some View {
        VStack {
            HStack {
                Button(action: {
                    withAnimation {
                        selectedMonth = nil
                        viewModel.filteredPhotos = []
                        updateDisplayPhotos()
                    }
                }) {
                    Image("arrowBackIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundColor(.black)
                }
                Spacer()
                dateFilterView
            }
            .padding(.horizontal)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 5) {
                    ForEach(viewModel.filteredPhotos) { photo in
                        Button(action: {
                            currentDisplayPhotos = viewModel.filteredPhotos.filter { !$0.isFavorite && !$0.isDeleted }
                            if let index = currentDisplayPhotos.firstIndex(where: { $0.id == photo.id }) {
                                currentIndex = index
                            } else {
                                currentIndex = 0
                            }
                            print("Selected photo: \(photo.id), currentIndex: \(currentIndex)")
                            withAnimation {
                                isAlbumOpen = false
                            }
                        }) {
                            SsakSsakAsyncImage(asset: photo.asset, size: CGSize(width: 80, height: 80))
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // 폴더별 사진 뷰
    private var folderPhotosView: some View {
        VStack {
            HStack {
                Button(action: {
                    viewModel.selectedFolder = nil
                    viewModel.filteredPhotos = []
                    updateDisplayPhotos()
                }) {
                    Image("arrowBackIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundColor(.black)
                }
                Spacer()
                dateFilterView
            }
            .padding(.horizontal)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 5) {
                    ForEach(viewModel.filteredPhotos) { photo in
                        Button(action: {
                            currentDisplayPhotos = viewModel.filteredPhotos.filter { !$0.isFavorite && !$0.isDeleted }
                            if let index = currentDisplayPhotos.firstIndex(where: { $0.id == photo.id }) {
                                currentIndex = index
                            } else {
                                currentIndex = 0
                            }
                            print("Selected folder photo: \(photo.id), currentIndex: \(currentIndex)")
                            withAnimation {
                                isAlbumOpen = false
                            }
                        }) {
                            SsakSsakAsyncImage(asset: photo.asset, size: CGSize(width: 80, height: 80))
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .onAppear {
                                    Task {
                                        if let folderId = viewModel.selectedFolder {
                                            await viewModel.loadMoreFolderPhotosIfNeeded(folderId: folderId, currentPhoto: photo)
                                        }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // 폴더 목록 뷰
    private var folderListView: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: max(1, Int(UIScreen.main.bounds.width / 120))), spacing: 10) {
                ForEach(viewModel.albums) { album in
                    Button(action: {
                        Task {
                            viewModel.selectedFolder = album.id
                            viewModel.selectedAlbum = album.id
                            await viewModel.loadFolderPhotos(folderId: album.id, page: 1)
                            await MainActor.run {
                                updateDisplayPhotos()
                                if let firstPhoto = currentDisplayPhotos.first,
                                   let index = currentDisplayPhotos.firstIndex(where: { $0.id == firstPhoto.id }) {
                                    currentIndex = index
                                } else {
                                    currentIndex = 0
                                }
                                print("Selected folder: \(album.name), currentIndex: \(currentIndex), filteredPhotos: \(viewModel.filteredPhotos.count)")
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isAlbumOpen = false // 로드 완료 후 오버레이 닫기
                                }
                            }
                        }
                    }) {
                        VStack {
                            if let coverAsset = album.coverAsset {
                                SsakSsakAsyncImage(asset: coverAsset, size: CGSize(width: 100, height: 100))
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Color.gray.opacity(0.2)
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        Text("No Image")
                                            .foregroundColor(.white)
                                            .font(.caption)
                                    )
                            }
                            Text(album.name)
                                .foregroundColor(.black)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // 월별 리스트 뷰
    private var monthListView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible())], spacing: 10) {
                ForEach(viewModel.monthlyPhotos, id: \.id) { group in
                    Button(action: {
                        withAnimation {
                            selectedMonth = group
                            viewModel.filteredPhotos = group.photos.filter { !$0.isFavorite && !$0.isDeleted }
                            updateDisplayPhotos()
                            print("Selected month: \(group.year)-\(group.month), filteredPhotos count: \(viewModel.filteredPhotos.count)")
                        }
                    }) {
                        VStack {
                            Text("\(group.year)년 \(group.month)월")
                                .font(.headline)
                                .foregroundColor(.black)
                            Text("\(group.photos.count)장")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // 날짜 필터 뷰
    private var dateFilterView: some View {
        HStack {
            Button(action: { showStartPicker = true }) {
                Text(viewModel.startDate?.formatted(date: .abbreviated, time: .omitted) ?? "시작")
                    .foregroundColor(.black)
            }
            Text("-")
            Button(action: { showEndPicker = true }) {
                Text(viewModel.endDate?.formatted(date: .abbreviated, time: .omitted) ?? "종료")
                    .foregroundColor(.black)
            }
        }
        .sheet(isPresented: $showStartPicker) {
            DatePicker("시작 날짜", selection: Binding(
                get: { viewModel.startDate ?? Date() },
                set: { viewModel.startDate = $0 }
            ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
        }
        .sheet(isPresented: $showEndPicker) {
            DatePicker("종료 날짜", selection: Binding(
                get: { viewModel.endDate ?? Date() },
                set: { viewModel.endDate = $0 }
            ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
        }
    }

    // 즐겨찾기 섹션
    private var favoriteSection: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("즐겨찾기")
                    .font(.headline)
                    .foregroundColor(.black)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.favoritePhotos.reversed()) { photo in
                        Button(action: {
                            Task {
                                await viewModel.toggleFavorite(photoId: photo.id)
                                await MainActor.run {
                                    updateDisplayPhotos()
                                }
                            }
                        }) {
                            SsakSsakAsyncImage(asset: photo.asset, size: CGSize(width: 60, height: 60))
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 5)
        .background(Color.white)
    }

    // 메인 이미지 섹션
    private var mainImageSection: some View {
        GeometryReader { geometry in
            ZStack {
                if currentDisplayPhotos.isEmpty {
                    Text("표시할 사진이 없습니다.")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TabView(selection: Binding(
                        get: { min(currentIndex, max(0, currentDisplayPhotos.count - 1)) },
                        set: { newValue in
                            currentIndex = max(0, min(newValue, currentDisplayPhotos.count - 1))
                            Task {
                                if !viewModel.isFavoritesMain && !viewModel.isTrashMain {
                                    await viewModel.loadMorePhotosIfNeeded(currentIndex: currentIndex, totalCount: currentDisplayPhotos.count)
                                }
                            }
                            print("TabView selection changed, currentIndex: \(currentIndex)")
                        }
                    )) {
                        ForEach(currentDisplayPhotos.indices, id: \.self) { index in
                            let photo = currentDisplayPhotos[index]
                            ZStack {
                                SsakSsakAsyncImage(asset: photo.asset, size: CGSize(width: geometry.size.width - 80, height: geometry.size.height))
                                    .frame(width: geometry.size.width - 80, height: geometry.size.height)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                if photo.isFavorite {
                                    Image(systemName: "heart.fill")
                                        .foregroundColor(.red)
                                        .frame(width: 24, height: 24)
                                        .background(Color.white.opacity(0.8))
                                        .clipShape(Circle())
                                        .position(x: geometry.size.width - 40, y: 40)
                                }
                            }
                            .tag(index)
                            .gesture(
                                DragGesture(minimumDistance: 50)
                                    .onEnded { value in
                                        let verticalTranslation = value.translation.height
                                        let horizontalTranslation = value.translation.width
                                        print("DragGesture: vertical: \(verticalTranslation), horizontal: \(horizontalTranslation)")
                                        if abs(verticalTranslation) > abs(horizontalTranslation) * 2 && abs(verticalTranslation) > 100 {
                                            if verticalTranslation < 0 { // 위로 스와이프
                                                print("Swipe up on photo \(photo.id)")
                                                if viewModel.isTrashMain {
                                                    Task {
                                                        await viewModel.toggleFavorite(photoId: photo.id)
                                                        await viewModel.restorePhoto(photoId: photo.id)
                                                        await MainActor.run {
                                                            updateDisplayPhotos()
                                                            currentIndex = min(currentIndex, max(0, currentDisplayPhotos.count - 1))
                                                        }
                                                    }
                                                } else {
                                                    Task {
                                                        await viewModel.toggleFavorite(photoId: photo.id)
                                                        await MainActor.run {
                                                            updateDisplayPhotos()
                                                            currentIndex = min(currentIndex, max(0, currentDisplayPhotos.count - 1))
                                                        }
                                                    }
                                                }
                                            } else if verticalTranslation > 0 { // 아래로 스와이프
                                                print("Swipe down on photo \(photo.id)")
                                                if viewModel.isTrashMain {
                                                    Task {
                                                        await viewModel.restorePhoto(photoId: photo.id)
                                                        await MainActor.run {
                                                            updateDisplayPhotos()
                                                            currentIndex = min(currentIndex, max(0, currentDisplayPhotos.count - 1))
                                                        }
                                                    }
                                                } else {
                                                    Task {
                                                        await viewModel.deletePhoto(photoId: photo.id)
                                                        await MainActor.run {
                                                            updateDisplayPhotos()
                                                            currentIndex = min(currentIndex, max(0, currentDisplayPhotos.count - 1))
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .contentShape(Rectangle())
                        }
                    }
                    .tabViewStyle(.page)
                    .indexViewStyle(.page(backgroundDisplayMode: .never))
                    .animation(.easeInOut, value: currentIndex)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    Text("\(min(currentIndex, max(0, currentDisplayPhotos.count - 1)) + 1) / \(currentDisplayPhotos.count)")
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 20)
                }
            }
        }
        .background(Color.white)
    }

    // 휴지통 섹션
    private var trashSection: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("휴지통")
                    .font(.headline)
                    .foregroundColor(.black)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.trashPhotos.reversed()) { photo in
                        Button(action: {
                            Task {
                                await viewModel.restorePhoto(photoId: photo.id)
                                await MainActor.run {
                                    updateDisplayPhotos()
                                }
                            }
                        }) {
                            SsakSsakAsyncImage(asset: photo.asset, size: CGSize(width: 60, height: 60))
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .opacity(0.6)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 5)
        .background(Color.white)
    }

    // 광고 섹션
    private var adSection: some View {
        BannerAdView(adUnitID: adUnitID)
            .frame(height: 50)
            .background(Color.white)
    }

    private var adUnitID: String {
        return "ca-app-pub-3940256099942544/2934735716"
    }
}
