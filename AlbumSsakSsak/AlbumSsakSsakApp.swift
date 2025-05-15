import SwiftUI

@main
struct AlbumSsakSsakApp: App {
    @StateObject private var viewModel = PhotoViewModel()

    var body: some Scene {
        WindowGroup {
            MainView(viewModel: viewModel)
        }
    }
}
