//
//  DERDecoder.swift
//  ReceiptDecoder
//
//  Created by Antoine Palazzolo on 29/11/2019.
//  Copyright © 2019 Alpha Coders. All rights reserved.
//

import Foundation

class DERDecoder {
    enum DecodingError: Error {
        struct Context {
            var debugDescription: String
        }
        case typeMismatch(Self.Context)
        case valueNotFound(Self.Context)
        case dataCorrupted(Self.Context)
    }
    func decode(data: Data) throws -> ASN1Node {
        return try self.decodeInternal(data: data).content
    }
    private func decodeInternal(data: Data) throws -> (content: ASN1Node, encodedSize: Int) {
        guard let firstByte = data.first else {
            throw DecodingError.dataCorrupted(.init(debugDescription: "first byte not found"))
        }
        let tagClass = TagClass(byte: firstByte)
        let encodingMethod = ContentEncodingMethod(byte: firstByte)
        let tagNumber = try TagNumber(bytes: data)
        let lenStartIndex = data.index(data.startIndex, offsetBy: tagNumber.encodedSize)
        let length = try Length(bytes: data.suffix(from: lenStartIndex))
        
        let headerSize = tagNumber.encodedSize + length.encodedSize
        switch encodingMethod {
        case .constructed:
            var contentList: [ASN1Node] = []
            var totalEncodedSize = 0
            while true {
                guard let contentStartIndex = data.index(data.startIndex, offsetBy: headerSize + totalEncodedSize,
                                                         limitedBy: data.endIndex) else {
                    let debug = "Construct content octets start index is greater than input size"
                    throw DecodingError.dataCorrupted(.init(debugDescription: debug))
                }
                let (content, encodedSize) = try self.decodeInternal(data: data.suffix(from: contentStartIndex))
                totalEncodedSize += encodedSize
                contentList.append(content)
                if let len = length.value {
                    if totalEncodedSize >= len {
                        break
                    }
                } else if content.tagClass == .universal,
                    let universalClassNumber = UniversalTagClassNumber(rawValue: content.number),
                    universalClassNumber == .endOfContent {
                    break
                }
            }
            let construct = Construct(number: tagNumber.value, tagClass: tagClass, content: contentList)
            return (construct, headerSize + totalEncodedSize)
        case .primitive:
            guard let len = length.value else {
                throw DecodingError.dataCorrupted(.init(debugDescription: "Primitive has indefinite size"))
            }
            guard let startIndex = data.index(data.startIndex, offsetBy: headerSize, limitedBy: data.endIndex) else {
                let debug = "Primitive content octets startIndex is greater than input size"
                throw DecodingError.dataCorrupted(.init(debugDescription: debug))
            }
            guard let endIndex = data.index(startIndex, offsetBy: len, limitedBy: data.endIndex) else {
                let debug = "Primitive content octets endIndex is greater than input size"
                throw DecodingError.dataCorrupted(.init(debugDescription: debug))
            }
            let data = data.subdata(in: startIndex..<endIndex)
            let primitive = Primitive(number: tagNumber.value, tagClass: tagClass, data: data)
            return (primitive, headerSize + len)
        }
    }
}

protocol ASN1Node: CustomStringConvertible {
    var number: UInt64 { get }
    var tagClass: DERDecoder.TagClass { get }
}
extension DERDecoder {
    fileprivate struct Primitive: ASN1Node, CustomStringConvertible {
        var number: UInt64
        var tagClass: TagClass
        var data: Data
        
        var description: String {
            return "Primitive: \(self.tagClass.descriptionWithNumber(self.number)) \(self.data)"
        }
        
    }
    fileprivate struct Construct: ASN1Node, CustomStringConvertible {
        var number: UInt64
        var tagClass: TagClass
        var content: [ASN1Node]
        var description: String {
            return "(Construct: \(self.tagClass.descriptionWithNumber(self.number))) -> \(self.content)"
        }
    }
}

