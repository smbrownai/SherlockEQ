import SwiftUI

/// Bridges SwiftUI's `\.undoManager` environment value into
/// `ProfileStore.undoManager` so the store can register undo entries
/// from `save`/`delete` without every editor having to thread the
/// manager through. Apply once high up the view tree (MainWindowView).
struct UndoManagerLink: ViewModifier {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var profileStore: ProfileStore

    func body(content: Content) -> some View {
        content
            .onAppear { profileStore.undoManager = undoManager }
            .onChange(of: undoManager) { _, new in
                profileStore.undoManager = new
            }
    }
}

extension View {
    /// Pushes the active `\.undoManager` into `ProfileStore` whenever it
    /// changes. Use once at the top of the main-window hierarchy.
    func linkUndoManagerToProfileStore() -> some View {
        modifier(UndoManagerLink())
    }
}
