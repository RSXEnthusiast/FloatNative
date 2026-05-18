//
//  LossyArray.swift
//  FloatNative
//
//  Element-tolerant array decoder. When wrapped around an array of `Codable`
//  values, an element that fails to decode is logged and skipped instead of
//  dynamiting the whole response. The home feed uses this so a single
//  malformed post can't blank out the entire screen.
//

import Foundation

/// Property wrapper / standalone codable that decodes an array element-by-element,
/// dropping (and logging) anything that can't be decoded. The encoded form is
/// identical to `[Element]`.
@propertyWrapper
struct LossyArray<Element: Codable>: Codable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var results: [Element] = []
        results.reserveCapacity(container.count ?? 0)
        var index = 0
        while !container.isAtEnd {
            do {
                let element = try container.decode(Element.self)
                results.append(element)
            } catch {
                // Advance past the offending element and log it so the feed
                // continues rather than 500ing on a single bad post.
                _ = try? container.decode(JSONSkip.self)
                let summary = DecodingErrorFormatter.summary(error)
                DebugLogManager.shared.append(
                    .decode(
                        message: "skipped \(Element.self) at index \(index): \(summary)",
                        verbose: DecodingErrorFormatter.verbose(error)
                    )
                )
            }
            index += 1
        }
        self.wrappedValue = results
    }

    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

/// Throwaway type used to advance past an array element after a decode failure.
/// Decodes any single JSON value without keeping the result.
private struct JSONSkip: Decodable {
    init(from decoder: Decoder) throws {
        // singleValueContainer().decode(...) is enough to consume one element
        // for primitive cases; for objects/arrays we have to walk children to
        // make the underlying JSONDecoder advance the cursor.
        if let single = try? decoder.singleValueContainer() {
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Int.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            if (try? single.decode(String.self)) != nil { return }
            if single.decodeNil() { return }
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd {
                _ = try? unkeyed.decode(JSONSkip.self)
            }
            return
        }
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            for key in keyed.allKeys {
                _ = try? keyed.decode(JSONSkip.self, forKey: key)
            }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