extension ASN1Node {
    var universalTagClassNumber: DERDecoder.UniversalTagClassNumber? {
        switch self.tagClass {
        case .universal:
            return DERDecoder.UniversalTagClassNumber(rawValue: self.number)
        case .application, .private, .contextSpecific:
            return nil
        }
    }
    var children: [ASN1Node] {
        guard let construct = self as? DERDecoder.Construct else { return [] }
        return construct.content
    }
    subscript(key: DERDecoder.ObjectIdentifier) -> ASN1Node? {
        get {
            return self.children.first(where: {
                for content in $0.children {
                    return content.objectIdentifierValue == key
                }
                return false
            })
        }
    }
    subscript(index: Int) -> ASN1Node? {
        get {
            let children = self.children
            if children.indices.contains(index) {
                return children[index]
            }
            return nil
        }
    }
    var data: Data {
        guard let primitive = self as? DERDecoder.Primitive else { return Data() }
        return primitive.data
    }
    
    func decodeInt() throws -> Int64 {
        if self.universalTagClassNumber != .integer {
            let debug = "Not an integer: node is \(self.description)"
            throw DERDecoder.DecodingError.typeMismatch(.init(debugDescription: debug))
        }
        if self.data.count > MemoryLayout<Int64>.size {
            let debug = "Integer input size if too large (self.data.count)"
            throw DERDecoder.DecodingError.typeMismatch(.init(debugDescription: debug))
        }
        var result: Int64 = 0
        for (offset, value) in self.data.reversed().enumerated() {
            let bigComp = Int64(value) << (8*offset)
            result |= bigComp
        }
        return result.littleEndian
    }
    
    func decodeString() throws -> String {
        let decoded: String?
        switch self.universalTagClassNumber {
        case .utf8String:
            decoded = String(data: self.data, encoding: .utf8)
        case .ia5String:
            decoded = String(data: self.data, encoding: .ascii)
        default:
           let debug = "Not a String: node is \(self.description)"
            throw DERDecoder.DecodingError.typeMismatch(.init(debugDescription: debug))
        }
        if let result = decoded {
            return result
        } else {
            let debug = "invalid string encoding \(self)"
            throw DERDecoder.DecodingError.dataCorrupted(.init(debugDescription: debug))
        }
    }
    var objectIdentifierValue: DERDecoder.ObjectIdentifier? {
        if self.universalTagClassNumber != .objectIdentifier { return nil }
        return try? DERDecoder.ObjectIdentifier(self.data)
    }
}
extension DERDecoder {
    enum TagClass: UInt8, CaseIterable {
        case universal          = 0b00000000
        case application        = 0b01000000
        case contextSpecific    = 0b10000000
        case `private`          = 0b11000000
        
        private static let mask: UInt8 = 0b11000000
        
        func descriptionWithNumber(_ number: UInt64) -> String {
            switch self {
            case .universal:
                return UniversalTagClassNumber(rawValue: number)?.description ?? "invalid universal class"
            case .application:
                return "application(\(number))"
            case .private:
                return "private(\(number))"
            case .contextSpecific:
                return "contextSpecific(\(number))"
            }
        }
    }
}

