# Lightweight Reader engineering rules

- This is a **native macOS AppKit** project. The user's explicit platform choice overrides the Idea Lab default of UIKit and Mac Catalyst.
- Baseline: Xcode 27.0, Swift 6.4, macOS 13.0 deployment target. Guard newer APIs with availability checks.
- Keep a Clean MVVM flow for each reader screen: Model/UseCase, NSView, thin NSViewController, ViewState, and ViewAction. Views lay out and render; ViewModels own state changes; domain and data code do not import AppKit.
- Use constructor injection for dependencies. Keep UI changes on the main actor and file parsing off the main actor. Support cancellation when another file is opened or a tree node is collapsed.
- Do not load a large JSON document into a Swift dictionary, array, string, or text view. Index byte ranges lazily and limit both visible rows and cached nodes.
- JSON is read-only in version 1. Markdown editing and saving are required. Write saves atomically and surface errors.
- Use PDFKit for PDF display. Render GitHub-style Markdown safely, including tables, task lists, fenced code blocks, and local images.
- Support keyboard navigation, VoiceOver, window resizing, and Dynamic Type equivalents on macOS. Put user-visible strings in a String Catalog.
- Do not force unwrap, silently ignore errors, add fake functionality, or leave placeholders in a finished feature.
- Run an Xcode build after changes. XCTest coverage is optional; ask the user before adding tests.
- Do not create a Git commit unless the user explicitly asks. When authorized, use Conventional Commits and inspect the staged diff first.
