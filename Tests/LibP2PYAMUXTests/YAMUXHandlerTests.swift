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
import NIOEmbedded
import Testing

@testable import LibP2P
@testable import LibP2PYAMUX

@Suite("Handler Tests")
struct YAMUXHandlerTests {
    @Test func testHandlerInitializationOnAdd_WhenListener() async throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .inbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Activate the channel
        _ = try await channel.connect(to: .init(unixDomainSocketPath: "/foo"))

        // Add our handler to the already activated channel
        #expect(throws: Never.self) { try channel.pipeline.syncOperations.addHandler(handler) }
        // Yamux has no session-open handshake
        #expect(try channel.readOutbound(as: Frame.self) == nil)

        try await channel.close()
    }

    @Test func testHandlerInitializationOnAdd_WhenInitiator() async throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .outbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Activate the channel
        _ = try await channel.connect(to: .init(unixDomainSocketPath: "/foo"))

        // Add our handler to the already activated channel
        #expect(throws: Never.self) { try channel.pipeline.syncOperations.addHandler(handler) }
        // Yamux has no session-open handshake
        #expect(try channel.readOutbound(as: Frame.self) == nil)

        try await channel.close()
    }

    @Test func testHandlerInitializationActive_WhenListener() async throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .inbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Add our handler to the inactive channel
        #expect(throws: Never.self) { try channel.pipeline.syncOperations.addHandler(handler) }
        // Ensure we can't read
        #expect(try channel.readOutbound() == nil)

        // Activate the channel
        _ = try await channel.connect(to: .init(unixDomainSocketPath: "/foo"))
        // Yamux has no session-open handshake
        #expect(try channel.readOutbound(as: Frame.self) == nil)

        try await channel.close()
    }

    @Test func testHandlerInitializationActive_WhenInitiator() async throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .outbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Add our handler to the inactive channel
        #expect(throws: Never.self) { try channel.pipeline.syncOperations.addHandler(handler) }
        // Ensure we can't read
        #expect(try channel.readOutbound() == nil)

        // Activate the channel
        _ = try await channel.connect(to: .init(unixDomainSocketPath: "/foo"))
        // Yamux has no session-open handshake
        #expect(try channel.readOutbound(as: Frame.self) == nil)

        try await channel.close()
    }

    /// A full loop: initiator opens a stream, sends bytes, the listener accepts the
    /// inbound stream and echoes, and the initiator receives its bytes back — exercising
    /// SYN/ACK, data framing, flow-control windows, and read delivery across two muxers.
    @Test func testOpenStreamSendAndEcho() throws {
        let received = NIOLockedValueBox<[UInt8]>([])
        let acceptedInbound = NIOLockedValueBox(false)

        let listenerConnection = ConfigurableInboundConnection(direction: .inbound) { child in
            acceptedInbound.withLockedValue { $0 = true }
            return child.pipeline.addHandler(EchoHandler())
        }
        let initiatorConnection = try DummyConnection(peer: PeerID(.Ed25519), direction: .outbound)

        let listenerChannel = listenerConnection.channel as! EmbeddedChannel
        let initiatorChannel = initiatorConnection.channel as! EmbeddedChannel

        _ = try makeMuxer(on: listenerChannel, for: listenerConnection)
        let initiator = try makeMuxer(on: initiatorChannel, for: initiatorConnection)

        try listenerChannel.connect(to: .init(unixDomainSocketPath: "/listener")).wait()
        try initiatorChannel.connect(to: .init(unixDomainSocketPath: "/initiator")).wait()

        // Open an outbound stream, capturing anything the peer sends back on it.
        let streamPromise = initiatorChannel.eventLoop.makePromise(of: YAMUXStream.self)
        initiator.createChannel(streamPromise) { child in
            child.pipeline.addHandler(CaptureHandler(received))
        }

        // Pump the SYN/ACK handshake through.
        try interact(initiatorChannel, listenerChannel)

        let stream = try streamPromise.futureResult.wait()
        #expect(acceptedInbound.withLockedValue { $0 }, "Listener should have accepted the inbound stream.")

        // Send a request on the freshly-opened stream.
        var payload = initiatorChannel.allocator.buffer(capacity: 4)
        payload.writeString("ping")
        stream.channel.writeAndFlush(payload, promise: nil)

        // Pump data out and the echo back.
        try interact(initiatorChannel, listenerChannel)

        #expect(
            received.withLockedValue { $0 } == Array("ping".utf8),
            "The initiator should receive the bytes echoed by the listener."
        )
    }
}

extension YAMUXHandlerTests {

    /// A `DummyConnection` whose inbound child-channel initializer is supplied by the test
    /// (the stock one fails with `notImplementedYet`, which would reject every inbound stream).
    private final class ConfigurableInboundConnection: DummyConnection, @unchecked Sendable {
        private let onInbound: @Sendable (Channel) -> EventLoopFuture<Void>
        init(direction: ConnectionStats.Direction, onInbound: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) {
            self.onInbound = onInbound
            super.init(peer: nil, direction: direction)
        }
        override func inboundMuxedChildChannelInitializer(_ childChannel: Channel) -> EventLoopFuture<Void> {
            self.onInbound(childChannel)
        }
    }

    /// Captures every inbound `ByteBuffer` delivered to a child channel.
    private final class CaptureHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let received: NIOLockedValueBox<[UInt8]>
        init(_ received: NIOLockedValueBox<[UInt8]>) { self.received = received }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = self.unwrapInboundIn(data)
            self.received.withLockedValue { $0.append(contentsOf: buffer.readableBytesView) }
        }
    }

    /// Echoes every inbound `ByteBuffer` straight back out.
    private final class EchoHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = self.unwrapInboundIn(data)
            context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
        }
    }

    /// moves wire bytes back and forth between two muxer channels until both go quiet,
    /// running each embedded event loop so scheduled work (activation, initializers) fires.
    private func interact(_ a: EmbeddedChannel, _ b: EmbeddedChannel) throws {
        var progress = true
        var iterations = 0
        while progress {
            progress = false
            iterations += 1
            #expect(iterations < 1_000, "interaction pump failed to quiesce")
            (a.eventLoop as! EmbeddedEventLoop).run()
            (b.eventLoop as! EmbeddedEventLoop).run()
            if let outbound = try a.readOutbound(as: ByteBuffer.self) {
                try b.writeInbound(outbound)
                progress = true
            }
            if let outbound = try b.readOutbound(as: ByteBuffer.self) {
                try a.writeInbound(outbound)
                progress = true
            }
        }
    }

    private func makeMuxer(on channel: EmbeddedChannel, for connection: Connection) throws -> YAMUXHandler {
        let handler = YAMUXHandler(
            connection: connection,
            muxedPromise: channel.eventLoop.makePromise(of: Muxer.self),
            supportedProtocols: []
        )
        try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(FrameDecoder()),
            MessageToByteHandler(FrameEncoder()),
            handler,
        ])
        return handler
    }
}
