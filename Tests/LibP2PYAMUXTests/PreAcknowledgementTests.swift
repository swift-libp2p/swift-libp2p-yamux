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

/// Regression tests for traffic that arrives on a stream *before* the peer's `ACK`.
///
/// In yamux the ACK flag is informational, it exists so a peer can bound the number of
/// unacknowledged streams, and nothing requires it to precede data on the stream. Real peers
/// attach it to the first frame they happen to send, which can be *after* the first data frame
/// they send us. Rejecting pre-ACK traffic tore down every such stream, and (because the failed
/// child stayed registered) the peer's late ACK then produced a second, spurious violation...
///
/// ```
/// YAMUX=Child[1][OUT] protocolViolation: Received channel data before channel was open.
/// YAMUX=Child[1][OUT] protocolViolation: Duplicate open confirmation received.
/// ```
@Suite("Pre-Acknowledgement Traffic Tests")
struct PreAcknowledgementTests {

    static let window: UInt32 = 1024 * 256

    // MARK: - State machine: locally-opened streams (we SYN'd, no ACK yet)

    /// A peer that answers before it acknowledges.
    @Test func testInboundDataBeforeAckIsAccepted() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)

        #expect(throws: Never.self, "Yamux does not require an ACK before data.") {
            try sm.receiveChannelData(.init(recipientChannel: 1, data: Self.payload()))
        }
    }

    /// Data must not silently advance the stream, the ACK that follows is still the real one.
    @Test func testAckArrivingAfterDataIsProcessed() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)
        try sm.receiveChannelData(.init(recipientChannel: 1, data: Self.payload()))

        let action = try sm.receiveChannelOpenConfirmation(Self.ack(1))

        #expect(action == .process, "The first ACK is still the one that opens the stream.")
        #expect(sm.isActiveOnChannel)
    }

    /// A stream we've SYN'd is already active on the channel, otherwise `tryToRead` would sit on
    /// pre-ACK data that the pipeline (activated when the SYN went out) is waiting for.
    @Test func testLocallyRequestedStreamIsActiveOnChannel() throws {
        let sm = Self.makeLocallyRequestedChannel(id: 1)
        #expect(sm.isActiveOnChannel, "We fire channelActive on SYN, so reads must be deliverable.")
    }

    /// A second ACK is ignored, not a violation.
    @Test func testDuplicateAckIsIgnored() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)
        #expect(try sm.receiveChannelOpenConfirmation(Self.ack(1)) == .process)
        #expect(try sm.receiveChannelOpenConfirmation(Self.ack(1)) == .ignore)
    }

    @Test func testAckArrivingAfterWeClosedIsIgnored() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)
        try sm.sendChannelClose(.init(recipientChannel: 1))

        #expect(try sm.receiveChannelOpenConfirmation(Self.ack(1)) == .ignore)
    }

    @Test func testInboundWindowUpdateBeforeAckIsAccepted() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)

        #expect(throws: Never.self) {
            try sm.receiveChannelWindowAdjust(.init(recipientChannel: 1, bytesToAdd: Self.window))
        }
    }

    /// The peer half-closes its write side without ever having ACKed, our write side stays open.
    @Test func testInboundCloseBeforeAckIsAccepted() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)

        #expect(throws: Never.self) {
            try sm.receiveChannelClose(.init(recipientChannel: 1))
        }
        #expect(!sm.isClosed, "A FIN from the peer half-closes; it must not close the stream outright.")
        #expect(!sm.sentClose, "Our write side is still open, so we can still answer.")
    }

    // MARK: - State machine: remotely-opened streams (peer SYN'd, we haven't ACKed yet)

    /// `SYN` + request + `FIN` in a single read burst is what a one-shot request looks like on the
    /// wire. If the child channel's initializer hasn't finished, our ACK hasn't gone out yet, and
    /// all three of these land while the stream is still `.requestedRemotely`.
    @Test func testSynDataFinBurstBeforeOurAckIsAccepted() throws {
        var sm = ChildChannelStateMachine(localChannelID: 2)
        sm.receiveChannelOpen(.init(senderChannel: 2, initialWindowSize: Self.window, maximumPacketSize: Self.window))

        #expect(throws: Never.self) {
            try sm.receiveChannelWindowAdjust(.init(recipientChannel: 2, bytesToAdd: Self.window))
            try sm.receiveChannelData(.init(recipientChannel: 2, data: Self.payload()))
            try sm.receiveChannelClose(.init(recipientChannel: 2))
        }

        // We still owe the peer its ACK, and sending it must remain legal, this used to be a
        // `preconditionFailure` (a crash, not an error) once the FIN had been processed.
        sm.sendChannelOpenConfirmation(Self.ack(2))
        #expect(!sm.sentClose, "Our write side stays open so the application can still respond.")
    }

    /// A peer that opens and immediately resets.
    @Test func testInboundResetBeforeOurAckIsAccepted() throws {
        var sm = ChildChannelStateMachine(localChannelID: 2)
        sm.receiveChannelOpen(.init(senderChannel: 2, initialWindowSize: Self.window, maximumPacketSize: Self.window))

        #expect(throws: Never.self) {
            try sm.receiveChannelReset(.init(recipientChannel: 2, reasonCode: 0, description: "Stream Reset"))
        }
        #expect(sm.isClosed, "A reset is terminal.")
    }

    // MARK: - State machine: genuine violations must still be rejected

    @Test func testDataAfterRemoteFinIsStillRejected() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)
        try sm.receiveChannelClose(.init(recipientChannel: 1))

        #expect(throws: YAMUX.Error.self, "Data after the peer's FIN is a real violation.") {
            try sm.receiveChannelData(.init(recipientChannel: 1, data: Self.payload()))
        }
    }

    @Test func testDataOnIdleStreamIsStillRejected() throws {
        var sm = ChildChannelStateMachine(localChannelID: 1)

        #expect(throws: YAMUX.Error.self, "Nothing is on the wire yet, data for this id is bogus.") {
            try sm.receiveChannelData(.init(recipientChannel: 1, data: Self.payload()))
        }
    }

    @Test func testAckOnRemotelyOpenedStreamIsStillRejected() throws {
        var sm = ChildChannelStateMachine(localChannelID: 2)
        sm.receiveChannelOpen(.init(senderChannel: 2, initialWindowSize: Self.window, maximumPacketSize: Self.window))

        #expect(throws: YAMUX.Error.self, "The peer cannot acknowledge a stream it opened itself.") {
            try sm.receiveChannelOpenConfirmation(Self.ack(2))
        }
    }

    // MARK: - Multiplexer: late frames for streams that are gone

    /// Frames for an id we don't hold are dropped, not errored.
    @Test func testFramesForUnknownStreamAreDropped() throws {
        let harness = try MultiplexerHarness()
        defer { harness.tearDown() }

        #expect(throws: Never.self) {
            try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 99, data: Self.payload())))
            try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 99)))
            try harness.multiplexer.receiveMessage(.channelWindowAdjust(.init(recipientChannel: 99, bytesToAdd: 256)))
            try harness.multiplexer.receiveMessage(.channelOpenConfirmation(Self.ack(99)))
            try harness.multiplexer.receiveMessage(
                .channelReset(.init(recipientChannel: 99, reasonCode: 0, description: "Stream Reset"))
            )
        }
    }

    /// A reset stream must leave the registry immediately. While removal was deferred to the next
    /// event-loop tick, the rest of the parent's read burst kept being routed into the closed child.
    @Test func testResetStreamIsDeregisteredSynchronously() throws {
        let harness = try MultiplexerHarness()
        defer { harness.tearDown() }

        try harness.openInboundStream(id: 1)
        #expect(harness.multiplexer.channels[1] != nil)

        try harness.multiplexer.receiveMessage(
            .channelReset(.init(recipientChannel: 1, reasonCode: 0, description: "Stream Reset"))
        )

        #expect(
            harness.multiplexer.channels[1] == nil,
            "A reset stream must be deregistered before the next frame is routed, not a tick later."
        )
        // And the peer's in-flight leftovers for that id are now harmless.
        #expect(throws: Never.self) {
            try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 1)))
            try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 1, data: Self.payload())))
        }
    }

    /// Same requirement for a stream we tear down because of a real protocol violation, the very
    /// next frame in the burst must not be delivered to the closed child.
    @Test func testErroredStreamIsDeregisteredSynchronously() throws {
        let harness = try MultiplexerHarness()
        defer { harness.tearDown() }

        try harness.openInboundStream(id: 1)
        // Peer half-closes, then sends data anyway, a genuine violation that errors the child.
        try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 1)))
        try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 1, data: Self.payload())))

        #expect(
            harness.multiplexer.channels[1] == nil,
            "An errored stream must be deregistered immediately so later frames in the burst are dropped."
        )
        #expect(throws: Never.self) {
            try harness.multiplexer.receiveMessage(.channelOpenConfirmation(Self.ack(1)))
        }
    }

    // MARK: - End to end

    /// Open an outbound stream, then hand the muxer a bare `DATA` frame (no ACK) followed by
    /// the ACK on a later frame. The bytes must reach the stream's handler and nothing may be
    /// reported as an error.
    @Test func testDataBeforeAckIsDeliveredToTheStream() throws {
        let received = NIOLockedValueBox<[UInt8]>([])
        let errors = NIOLockedValueBox<[String]>([])

        let connection = try DummyConnection(peer: PeerID(.Ed25519), direction: .outbound)
        let channel = connection.channel as! EmbeddedChannel
        let muxer = YAMUXHandler(
            connection: connection,
            muxedPromise: channel.eventLoop.makePromise(of: Muxer.self),
            supportedProtocols: []
        )
        try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(FrameDecoder()),
            MessageToByteHandler(FrameEncoder()),
            muxer,
        ])
        try channel.connect(to: .init(unixDomainSocketPath: "/initiator")).wait()

        let streamPromise = channel.eventLoop.makePromise(of: YAMUXStream.self)
        muxer.createChannel(streamPromise) { child in
            child.pipeline.addHandlers([Recorder(received: received, errors: errors)])
        }
        (channel.eventLoop as! EmbeddedEventLoop).run()

        // Our SYN is on the wire, drain it so we can see what the stream produces later.
        while try channel.readOutbound(as: ByteBuffer.self) != nil {}
        let stream = try streamPromise.futureResult.wait()

        // The peer answers before it acknowledges, a bare data frame, no flags.
        try channel.writeInbound(Self.encode(Self.dataFrame(streamID: 1, payload: "response", flags: []), on: channel))
        (channel.eventLoop as! EmbeddedEventLoop).run()

        #expect(
            received.withLockedValue { $0 } == Array("response".utf8),
            "Data that arrives before the peer's ACK must still be delivered to the stream."
        )
        #expect(errors.withLockedValue { $0 }.isEmpty, "Pre-ACK data is legal: \(errors.withLockedValue { $0 })")
        #expect(stream.channel.isActive)

        // Now the ACK turns up, on a later frame, still legal, still not an error.
        try channel.writeInbound(
            Self.encode(
                Frame(header: .init(version: .v0, messageType: .windowUpdate, flags: [.ack], streamID: 1, length: 0)),
                on: channel
            )
        )
        (channel.eventLoop as! EmbeddedEventLoop).run()

        #expect(errors.withLockedValue { $0 }.isEmpty, "A late ACK is informational: \(errors.withLockedValue { $0 })")
        #expect(stream.channel.isActive, "The stream must survive an ACK that arrives behind the data.")

        // A second data frame is accepted.
        try channel.writeInbound(Self.encode(Self.dataFrame(streamID: 1, payload: "!", flags: []), on: channel))
        (channel.eventLoop as! EmbeddedEventLoop).run()
        #expect(received.withLockedValue { $0 } == Array("response!".utf8))
    }
}

