import Foundation
import Testing

/// SwiftUI keyboard shortcuts cannot be introspected from a unit test, and the project has no
/// UI test target. The invariant is nonetheless worth protecting mechanically, because its
/// violation is invisible in review: a destructive confirmation looks correct whether or not it
/// carries `.defaultAction`, and the consequence is unrecoverable file deletion.
///
/// These tests therefore assert against the view source itself, in the same spirit as
/// `ReleaseScriptSafetyTests`, which locates the repository via `#filePath` and exercises a real
/// artefact rather than a Swift stand-in.
struct DestructiveConfirmationSafetyTests {
    private static let overviewViewSource: String = {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appending(path: "Sources/Views/OverviewView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The modifier chain applied to the confirmation sheet's "Clean Up" button, i.e. everything
    /// between that button and the end of its enclosing `HStack`.
    private func cleanUpButtonModifiers() throws -> String {
        let source = Self.overviewViewSource
        #expect(!source.isEmpty, "OverviewView.swift could not be read")

        let anchor = try #require(
            source.range(of: #"Button("Clean Up", role: .destructive"#),
            "The confirmation button was renamed; update this safety test deliberately."
        )
        let remainder = source[anchor.upperBound...]
        // The button is the last element of its HStack, so the chain ends at the closing brace.
        let end = remainder.range(of: "\n            }") ?? remainder.endIndex..<remainder.endIndex
        return String(remainder[..<end.lowerBound])
    }

    @Test
    func destructiveConfirmationIsNotTriggeredByReturn() throws {
        let modifiers = try cleanUpButtonModifiers()

        #expect(
            !modifiers.contains(".keyboardShortcut(.defaultAction)"),
            """
            The "Clean Up" confirmation must not be the default action. It is the only guard \
            before irreversible deletion, and providers using .permanentDelete do not route \
            through the Trash. With .defaultAction present, two Return presses delete files \
            without the confirmation ever being read.
            """
        )
    }

    @Test
    func cancelRemainsTheEscapeRouteOnTheConfirmation() throws {
        let source = Self.overviewViewSource
        let anchor = try #require(source.range(of: #"Button("Cancel", role: .cancel, action: cancel)"#))
        let remainder = source[anchor.upperBound...]
        let end = try #require(remainder.range(of: #"Button("Clean Up""#))

        #expect(
            remainder[..<end.lowerBound].contains(".keyboardShortcut(.cancelAction)"),
            "Cancel must keep .cancelAction so Escape dismisses the destructive confirmation."
        )
    }
}
