import SwiftUI

@main
public struct SignetApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 680, height: 780)
    }
}
