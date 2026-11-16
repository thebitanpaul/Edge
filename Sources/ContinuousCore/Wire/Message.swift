import Foundation

public enum Wire {
    /// Bumped whenever the frame layout changes incompatibly.
    public static let protocolVersion: UInt16 = 1
    /// Frames larger than this are a bug or an attack; the link is dropped.
    public static let maxFrameSize: Int = 64 * 1024
    public static let nonceLength = 32
    public static let proofLength = 32
    /// Length of the derived PSK identifier that selects which pre-shared key a link uses.
    public static let keyIDLength = 8
}

public struct Capabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let pointer   = Capabilities(rawValue: 1 << 0)
    public static let keyboard  = Capabilities(rawValue: 1 << 1)
    public static let scroll    = Capabilities(rawValue: 1 << 2)
    public static let clipboard = Capabilities(rawValue: 1 << 3)

    public static let baseline: Capabilities = [.pointer, .keyboard, .scroll]
}

public enum MessageType: UInt8, Sendable {
    // session
    case hello        = 0x01
    case helloAck     = 0x02
    case authProof    = 0x03
    case ready        = 0x04
    case ping         = 0x05
    case pong         = 0x06
    case bye          = 0x07
    case failure      = 0x08
    // pointer
    case enterScreen  = 0x10
    case leaveScreen  = 0x11
    case mouseMove    = 0x12
    case mouseButton  = 0x13
    case scroll       = 0x14
    // keyboard
    case keyEvent     = 0x20
    case flagsChanged = 0x21
    // display
    case screenInfo   = 0x30
    // optional extras (M5)
    case clipboard    = 0x40
}

// MARK: - Payloads

public struct Display: Sendable, Equatable, Codable {
    public var x: Int32, y: Int32, width: Int32, height: Int32
    public var isMain: Bool
    public init(x: Int32, y: Int32, width: Int32, height: Int32, isMain: Bool) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.isMain = isMain
    }
}

public enum MouseButtonID: UInt8, Sendable {
    case left = 0, right = 1, middle = 2, other3 = 3, other4 = 4
}

public enum Message: Sendable {
    case hello(protocolVersion: UInt16, deviceID: DeviceID, deviceName: String,
               role: Role, capabilities: Capabilities, nonce: Data, keyID: Data)
    case helloAck(protocolVersion: UInt16, deviceID: DeviceID, deviceName: String,
                  capabilities: Capabilities, nonce: Data, proof: Data)
    case authProof(proof: Data)
    case ready
    case ping(seq: UInt32, sentAt: UInt64)
    case pong(seq: UInt32, sentAt: UInt64)
    case bye(reason: String)
    case failure(code: UInt16, message: String)

    case enterScreen(x: Int32, y: Int32, flags: UInt64)
    case leaveScreen
    case mouseMove(x: Int32, y: Int32, dx: Int32, dy: Int32)
    case mouseButton(button: MouseButtonID, down: Bool, clickCount: UInt8, x: Int32, y: Int32)
    case scroll(dx: Int32, dy: Int32, isPixel: Bool)

    case keyEvent(keyCode: UInt16, down: Bool, isRepeat: Bool, flags: UInt64)
    case flagsChanged(flags: UInt64)

    case screenInfo(displays: [Display])
    case clipboard(kind: String, payload: Data)

    public var type: MessageType {
        switch self {
        case .hello:        return .hello
        case .helloAck:     return .helloAck
        case .authProof:    return .authProof
        case .ready:        return .ready
        case .ping:         return .ping
        case .pong:         return .pong
        case .bye:          return .bye
        case .failure:      return .failure
        case .enterScreen:  return .enterScreen
        case .leaveScreen:  return .leaveScreen
        case .mouseMove:    return .mouseMove
        case .mouseButton:  return .mouseButton
        case .scroll:       return .scroll
        case .keyEvent:     return .keyEvent
        case .flagsChanged: return .flagsChanged
        case .screenInfo:   return .screenInfo
        case .clipboard:    return .clipboard
        }
    }
}

// MARK: - Codec

public enum Codec {
    public enum Failure: Error, CustomStringConvertible {
        case unknownType(UInt8)
        case oversizedFrame(Int)
        case malformed(MessageType, String)

        public var description: String {
            switch self {
            case .unknownType(let t):     return String(format: "unknown message type 0x%02X", t)
            case .oversizedFrame(let n):  return "frame of \(n) bytes exceeds the \(Wire.maxFrameSize) byte limit"
            case .malformed(let t, let d):return "malformed \(t) message: \(d)"
            }
        }
    }

