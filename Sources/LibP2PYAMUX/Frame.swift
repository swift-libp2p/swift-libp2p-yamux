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

struct Frame {
    private(set) var header: Header
    var payload: ByteBuffer?

    var messages: [Message] {
        [Message](frame: self).sorted()
    }
}

extension Frame {
    init(streamID: UInt32, message: Message, additionalFlags: [Header.Flag] = []) throws {
        guard let msgType = message.headerType else {
            throw YamuxError.frameDecodingError
        }

        self.header = Header(
            version: .v0,
            messageType: msgType,
            flags: Set(message.flags + additionalFlags),
            streamID: streamID,
            length: message.length
        )

        if case .data(let payload) = message {
            self.payload = payload
        }
    }
}

extension Frame {
    mutating func addFlag(_ flag: Header.Flag) {
        self.header.addFlag(flag)
    }
}

extension ByteBuffer {
    mutating func write(frame: Frame) {
        self.write(header: frame.header)
        if var payload = frame.payload {
            self.writeBuffer(&payload)
        }
    }

    /// Reads in a YAMUX Frame
    /// If the frame includes a payload, it reads in and populates the payload param
    /// If theres insufficient readable bytes for the payload, we reset the reader index to BEFORE the header.
    mutating func readFrame() throws -> Frame {
        let readerIndex = self.readerIndex

        let header = try Header(buffer: &self)
        var payload: ByteBuffer? = nil

        if header.messageType == .data {
            guard let data = self.readSlice(length: Int(header.length)) else {
                self.moveReaderIndex(to: readerIndex)
                throw YamuxError.frameDecodingError
            }
            payload = data
        }
        return Frame(header: header, payload: payload)
    }
}
