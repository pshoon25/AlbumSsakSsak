// ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PhotoViewModel()

    var body: some View {
        MainView(viewModel: viewModel)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
