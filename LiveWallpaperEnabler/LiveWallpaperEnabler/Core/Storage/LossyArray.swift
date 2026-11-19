import Foundation

/// Decodes an array element by element: elements that fail to decode are kept verbatim in
/// `quarantined` instead of failing the whole array, so one bad record never takes the rest of
/// the library with it.
nonisolated struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var quarantined: [JSONValue] = []
    /// Decoding errors for the quarantined elements, for logging.
    var errors: [String] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                errors.append(String(describing: error))
                // The failed decode did not advance the container; consume the element as raw JSON.
                if let raw = try? container.decode(JSONValue.self) {
                    quarantined.append(raw)
                } else {
                    _ = try? container.decode(SkipElement.self)
                }
            }
        }
    }

    private struct SkipElement: Decodable {}
}

/// Minimal lossless JSON tree, used to keep records we could not decode.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
