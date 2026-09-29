import Foundation

private let operations = [
    "open_file", "document_info", "pdf_page_text", "json_children", "json_value",
    "markdown_text", "replace_markdown_range"
]

private func schema(for name: String) -> [String: Any] {
    var properties: [String: Any] = ["path": ["type": "string", "description": "Absolute local file path"]]
    var required = ["path"]
    switch name {
    case "open_file":
        properties["appPath"] = ["type": "string", "description": "Optional path to LightweightReader.app"]
    case "pdf_page_text":
        properties["page"] = ["type": "integer", "minimum": 1]
        properties["offset"] = ["type": "integer", "minimum": 0]
        required.append("page")
    case "json_children":
        properties["pointer"] = ["type": "string", "description": "RFC 6901 JSON pointer; empty string is the root"]
        properties["page"] = ["type": "integer", "minimum": 0]
    case "json_value":
        properties["pointer"] = ["type": "string"]
    case "markdown_text":
        properties["offset"] = ["type": "integer", "minimum": 0]
    case "replace_markdown_range":
        properties["expectedSha256"] = ["type": "string"]
        properties["offset"] = ["type": "integer", "minimum": 0]
        properties["length"] = ["type": "integer", "minimum": 0]
        properties["replacement"] = ["type": "string"]
        required += ["expectedSha256", "offset", "length", "replacement"]
    default: break
    }
    return ["type": "object", "properties": properties, "required": required]
}

private func output(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

private func runCall(_ name: String, _ args: [String: Any]) -> [String: Any] {
    do {
        if name == "open_file" {
            guard let path = args["path"] as? String else { throw AgentDocumentError.missing("path") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            _ = try ReaderType(url: url)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AgentDocumentError.notFound }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let directory = executable.deletingLastPathComponent()
            let siblingApp = directory.appendingPathComponent("LightweightReader.app")
            let containingApp = directory.deletingLastPathComponent().deletingLastPathComponent()
            let defaultApp = containingApp.pathExtension == "app" ? containingApp : siblingApp
            let appPath = (args["appPath"] as? String) ?? defaultApp.path
            guard FileManager.default.fileExists(atPath: appPath) else { throw AgentDocumentError.invalid("appPath") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", appPath, url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw AgentDocumentError.invalid("app launch") }
            return ["result": ["path": url.path, "openRequested": true]]
        }
        return ["result": try AgentDocumentService().call(name, arguments: args)]
    }
    catch { return ["error": error.localizedDescription] }
}

private func serveMCP() {
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else { continue }
        let id = message["id"]
        if id == nil { continue }
        let parameters = message["params"] as? [String: Any] ?? [:]
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        switch method {
        case "initialize":
            response["result"] = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:], "resources": [:]],
                                  "serverInfo": ["name": "lightweight-reader", "version": "1.0.0"]]
        case "ping": response["result"] = [:]
        case "tools/list":
            response["result"] = ["tools": operations.map { name in
                ["name": name, "description": "Lightweight Reader \(name.replacingOccurrences(of: "_", with: " "))",
                 "inputSchema": schema(for: name)] as [String: Any]
            }]
        case "tools/call":
            let name = parameters["name"] as? String ?? ""
            let args = parameters["arguments"] as? [String: Any] ?? [:]
            let value = runCall(name, args)
            if let result = value["result"],
               let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let text = String(data: bytes, encoding: .utf8) {
                response["result"] = ["content": [["type": "text", "text": text]], "structuredContent": result]
            } else {
                response["result"] = ["content": [["type": "text", "text": value["error"] ?? "Unknown error"]], "isError": true]
            }
        case "resources/list":
            response["result"] = ["resources": []]
        case "resources/templates/list":
            response["result"] = ["resourceTemplates": [
                ["uriTemplate": "reader://document?path={path}", "name": "Document information", "mimeType": "application/json"],
                ["uriTemplate": "reader://pdf-page?path={path}&page={page}&offset={offset}", "name": "PDF page text", "mimeType": "application/json"],
                ["uriTemplate": "reader://json-children?path={path}&pointer={pointer}&page={page}", "name": "JSON children", "mimeType": "application/json"],
                ["uriTemplate": "reader://json-value?path={path}&pointer={pointer}", "name": "JSON value", "mimeType": "application/json"],
                ["uriTemplate": "reader://markdown?path={path}&offset={offset}", "name": "Markdown text", "mimeType": "application/json"]
            ]]
        case "resources/read":
            guard let uri = parameters["uri"] as? String,
                  let components = URLComponents(string: uri), components.scheme == "reader",
                  let host = components.host else {
                response["error"] = ["code": -32602, "message": "Invalid reader URI"]
                output(response)
                continue
            }
            let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            let operation: String
            switch host {
            case "document": operation = "document_info"
            case "pdf-page": operation = "pdf_page_text"
            case "json-children": operation = "json_children"
            case "json-value": operation = "json_value"
            case "markdown": operation = "markdown_text"
            default: operation = ""
            }
            var arguments: [String: Any] = query
            for key in ["page", "offset"] where query[key] != nil {
                guard let value = Int(query[key] ?? "") else { continue }
                arguments[key] = value
            }
            let value = runCall(operation, arguments)
            if let result = value["result"],
               let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let content = String(data: bytes, encoding: .utf8) {
                response["result"] = ["contents": [["uri": uri, "mimeType": "application/json", "text": content]]]
            } else {
                response["error"] = ["code": -32602, "message": value["error"] ?? "Resource unavailable"]
            }
        default:
            response["error"] = ["code": -32601, "message": "Method not found"]
        }
        output(response)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "mcp" {
    serveMCP()
} else if args.count == 3, args[0] == "call", let data = args[2].data(using: .utf8),
          let parameters = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let result = runCall(args[1], parameters)
    output(result)
    if result["error"] != nil { exit(1) }
} else {
    fputs("Usage: reader-agent call OPERATION JSON_ARGUMENTS | reader-agent mcp\n", stderr)
    exit(2)
}
