//
//  Receipt.swift
//  ReceiptDecoder
//
//  Created by Antoine Palazzolo on 29/11/2019.
//  Copyright © 2019 Alpha Coders. All rights reserved.
//

import Foundation

public struct Receipt {
    public var bundleIdentifier: String //2
    public var appVersion: String //3
    public var originalAppVersion: String //19
    public var receiptCreationDate: Date //12 string RFC 3339 date
    public var receiptExpirationDate: Date? //21 string RFC 3339 date
    public var inAppPurchases: [InAppPurchase] // 17
    public init(receiptData: Data) throws {
        let decoder = DERDecoder()
        let content = try decoder.decode(data: receiptData)
        guard let contentData = content[1]?[0]?[.pkcs7Data]?[1]?[0]?.data else {
            let debugDescription = "PKSC7 content data not found"
            throw DERDecoder.DecodingError.valueNotFound(.init(debugDescription: debugDescription))
        }
        let appReceipt = try decoder.decode(data: contentData)
        let container = ReceiptFieldsContainer(nodes: appReceipt.children)
        self.bundleIdentifier = try container.string(identifier: 2)
        self.appVersion = try container.string(identifier: 3)
        self.originalAppVersion = try container.string(identifier: 19)
        self.receiptCreationDate = try container.date(identifier: 12)
        self.receiptExpirationDate = try container.dateIfPresent(identifier: 21)
        self.inAppPurchases = try container.fields(identifier: 17).map(InAppPurchase.init(field:))
    }
}
extension Receipt {
    public struct InAppPurchase {
        public var quantity: Int //1701
        public var productIdentifier: String //1702
        public var transactionIdentifier: String //1703
        public var originalTransactionIdentifier: String? //1705
        public var purchaseDate: Date // 1704 string RFC 3339 date
        public var originalPurchaseDate: Date? //1706 string RFC 3339 date
        public var subscriptionExpirationDate: Date? //1708 string RFC 3339 date
        public var isInIntroOfferPeriod: Bool? //1719 integer
        public var cancellationDate: Date? //1712 string RFC 3339 date
        public var webOrderLineItemId: Int64 //1711 integer
        fileprivate init(field: ReceiptFieldsContainer.Field) throws {
            let container = ReceiptFieldsContainer(nodes: field.content.children)
            self.quantity = try container.int(identifier: 1701)
            self.productIdentifier = try container.string(identifier: 1702)
            self.transactionIdentifier = try container.string(identifier: 1703)
            self.originalTransactionIdentifier = try container.stringIfPresent(identifier: 1705)
            self.purchaseDate = try container.date(identifier: 1704)
            self.originalPurchaseDate = try container.dateIfPresent(identifier: 1706)
            self.subscriptionExpirationDate = try container.dateIfPresent(identifier: 1708)
            self.isInIntroOfferPeriod = try container.intIfPresent(identifier: 1719).map({ $0 > 0 })
            self.cancellationDate = try container.dateIfPresent(identifier: 1712)
            self.webOrderLineItemId = try container.int64(identifier: 1711)
        }
    }
}

extension Receipt {
    private static let rfc3339DateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
        return dateFormatter
    }()
    fileprivate struct ReceiptFieldsContainer {
        struct Field {
            var identifier: Int
            var version: Int
            var content: ASN1Node
            init(node: ASN1Node) throws {
                let children = node.children
                if children.count < 3 {
                    let debug = "Invalid children count \(children.count) in receipt field"
                    throw DERDecoder.DecodingError.dataCorrupted(.init(debugDescription: debug))
                }
                self.identifier = try Int(children[0].decodeInt())
                self.version = try Int(children[1].decodeInt())
                let decoder = DERDecoder()
                let content = try decoder.decode(data: children[2].data)
                self.content = content
            }
        }
        private var content: [Int: [Field]]
        
        init(nodes: [ASN1Node]) {
            let receiptFields = nodes.compactMap { try? Field(node: $0) }
            self.content = Dictionary(grouping: receiptFields, by: { $0.identifier })
        }
        private func firstField(identifier: Int) throws -> Field {
            if let field = self.content[identifier]?.first {
                return field
            } else {
                let debug = "Field not found for identifier: \(identifier)"
                throw DERDecoder.DecodingError.valueNotFound(.init(debugDescription: debug))
            }
        }
        func string(identifier: Int) throws -> String {
            return try self.firstField(identifier: identifier).content.decodeString()
        }
        func stringIfPresent(identifier: Int) throws -> String? {
            return try self.content[identifier]?.first?.content.decodeString()
        }
        func int(identifier: Int) throws -> Int {
            return try Int(self.int64(identifier: identifier))
        }
        func intIfPresent(identifier: Int) throws -> Int? {
            return try self.int64IfPresent(identifier: identifier).map(Int.init)
        }
        func int64(identifier: Int) throws -> Int64 {
            return try self.firstField(identifier: identifier).content.decodeInt()
        }
        func int64IfPresent(identifier: Int) throws -> Int64? {
            return try self.content[identifier]?.first?.content.decodeInt()
        }
        func date(identifier: Int) throws -> Date {
            return try self.dateFromString(self.string(identifier: identifier))
        }
        func dateIfPresent(identifier: Int) throws -> Date? {
            if let string = try self.stringIfPresent(identifier: identifier), string.isEmpty == false {
                return try self.dateFromString(string)
            }
            return nil
        }
        private func dateFromString(_ string: String) throws -> Date {
            if let result = Receipt.rfc3339DateFormatter.date(from: string) {
                return result
            } else {
                let debug = "invalid date format: \(string)"
                throw DERDecoder.DecodingError.valueNotFound(.init(debugDescription: debug))
            }
        }
        func fields(identifier: Int) -> [Field] {
            return self.content[identifier] ?? []
        }
    }
}
