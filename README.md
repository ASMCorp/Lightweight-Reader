# Lightweight Reader

A native macOS app for opening one local document at a time.

## Version 1 scope

- Read PDF files with page navigation, zoom, and search.
- Read and edit Markdown in a source editor with a GitHub-style preview.
  The preview supports tables, task lists, fenced code blocks, and local images.
- View JSON as an expandable tree. JSON is read-only in this version.
- Open another file in the same window, replacing the current document.
- Work entirely with local files. No account, cloud sync, or network dependency is required at runtime.

## Large JSON requirement

Opening a large JSON file must keep the window responsive. The implementation should map or stream the file, keep byte ranges instead of materializing the full object graph, and scan child nodes on demand in cancellable background work. The tree should display children in bounded pages and evict cached pages when memory pressure rises. Avoid passing the entire file to `JSONSerialization`, `JSONDecoder`, or a text view.

## Agent access

Build the app and companion command line tool with `xcodebuild -project LightweightReader.xcodeproj -scheme LightweightReader build` and `xcodebuild -project LightweightReader.xcodeproj -scheme reader-agent build`. The tool is named `reader-agent` in Xcode's build products.

The command line format is `reader-agent call OPERATION JSON_ARGUMENTS`. For example:

```sh
reader-agent call json_children '{"path":"/absolute/path/data.json","pointer":"/items","page":0}'
reader-agent call pdf_page_text '{"path":"/absolute/path/report.pdf","page":1,"offset":0}'
reader-agent call open_file '{"path":"/absolute/path/report.pdf"}'
```

The available operations are `open_file`, `document_info`, `pdf_page_text`, `json_children`, `json_value`, `markdown_text`, and `replace_markdown_range`. `open_file` asks the app containing `reader-agent`, or the sibling app in Xcode's build products, to open a document; pass `appPath` if the app is elsewhere. PDF text and Markdown text are returned in bounded excerpts with a `nextOffset` for reading more. JSON children are returned in pages of 100; locations use RFC 6901 JSON pointers. `json_value` returns metadata for containers and a bounded raw excerpt for scalar values. JSON is read only.

For a Markdown edit, first call `markdown_text` and keep its `sha256`. Then call `replace_markdown_range` with that hash, a character `offset` and `length`, and a `replacement` string. The tool rejects the write if the file changed, and saves atomically. The app applies the same conflict check when saving an open Markdown document.

Run `reader-agent mcp` as a local stdio MCP server. Configure an MCP client to launch the built executable with the single argument `mcp`. It exposes the seven operations as tools and read only document resource templates. File paths in resource URIs must be URL encoded. The server needs the same local file permissions as the process that launches it.

The macOS app also provides Shortcuts actions for opening a file by path, reading document information, reading a PDF page, listing JSON children, getting the current selection, going to a PDF page, and going to a JSON pointer. Its JSON tree exposes each visible node's pointer, type, and summary to accessibility clients.

## Installer DMG

Run `scripts/package-dmg.sh` on a Mac with Xcode 27 and XcodeGen. It builds a universal Release app for Apple silicon and Intel Macs, embeds `reader-agent` inside the app, and creates `dist/LightweightReader-1.0-macos-universal.dmg`. Users can open the DMG and drag the app to Applications without installing Xcode. The mounted DMG includes an Applications shortcut; agent setup instructions are inside the app bundle.

The installer uses a custom Finder window with a Retina background, a book icon, and positioned drag targets. The packaging script installs its pinned `dmgbuild` dependency into `build/packaging-venv`. Artwork sources are in `packaging/`; run `python3 packaging/generate_artwork.py` to regenerate them after design changes (requires Pillow).

The default build has an ad hoc signature. For distribution without a Gatekeeper warning, provide a Developer ID Application identity and a configured notarization profile when packaging:

```sh
SIGN_IDENTITY='Developer ID Application: Example Team (TEAMID)' NOTARY_PROFILE='your-notary-profile' scripts/package-dmg.sh
```

After installation, the agent executable is at `/Applications/Lightweight Reader.app/Contents/Helpers/reader-agent`.

## Project state

The repository contains a buildable native macOS Xcode starter. The reader features above are the product requirements for implementation. The project is intentionally separate from Idea Lab.

Generate the Xcode project with `xcodegen generate`. The pinned baseline is Xcode 27.0 / Swift 6.4, with macOS 13.0 as the deployment target.

## Suggested implementation order

1. Add a local file opening flow and one-document window state.
2. Integrate PDFKit for PDF reading.
3. Add Markdown editing, safe local preview, and atomic save.
4. Build the paged JSON index and lazy outline viewer.
5. Verify responsiveness and memory use with multi-gigabyte JSON fixtures, then add accessibility and polish.
