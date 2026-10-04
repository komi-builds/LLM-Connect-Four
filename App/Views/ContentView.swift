import SwiftUI

struct ContentView: View {
    @State private var model = GameViewModel()

    var body: some View {
        Text("LLM Connect Four")
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