    /// Encodes the payload only. Framing (`[u32 length][u8 type]`) is added by the link.
    public static func encodePayload(_ message: Message) -> Data {
        var w = BinaryWriter()
        switch message {
        case let .hello(v, id, name, role, caps, nonce, keyID):
            w.u16(v); w.blob(id.bytes); w.u8(role.rawValue); w.u32(caps.rawValue)
            w.blob(nonce); w.blob(keyID); w.string(name)

        case let .helloAck(v, id, name, caps, nonce, proof):
            w.u16(v); w.blob(id.bytes); w.u32(caps.rawValue)
            w.blob(nonce); w.blob(proof); w.string(name)

        case let .authProof(proof):
            w.blob(proof)

        case .ready, .leaveScreen:
            break

        case let .ping(seq, t), let .pong(seq, t):
            w.u32(seq); w.u64(t)

        case let .bye(reason):
            w.string(reason)

        case let .failure(code, msg):
            w.u16(code); w.string(msg)

        case let .enterScreen(x, y, flags):
            w.i32(x); w.i32(y); w.u64(flags)

        case let .mouseMove(x, y, dx, dy):
            w.i32(x); w.i32(y); w.i32(dx); w.i32(dy)

        case let .mouseButton(button, down, clicks, x, y):
            w.u8(button.rawValue); w.bool(down); w.u8(clicks); w.i32(x); w.i32(y)

        case let .scroll(dx, dy, isPixel):
            w.i32(dx); w.i32(dy); w.bool(isPixel)

        case let .keyEvent(code, down, isRepeat, flags):
            w.u16(code); w.bool(down); w.bool(isRepeat); w.u64(flags)

        case let .flagsChanged(flags):
            w.u64(flags)

        case let .screenInfo(displays):
            w.u8(UInt8(min(displays.count, 255)))
            for d in displays.prefix(255) {
                w.i32(d.x); w.i32(d.y); w.i32(d.width); w.i32(d.height); w.bool(d.isMain)
            }

        case let .clipboard(kind, payload):
            w.string(kind); w.u32(UInt32(payload.count)); w.blob(payload)
        }
        return w.data
    }

    public static func decode(type rawType: UInt8, payload: Data) throws -> Message {
        guard let type = MessageType(rawValue: rawType) else { throw Failure.unknownType(rawType) }
        var r = BinaryReader(payload)
        do {
            switch type {
            case .hello:
                let v = try r.u16()
                guard let id = DeviceID(bytes: try r.blob(16)) else {
                    throw BinaryReader.Failure.invalidValue("device id")
                }
                guard let role = Role(rawValue: try r.u8()) else {
                    throw BinaryReader.Failure.invalidValue("role")
                }
                let caps = Capabilities(rawValue: try r.u32())
                let nonce = try r.blob(Wire.nonceLength)
                let keyID = try r.blob(Wire.keyIDLength)
                let name = try r.string()
                return .hello(protocolVersion: v, deviceID: id, deviceName: name,
                              role: role, capabilities: caps, nonce: nonce, keyID: keyID)

            case .helloAck:
                let v = try r.u16()
                guard let id = DeviceID(bytes: try r.blob(16)) else {
                    throw BinaryReader.Failure.invalidValue("device id")
                }
                let caps = Capabilities(rawValue: try r.u32())
                let nonce = try r.blob(Wire.nonceLength)
                let proof = try r.blob(Wire.proofLength)
                let name = try r.string()
                return .helloAck(protocolVersion: v, deviceID: id, deviceName: name,
                                 capabilities: caps, nonce: nonce, proof: proof)

            case .authProof:
                return .authProof(proof: try r.blob(Wire.proofLength))

            case .ready:        return .ready
            case .leaveScreen:  return .leaveScreen

            case .ping:  return .ping(seq: try r.u32(), sentAt: try r.u64())
            case .pong:  return .pong(seq: try r.u32(), sentAt: try r.u64())
            case .bye:   return .bye(reason: try r.string())

            case .failure:
                return .failure(code: try r.u16(), message: try r.string())

            case .enterScreen:
                return .enterScreen(x: try r.i32(), y: try r.i32(), flags: try r.u64())

            case .mouseMove:
                return .mouseMove(x: try r.i32(), y: try r.i32(), dx: try r.i32(), dy: try r.i32())

            case .mouseButton:
                guard let b = MouseButtonID(rawValue: try r.u8()) else {
                    throw BinaryReader.Failure.invalidValue("mouse button")
                }
                return .mouseButton(button: b, down: try r.bool(), clickCount: try r.u8(),
                                    x: try r.i32(), y: try r.i32())

            case .scroll:
                return .scroll(dx: try r.i32(), dy: try r.i32(), isPixel: try r.bool())

            case .keyEvent:
                return .keyEvent(keyCode: try r.u16(), down: try r.bool(),
                                 isRepeat: try r.bool(), flags: try r.u64())

            case .flagsChanged:
                return .flagsChanged(flags: try r.u64())

            case .screenInfo:
                let n = Int(try r.u8())
                var displays: [Display] = []
                displays.reserveCapacity(n)
                for _ in 0..<n {
                    displays.append(Display(x: try r.i32(), y: try r.i32(),
                                            width: try r.i32(), height: try r.i32(),
                                            isMain: try r.bool()))
                }
                return .screenInfo(displays: displays)

            case .clipboard:
                let kind = try r.string()
                let n = Int(try r.u32())
                guard n <= Wire.maxFrameSize else { throw Failure.oversizedFrame(n) }
                return .clipboard(kind: kind, payload: try r.blob(n))
            }
        } catch let e as BinaryReader.Failure {
            throw Failure.malformed(type, e.description)
        }
    }

    /// Full frame: `[u32be payloadLength + 1][u8 type][payload]`
    public static func encodeFrame(_ message: Message) -> Data {
        let payload = encodePayload(message)
        var frame = Data(capacity: payload.count + 5)
        let len = UInt32(payload.count + 1)
        withUnsafeBytes(of: len.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(message.type.rawValue)
        frame.append(payload)
        return frame
    }
}
