import Foundation
import Darwin

enum ControlActionError: Error, CustomStringConvertible {
    case badRequest(String)
    case notFound(String)
    case methodNotAllowed(String)
    case conflict(String)
    case internalError(String)

    var statusCode: Int {
        switch self {
        case .badRequest: return 400
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .conflict: return 409
        case .internalError: return 500
        }
    }

    var description: String {
        switch self {
        case .badRequest(let message), .notFound(let message), .methodNotAllowed(let message),
             .conflict(let message), .internalError(let message):
            return message
        }
    }
}

final class ControlServer {
    static let shared = ControlServer()
    private var listenFd: Int32 = -1
    private weak var owner: Controller?

    func start(owner: Controller) {
        guard listenFd < 0 else { return }
        self.owner = owner
        for port in 8883...8898 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                logLine("control: socket failed (errno \(errno))")
                return
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 && listen(fd, 16) == 0 {
                listenFd = fd
                writePortFile(port)
                logLine("control: listening on 127.0.0.1:\(port)")
                Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
                return
            }
            close(fd)
        }
        logLine("control: no port available from 8883 through 8898")
    }

    private func writePortFile(_ port: Int) {
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mantra", isDirectory: true)
                .appendingPathComponent("ports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\(port)".write(to: directory.appendingPathComponent("screen-copy"), atomically: true, encoding: .utf8)
        } catch {
            logLine("control: could not write port file: \(error)")
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while listenFd == fd {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if listenFd == fd { logLine("control: accept failed (errno \(errno))") }
                break
            }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        do {
            guard let request = try readRequest(fd) else { return }
            let response = try route(method: request.method, path: request.path, body: request.body)
            send(fd, status: response.status, object: response.object)
        } catch let error as ControlActionError {
            sendError(fd, status: error.statusCode, message: error.description)
        } catch {
            logLine("control: request failed: \(error)")
            sendError(fd, status: 500, message: "internal server error")
        }
    }

    private struct Request {
        let method: String
        let path: String
        let body: [String: Any]
    }

    private func readRequest(_ fd: Int32) throws -> Request? {
        var bytes = [UInt8]()
        var headerEnd: Int?
        var buffer = [UInt8](repeating: 0, count: 4096)
        while headerEnd == nil {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, 0) }
            if count <= 0 || bytes.count + count > 65536 { return nil }
            bytes.append(contentsOf: buffer[0..<count])
            if bytes.count >= 4 {
                for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
                    headerEnd = i + 4
                    break
                }
            }
        }
        guard let end = headerEnd else { throw ControlActionError.badRequest("invalid HTTP headers") }
        let header = String(decoding: bytes[..<end], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ControlActionError.badRequest("missing request line") }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { throw ControlActionError.badRequest("invalid request line") }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= 1_048_576 else {
            throw ControlActionError.badRequest("invalid or oversized Content-Length")
        }
        var body = Array(bytes[end...])
        while body.count < length {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, min($0.count, length - body.count), 0) }
            if count <= 0 { return nil }
            body.append(contentsOf: buffer[0..<count])
        }
        if body.count > length { body = Array(body.prefix(length)) }

        let object: Any?
        if body.isEmpty {
            object = [String: Any]()
        } else {
            object = try? JSONSerialization.jsonObject(with: Data(body), options: [])
        }
        guard let dictionary = object as? [String: Any] else {
            throw ControlActionError.badRequest("body must be a JSON object")
        }
        return Request(method: method, path: path, body: dictionary)
    }

    private struct Response {
        let status: Int
        let object: Any
    }

    private func route(method: String, path: String, body: [String: Any]) throws -> Response {
        guard let controller = owner else {
            throw ControlActionError.internalError("app controller is unavailable")
        }
        var result: [String: Any] = [:]
        var state: Any?
        var isGet = false

        if method == "GET" {
            isGet = true
            switch path {
            case "/tabs":
                state = DispatchQueue.main.sync { controller.controlTabs() }
            case "/status":
                state = DispatchQueue.main.sync { controller.recordStatusEntries() }
            default:
                if ["/record/start", "/record/pause", "/record/resume", "/record/stop", "/record/next",
                    "/record/rename", "/record/monitor", "/tab/select", "/tap", "/key", "/text"].contains(path) {
                    throw ControlActionError.methodNotAllowed("endpoint requires POST")
                }
                throw ControlActionError.notFound("unknown endpoint")
            }
        } else if method == "POST" {
            switch path {
            case "/record/start":
                let index = try targetTab(body, controller: controller)
                let name = try requiredString("name", body)
                result["recording"] = try DispatchQueue.main.sync { try controller.recordStart(tab: index, name: name) }
            case "/record/pause":
                let index = try targetTab(body, controller: controller)
                result["recording"] = try DispatchQueue.main.sync { try controller.recordPause(tab: index) }
            case "/record/resume":
                let index = try targetTab(body, controller: controller)
                result["recording"] = try DispatchQueue.main.sync { try controller.recordResume(tab: index) }
            case "/record/stop":
                let index = try targetTab(body, controller: controller)
                result["recording"] = try DispatchQueue.main.sync { try controller.recordStop(tab: index) }
            case "/record/next":
                let index = try targetTab(body, controller: controller)
                let name = try optionalString("name", body)
                result["recording"] = try DispatchQueue.main.sync { try controller.recordNext(tab: index, name: name) }
            case "/record/rename":
                let index = try targetTab(body, controller: controller)
                let from = try requiredString("from", body)
                let to = try requiredString("to", body)
                result["recording"] = try DispatchQueue.main.sync { try controller.recordRename(tab: index, from: from, to: to) }
            case "/record/monitor":
                let index = try targetTab(body, controller: controller)
                guard let on = body["on"] as? Bool else {
                    throw ControlActionError.badRequest("on must be true or false")
                }
                result["recording"] = try DispatchQueue.main.sync { try controller.recordMonitor(tab: index, on: on) }
            case "/tab/select":
                guard let number = body["tab"] as? Int, number > 0 else {
                    throw ControlActionError.badRequest("tab must be a positive 1-based integer")
                }
                result["tabs"] = try DispatchQueue.main.sync {
                    guard controller.tabs.indices.contains(number - 1) else {
                        throw ControlActionError.notFound("unknown tab \(number)")
                    }
                    controller.select(number - 1)
                    return controller.controlTabs()
                }
            case "/tap":
                let index = DispatchQueue.main.sync {
                    controller.tabs.indices.contains(controller.active) ? controller.active : -1
                }
                let x = try requiredInt("x", body)
                let y = try requiredInt("y", body)
                result["input"] = try DispatchQueue.main.sync { try controller.controlTap(tab: index, x: x, y: y) }
            case "/key":
                let index = DispatchQueue.main.sync {
                    controller.tabs.indices.contains(controller.active) ? controller.active : -1
                }
                let code = try requiredInt("code", body)
                result["input"] = try DispatchQueue.main.sync { try controller.controlKey(tab: index, code: code) }
            case "/text":
                let index = DispatchQueue.main.sync {
                    controller.tabs.indices.contains(controller.active) ? controller.active : -1
                }
                let text = try requiredString("text", body)
                result["input"] = try DispatchQueue.main.sync { try controller.controlText(tab: index, text: text) }
            default:
                if path == "/tabs" || path == "/status" {
                    throw ControlActionError.methodNotAllowed("endpoint requires GET")
                }
                throw ControlActionError.notFound("unknown endpoint")
            }
            result["ok"] = true
            result["status"] = DispatchQueue.main.sync { controller.recordStatusEntries() }
        } else {
            throw ControlActionError.methodNotAllowed("only GET and POST are supported")
        }

        if isGet, let state = state { return Response(status: 200, object: state) }
        return Response(status: 200, object: result)
    }

    private func targetTab(_ body: [String: Any], controller: Controller) throws -> Int {
        let hasTab = body["tab"] != nil
        let hasSerial = body["serial"] != nil
        if hasTab && hasSerial { throw ControlActionError.badRequest("provide tab or serial, not both") }
        if let tab = body["tab"] {
            guard let number = tab as? Int, number > 0 else {
                throw ControlActionError.badRequest("tab must be a positive 1-based integer")
            }
            return try DispatchQueue.main.sync {
                guard controller.tabs.indices.contains(number - 1) else {
                    throw ControlActionError.notFound("unknown tab \(number)")
                }
                return number - 1
            }
        }
        if let value = body["serial"] {
            guard let serial = value as? String, !serial.isEmpty else {
                throw ControlActionError.badRequest("serial must be a non-empty string")
            }
            return try DispatchQueue.main.sync {
                guard let index = controller.tabs.firstIndex(where: { $0.session.serial == serial }) else {
                    throw ControlActionError.notFound("unknown serial \(serial)")
                }
                return index
            }
        }
        return try DispatchQueue.main.sync {
            guard controller.tabs.indices.contains(controller.active) else {
                throw ControlActionError.notFound("there is no active tab")
            }
            return controller.active
        }
    }

    private func requiredString(_ key: String, _ body: [String: Any]) throws -> String {
        guard let value = body[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlActionError.badRequest("\(key) must be a non-empty string")
        }
        return value
    }

    private func optionalString(_ key: String, _ body: [String: Any]) throws -> String? {
        guard let value = body[key] else { return nil }
        guard let string = value as? String else {
            throw ControlActionError.badRequest("\(key) must be a string")
        }
        return string
    }

    private func requiredInt(_ key: String, _ body: [String: Any]) throws -> Int {
        guard let value = body[key] as? Int else {
            throw ControlActionError.badRequest("\(key) must be an integer")
        }
        return value
    }

    private func sendError(_ fd: Int32, status: Int, message: String) {
        send(fd, status: status, object: ["ok": false, "error": message])
    }

    private func send(_ fd: Int32, status: Int, object: Any) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object)
        } catch {
            logLine("control: JSON response failed: \(error)")
            data = Data(#"{"ok":false,"error":"response serialization failed"}"#.utf8)
        }
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        case 409: phrase = "Conflict"
        default: phrase = "Internal Server Error"
        }
        var response = Data("HTTP/1.1 \(status) \(phrase)\r\n".utf8)
        response.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        response.append(Data("Content-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8))
        response.append(data)
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if count <= 0 { break }
                offset += count
            }
        }
    }
}
