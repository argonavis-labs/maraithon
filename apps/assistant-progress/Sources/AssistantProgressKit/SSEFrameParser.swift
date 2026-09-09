import Foundation

/// Bounds memory before constructing Strings or decoding JSON, including when
/// a server sends a line without a newline. Handles CRLF and multi-line data.
struct SSEFrameParser {
    struct Frame { let event: String; let id: String?; let data: Data }
    private var line = Data()
    private var data = Data()
    private var event = "message"
    private var id: String?
    private var size = 0

    mutating func append(_ byte: UInt8) throws -> Frame? {
        size += 1
        guard size <= 4_000_000 else { throw AssistantProgressStream.Failure.frameTooLarge }
        guard byte == 10 else { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer { data.removeAll(keepingCapacity: true); event = "message"; id = nil; size = 0 }
            guard !data.isEmpty else { return nil }
            data.removeLast() // final SSE data newline
            return Frame(event: event, id: id, data: data)
        }
        guard line.first != 58 else { return nil }
        let split = line.firstIndex(of: 58) ?? line.endIndex
        let field = String(decoding: line[..<split], as: UTF8.self)
        var value = split == line.endIndex ? Data() : Data(line[line.index(after: split)...])
        if value.first == 32 { value.removeFirst() }
        switch field {
        case "event": event = String(decoding: value, as: UTF8.self)
        case "id": id = String(decoding: value, as: UTF8.self)
        case "data": data.append(value); data.append(10)
        default: break
        }
        return nil
    }
}
