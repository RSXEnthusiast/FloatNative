//
//  DecodingErrorFormatter.swift
//  FloatNative
//
//  Turns Swift's opaque `DecodingError.localizedDescription` strings (e.g.
//  "The data couldn't be read because it is missing.") into something
//  diagnosable: full coding path, the offending key or type, and the schema
//  expectation. Used both for surfacing errors to users and for the in-app
//  debug log.
//

import Foundation

enum DecodingErrorFormatter {

    /// Render a Swift `DecodingError` (or any error) into a one-line summary.
    /// Safe to embed in user-facing toasts and crash reports.
    static func summary(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "missing value of type \(type) at \(path(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            return "data corrupted at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return decoding.localizedDescription
        }
    }

    /// Render every detail of a `DecodingError` for log files / debug screens.
    static func verbose(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            let ns = error as NSError
            return "\(error.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return [
                "Type: keyNotFound",
                "Path: \(path(context.codingPath))",
                "Missing key: \(key.stringValue)",
                "Debug: \(context.debugDescription)",
            ].joined(separator: "\n")
        case .valueNotFound(let type, let context):
            return [
                "Type: valueNotFound",
                "Path: \(path(context.codingPath))",
                "Expected type: \(type)",
                "Debug: \(context.debugDescription)",
            ].joined(separator: "\n")
        case .typeMismatch(let type, let context):
            return [
                "Type: typeMismatch",
                "Path: \(path(context.codingPath))",
                "Expected type: \(type)",
                "Debug: \(context.debugDescription)",
            ].joined(separator: "\n")
        case .dataCorrupted(let context):
            return [
                "Type: dataCorrupted",
                "Path: \(path(context.codingPath))",
                "Debug: \(context.debugDescription)",
            ].joined(separator: "\n")
        @unknown default:
            return decoding.localizedDescription
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        if keys.isEmpty { return "(root)" }
        return keys.map { key in
            if let intValue = key.intValue {
                return "[\(intValue)]"
            }
            return key.stringValue
        }.joined(separator: ".")
    }
}