// MARK: - Helpers

extension PreAcknowledgementTests {

    /// A state machine for a stream we've opened but that the peer hasn't ACKed yet.
    fileprivate static func makeLocallyRequestedChannel(id: UInt32) -> ChildChannelStateMachine {
        var sm = ChildChannelStateMachine(localChannelID: id)
        sm.sendChannelOpen(.init(senderChannel: id, initialWindowSize: window, maximumPacketSize: window))
        return sm
    }

    fileprivate static func ack(_ id: UInt32) -> LibP2PYAMUX.Message.ChannelOpenConfirmationMessage {
        .init(recipientChannel: id, senderChannel: id, initialWindowSize: window, maximumPacketSize: window)
    }

    fileprivate static func payload(_ string: String = "hello") -> ByteBuffer {
        ByteBuffer(string: string)
    }

    fileprivate static func dataFrame(streamID: UInt32, payload: String, flags: Set<Header.Flag>) -> Frame {
        let buffer = ByteBuffer(string: payload)
        return Frame(
            header: .init(
                version: .v0,
                messageType: .data,
                flags: flags,
                streamID: streamID,
                length: UInt32(buffer.readableBytes)
            ),
            payload: buffer
        )
    }

    fileprivate static func encode(_ frame: Frame, on channel: Channel) -> ByteBuffer {
        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.write(frame: frame)
        return buffer
    }