extension DERDecoder.TagClass {
    fileprivate init(byte: UInt8) {
        let raw = byte & Self.mask
        self = Self.init(rawValue: raw)!
    }
}
extension DERDecoder {
    fileprivate enum ContentEncodingMethod: UInt8, CaseIterable {
        case primitive = 0b00000000
        case constructed = 0b00100000
        
        static let mask: UInt8 = 0b00100000
    }
}
extension DERDecoder.ContentEncodingMethod {
    fileprivate init(byte: UInt8) {
        let raw = byte & Self.mask
        self = Self.init(rawValue: raw)!
    }
}
extension DERDecoder {
    fileprivate struct TagNumber {
        var value: UInt64
        var encodedSize: Int
        static let firstOctetMask: UInt8 = 0b00011111
        static let longFormValueMarker: UInt8 = 0b00011111
        static let longFormValueMask: UInt8 = 0b01111111
        static let longFormMoreValueMask: UInt8 = 0b10000000
        static let longFormMoreValue: UInt8 = 0b10000000
        
        init<T: Sequence>(bytes: T) throws where T.Element == UInt8 {
            var iterator = bytes.makeIterator()
            guard let first = iterator.next() else {
                throw DecodingError.dataCorrupted(.init(debugDescription: "TagNumber first byte not found"))
            }
            let tag = first & Self.firstOctetMask
            if tag != Self.longFormValueMarker {
                self.value = UInt64(tag)
                self.encodedSize = 1
            } else {
                var components: [UInt8] = []
                while true {
                    guard let next = iterator.next() else {
                        let debug = "TagNumber number of components is greater than input data size"
                        throw DecodingError.dataCorrupted(.init(debugDescription: debug))
                    }
                    let tagComponent = next & Self.longFormValueMask
                    components.append(tagComponent)
                    if next & Self.longFormMoreValueMask != Self.longFormMoreValue {
                        break
                    }
                }
                self.encodedSize = components.count + 1
                self.value = try UInt64(sevenBytesComponents: components)
            }
        }
    }
}
extension DERDecoder {
    fileprivate struct Length {
        var value: Int?
        var encodedSize: Int
        static let firstOctetFormMask: UInt8 = 0b10000000
        static let firstOctetShortFormValue: UInt8 = 0b00000000
        static let firstOctetValueMask: UInt8 = 0b01111111
        static let firstOctetReservedValue: UInt8 = 0b01111111
        static let firstOctetIndefinitValue: UInt8 = 0b00000000

        init<T: Sequence>(bytes: T) throws where T.Element == UInt8 {
            var iterator = bytes.makeIterator()
            guard let first = iterator.next() else {
                throw DecodingError.dataCorrupted(.init(debugDescription: "Length first byte not found"))
            }
            let form = first & Self.firstOctetFormMask
            if form == Self.firstOctetShortFormValue {
                self.value = Int(first & Self.firstOctetValueMask)
                self.encodedSize = 1
            } else {
                let numberOfComponents = first & Self.firstOctetValueMask
                if numberOfComponents > MemoryLayout<UInt64>.size {
                    let debug = "Length number of components \(numberOfComponents) is greater than Int64 size"
                    throw DecodingError.dataCorrupted(.init(debugDescription: debug))
                }
                if numberOfComponents == Self.firstOctetIndefinitValue {
                    self.value = nil
                    self.encodedSize = 1
                } else if numberOfComponents == Self.firstOctetReservedValue {
                    throw DecodingError.dataCorrupted(.init(debugDescription: "Length number of components is reserved value"))
                } else {
                    var components: [UInt8] = []
                    for _ in 0..<numberOfComponents {
                        guard let next = iterator.next() else {
                            let debug = "Length number of components \(numberOfComponents) is greater than input data size"
                            throw DecodingError.dataCorrupted(.init(debugDescription: debug))
                        }
                        components.append(next)
                    }
                    self.encodedSize = components.count + 1
                    var result: UInt64 = 0
                    for (offset, component) in components.reversed().enumerated() {
                        let bigComp = UInt64(component) << (8*offset)
                        result |= bigComp
                    }
                    if let value = Int(exactly: result.littleEndian) {
                        self.value = value
                    } else {
                        let debug = "Lenght cannot be represented with an Int"
                        throw DecodingError.dataCorrupted(.init(debugDescription: debug))
                    }
                }
            }
        }
    }
}

extension DERDecoder {
    struct ObjectIdentifier: Equatable {
        var value: [UInt64]
        static let pkcs7Data                   = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 7, 1])
        static let pkcs7SignedData             = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 7, 2])
        static let pkcs7EnvelopedData          = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 7, 3])
        static let pkcs7SignedAndEnvelopedData = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 7, 4])
        static let pkcs7DigestedData           = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 7, 5])
        static let pkcs7EncryptedData          = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 7, 6])
        static let pkcs7AttributeContentType   = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 9, 3])
        static let pkcs7AttributeMessageDigest = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 9, 4])
        static let pkcs7AttributeSigningTime   = ObjectIdentifier(value: [1, 2, 840, 113549, 1, 9, 5])
    }
}

