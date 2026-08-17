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

import LibP2P

internal class FrameEncoder: MessageToByteEncoder {
    public typealias OutboundIn = Frame

    public init() {}

    public func encode(data: Frame, out: inout ByteBuffer) throws {
        //print("Outbound Frame: \(data)")
        out.write(frame: data)
    }
}

internal final class FrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = Frame

    /// A header we've decoded and validated, but whose data payload hasn't fully
    /// arrived yet. Stored so we don't re-decode (or re-validate) it on the next call.
    private var header: Header? = nil

    /// The largest data-frame payload we'll accept from a peer.
    ///
    /// Yamux data frames are bounded by the receive window we advertise, so a frame
    /// declaring a larger length is either buggy or a memory-exhaustion attack: without
    /// this cap a peer could announce a ~4 GiB length and force us to buffer it. We
    /// reject such frames instead of waiting for bytes that shouldn't exist.
    private let maximumInboundFrameSize: UInt32

    public init(maximumInboundFrameSize: UInt32 = YAMUXHandler.initialWindowSize) {
        self.maximumInboundFrameSize = maximumInboundFrameSize
    }

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // If we're mid-frame waiting on a data payload, try to complete it. The header
        // was already decoded, validated, and size-checked when we stashed it.
        if let header = self.header {
            guard buffer.readableBytes >= header.length else {
                return .needMoreData
            }
            let payload = buffer.readSlice(length: Int(header.length))
            self.header = nil
            context.fireChannelRead(self.wrapInboundOut(Frame(header: header, payload: payload)))
            return .continue
        }

        // We need a full 12-byte header before we can decode anything.
        guard buffer.readableBytes >= 12 else {
            return .needMoreData
        }

        // Decode and validate the header
        // A malformed or spec-violating header is a hard error
        let header = try Header.decode(&buffer)
        try header.validate()

        // Only data frames carry a payload; everything else is header-only.
        guard header.messageType == .data else {
            context.fireChannelRead(self.wrapInboundOut(Frame(header: header, payload: nil)))
            return .continue
        }

        // Reject oversized data frames *before* buffering their payload.
        guard header.length <= self.maximumInboundFrameSize else {
            throw YAMUX.Error.frameTooLarge(length: header.length, maximum: self.maximumInboundFrameSize)
        }

        guard buffer.readableBytes >= header.length else {
            // Header is valid; stash it and wait for the payload to arrive.
            self.header = header
            return .needMoreData
        }

        let payload = buffer.readSlice(length: Int(header.length))
        context.fireChannelRead(self.wrapInboundOut(Frame(header: header, payload: payload)))
        return .continue
    }
}
