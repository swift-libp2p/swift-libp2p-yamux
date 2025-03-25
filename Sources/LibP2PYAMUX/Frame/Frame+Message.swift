//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2025 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import NIOCore

internal enum Message: Equatable, Comparable {
    // Stream I/O
    case data(payload: ByteBuffer)
    case windowUpdate(delta: UInt32)

    // Stream Control
    case newStream
    case opened
    case close
    case reset

    // Session Control
    case ping(payload: UInt32)
    case goAway(errorCode: NetworkError)

    var headerType: Header.MessageType? {
        switch self {
        case .data: .data
        case .windowUpdate: .windowUpdate
        case .newStream, .opened, .close, .reset: nil
        case .ping: .ping
        case .goAway: .goAway
        }
    }

    var flags: [Header.Flag] {
        switch self {
        case .data, .windowUpdate, .ping, .goAway: []
        case .newStream: [.syn]
        case .opened: [.ack]
        case .close: [.fin]
        case .reset: [.reset]
        }
    }

    var length: UInt32 {
        switch self {
        case .data(let payload): UInt32(payload.readableBytes)
        case .windowUpdate(let delta): delta
        case .newStream, .opened, .close, .reset: 0
        case .ping(let payload): payload
        case .goAway(let errorCode): errorCode.code
        }
    }

    private var rank: Int {
        switch self {
        case .newStream: 0
        case .opened: 1
        case .data: 2
        case .windowUpdate: 3
        case .ping: 4
        case .close: 5
        case .reset: 6
        case .goAway: 7
        }
    }
}

extension Message {
    static func < (lhs: Message, rhs: Message) -> Bool {
        lhs.rank < rhs.rank
    }
}

extension Array where Element == Message {
    init(frame: Frame) {
        self = []
        for flag in frame.header.flags {
            switch flag {
            case .syn:
                self.append(.newStream)
            case .ack:
                self.append(.opened)
            default:
                continue
            }
        }

        switch frame.header.messageType {
        case .data:
            self.append(.data(payload: frame.payload ?? ByteBuffer()))
        case .windowUpdate:
            self.append(.windowUpdate(delta: frame.header.length))
        case .ping:
            self.append(.ping(payload: frame.header.length))
        case .goAway:
            self.append(.goAway(errorCode: NetworkError(networkCode: Int(frame.header.length))))
        }

        for flag in frame.header.flags {
            switch flag {
            case .fin:
                self.append(.close)
            case .reset:
                self.append(.reset)
            default:
                continue
            }
        }
    }
}
