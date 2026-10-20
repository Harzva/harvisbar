import Foundation

public enum SOCKS5Error: Error, Equatable, Sendable {
    case incompleteFrame
    case unsupportedVersion(UInt8)
    case authenticationRequired(UInt8)
    case malformedFrame
    case invalidAddressLength(Int)
    case connectionRejected(UInt8)
}

public enum SOCKS5Address: Equatable, Sendable {
    case ipv4([UInt8])
    case domain(String)
    case ipv6([UInt8])
}

public enum ProxyDestinationPolicy {
    public static func shouldBypass(_ address: SOCKS5Address) -> Bool {
        switch address {
        case let .domain(host):
            let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return normalized == "localhost" || normalized.hasSuffix(".local")
        case let .ipv4(bytes):
            guard bytes.count == 4 else { return true }
            return bytes[0] == 10
                || bytes[0] == 127
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
        case let .ipv6(bytes):
            guard bytes.count == 16 else { return true }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            return isLoopback || isUniqueLocal || isLinkLocal
        }
    }
}

public struct SOCKS5Reply: Equatable, Sendable {
    public let boundAddress: SOCKS5Address
    public let boundPort: UInt16
    public let consumedByteCount: Int

    public init(boundAddress: SOCKS5Address, boundPort: UInt16, consumedByteCount: Int) {
        self.boundAddress = boundAddress
        self.boundPort = boundPort
        self.consumedByteCount = consumedByteCount
    }
}

public enum SOCKS5Protocol {
    public static let noAuthenticationGreeting = Data([0x05, 0x01, 0x00])

    public static func validateMethodSelection(_ data: Data) throws -> Int {
        guard data.count >= 2 else { throw SOCKS5Error.incompleteFrame }
        guard data[0] == 0x05 else { throw SOCKS5Error.unsupportedVersion(data[0]) }
        guard data[1] == 0x00 else { throw SOCKS5Error.authenticationRequired(data[1]) }
        return 2
    }

    public static func connectRequest(to address: SOCKS5Address, port: UInt16) throws -> Data {
        var bytes: [UInt8] = [0x05, 0x01, 0x00]
        switch address {
        case let .ipv4(octets):
            guard octets.count == 4 else { throw SOCKS5Error.invalidAddressLength(octets.count) }
            bytes.append(0x01)
            bytes.append(contentsOf: octets)
        case let .domain(host):
            let encoded = Array(host.utf8)
            guard !encoded.isEmpty, encoded.count <= 255 else {
                throw SOCKS5Error.invalidAddressLength(encoded.count)
            }
            bytes.append(0x03)
            bytes.append(UInt8(encoded.count))
            bytes.append(contentsOf: encoded)
        case let .ipv6(octets):
            guard octets.count == 16 else { throw SOCKS5Error.invalidAddressLength(octets.count) }
            bytes.append(0x04)
            bytes.append(contentsOf: octets)
        }
        bytes.append(UInt8(port >> 8))
        bytes.append(UInt8(port & 0xff))
        return Data(bytes)
    }

    public static func parseConnectReply(_ data: Data) throws -> SOCKS5Reply {
        guard data.count >= 4 else { throw SOCKS5Error.incompleteFrame }
        guard data[0] == 0x05 else { throw SOCKS5Error.unsupportedVersion(data[0]) }
        guard data[1] == 0x00 else { throw SOCKS5Error.connectionRejected(data[1]) }
        guard data[2] == 0x00 else { throw SOCKS5Error.malformedFrame }

        let address: SOCKS5Address
        let portOffset: Int
        switch data[3] {
        case 0x01:
            guard data.count >= 10 else { throw SOCKS5Error.incompleteFrame }
            address = .ipv4(Array(data[4..<8]))
            portOffset = 8
        case 0x03:
            guard data.count >= 5 else { throw SOCKS5Error.incompleteFrame }
            let length = Int(data[4])
            guard length > 0 else { throw SOCKS5Error.malformedFrame }
            portOffset = 5 + length
            guard data.count >= portOffset + 2 else { throw SOCKS5Error.incompleteFrame }
            guard let host = String(data: data[5..<portOffset], encoding: .utf8) else {
                throw SOCKS5Error.malformedFrame
            }
            address = .domain(host)
        case 0x04:
            guard data.count >= 22 else { throw SOCKS5Error.incompleteFrame }
            address = .ipv6(Array(data[4..<20]))
            portOffset = 20
        default:
            throw SOCKS5Error.malformedFrame
        }

        let port = (UInt16(data[portOffset]) << 8) | UInt16(data[portOffset + 1])
        return SOCKS5Reply(
            boundAddress: address,
            boundPort: port,
            consumedByteCount: portOffset + 2
        )
    }
}
