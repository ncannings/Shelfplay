import SwiftData
import SwiftUI

@main
struct ShelfPlayApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let container = try! ModelContainer(for: ShelfAlbum.self)
        self.container = container
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ScannerView()
                .environment(model)
                .modelContainer(container)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
        }
    }
}