    /// Captures the reads and errors a child channel sees.
    fileprivate final class Recorder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        let received: NIOLockedValueBox<[UInt8]>
        let errors: NIOLockedValueBox<[String]>

        init(received: NIOLockedValueBox<[UInt8]>, errors: NIOLockedValueBox<[String]>) {
            self.received = received
            self.errors = errors
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = self.unwrapInboundIn(data)
            self.received.withLockedValue { $0.append(contentsOf: buffer.readableBytesView) }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            self.errors.withLockedValue { $0.append("\(error)") }
        }
    }

    /// A `ChannelMultiplexer` wired to an embedded parent channel, for driving `receiveMessage`
    /// directly without a full muxer pipeline.
    fileprivate struct MultiplexerHarness {
        let parent: EmbeddedChannel
        let multiplexer: ChannelMultiplexer
        private let delegate: Delegate

        init(mode: LibP2PCore.Mode = .listener) throws {
            self.parent = EmbeddedChannel()
            try self.parent.connect(to: .init(unixDomainSocketPath: "/parent")).wait()
            self.delegate = Delegate(channel: self.parent)
            self.multiplexer = ChannelMultiplexer(
                delegate: self.delegate,
                allocator: self.parent.allocator,
                mode: mode,
                initialWindowSize: PreAcknowledgementTests.window,
                logger: Logger(label: "test.yamux"),
                childChannelInitializer: { $0.eventLoop.makeSucceededVoidFuture() }
            )
        }

        /// Drives a remotely-initiated stream to `.active` (peer SYN, our ACK).
        func openInboundStream(id: UInt32) throws {
            try self.multiplexer.receiveMessage(
                .channelOpen(
                    .init(
                        senderChannel: id,
                        initialWindowSize: PreAcknowledgementTests.window,
                        maximumPacketSize: PreAcknowledgementTests.window
                    )
                )
            )
            (self.parent.eventLoop as! EmbeddedEventLoop).run()
        }

        func tearDown() {
            self.multiplexer.parentHandlerRemoved()
            _ = try? self.parent.finish(acceptAlreadyClosed: true)
        }

        /// The minimum a multiplexer needs from its parent handler.
        private final class Delegate: MultiplexerDelegate {
            let channel: Channel?
            init(channel: Channel) { self.channel = channel }
            func writeFromChildChannel(_ frame: Frame, _ promise: EventLoopPromise<Void>?) { promise?.succeed(()) }
            func flushFromChildChannel() {}
            func childChannelCreated(stream: any LibP2PCore._Stream) {}
            func childChannelRemoved(stream: any LibP2PCore._Stream) {}
        }
    }
}
