// URL+Identifiable.swift
// Retroactive Identifiable conformance on URL.
// Required for .sheet(item:) presentation of file URLs (e.g. export files).

import Foundation

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