extension DERDecoder.ObjectIdentifier {
    static let valueMask: UInt8 = 0b01111111
    static let moreValueMask: UInt8 = 0b10000000
    static let moreValue: UInt8 = 0b10000000
    
    init(_ bytes: Data) throws {
        guard let first = bytes.first else {
            let debug = "Empty input data for ObjectIdentifier"
            throw DERDecoder.DecodingError.dataCorrupted(.init(debugDescription: debug))
        }
        var values = [UInt64(first/40), UInt64(first%40)]
        
        var currentComponents: [UInt8] = []
        for nextByte in bytes.dropFirst() {
            currentComponents.append(nextByte & Self.valueMask)
            if nextByte & Self.moreValueMask != Self.moreValue {
                try values.append(UInt64(sevenBytesComponents: currentComponents))
                currentComponents.removeAll()
            }
        }
        self.value = values
    }
}
extension DERDecoder {
    enum UniversalTagClassNumber: UInt64, CustomStringConvertible {
        case endOfContent = 0
        case boolean = 1
        case integer = 2
        case bitString = 3
        case octetString = 4
        case null = 5
        case objectIdentifier = 6
        case objectDescriptor = 7
        case external = 8
        case real = 9
        case enumerated = 10
        case embeddedPdv = 11
        case utf8String = 12
        case relativeOid = 13
        case time = 14
        case reserved = 15
        case sequence = 16
        case set = 17
        case NumericString = 18
        case PrintableString = 19
        case t61String = 20
        case videotexString = 21
        case ia5String = 22
        case utcTime = 23
        case generalizedTime = 24
        case graphicString = 25
        case visibleString = 26
        case generalString = 27
        case universalString = 28
        case characterString = 29
        case bmpString = 30
        case date = 31
        case timeOfDay = 32
        case dateTime = 33
        case duration = 34
        case oidIri = 35
        case relativeOidIri = 36
        
        var description: String {
            switch self {
            case .endOfContent: return "endOfContent"
            case .boolean: return "boolean"
            case .integer: return "integer"
            case .bitString: return "bitString"
            case .octetString: return "octetString"
            case .null: return "null"
            case .objectIdentifier: return "objectIdentifier"
            case .objectDescriptor: return "objectDescriptor"
            case .external: return "external"
            case .real: return "real"
            case .enumerated : return "enumerated"
            case .embeddedPdv : return "embeddedPdv"
            case .utf8String : return "utf8String"
            case .relativeOid : return "relativeOid"
            case .time : return "time"
            case .reserved : return "reserved"
            case .sequence : return "sequence"
            case .set : return "set"
            case .NumericString : return "NumericString"
            case .PrintableString : return "PrintableString"
            case .t61String : return "t61String"
            case .videotexString : return "videotexString"
            case .ia5String : return "ia5String"
            case .utcTime : return "utcTime"
            case .generalizedTime : return "generalizedTime"
            case .graphicString : return "graphicString"
            case .visibleString : return "visibleString"
            case .generalString : return "generalString"
            case .universalString : return "universalString"
            case .characterString : return "characterString"
            case .bmpString : return "bmpString"
            case .date : return "date"
            case .timeOfDay : return "timeOfDay"
            case .dateTime : return "dateTime"
            case .duration : return "duration"
            case .oidIri : return "oidIri"
            case .relativeOidIri: return "relativeOidIri"
            }
        }
    }
}

extension UInt64 {
    fileprivate init(sevenBytesComponents components: [UInt8]) throws {
        if 7*components.count > UInt64.bitWidth {
            let debug = "Number of components \(components) is greater than Int64 bit"
            throw DERDecoder.DecodingError.dataCorrupted(.init(debugDescription: debug))
        }
        var result: UInt64 = 0
        for (offset, component) in components.reversed().enumerated() {
            let bigComp = UInt64(component) << (7*offset)
            result |= bigComp
        }
        self = result.littleEndian
    }
    
}
