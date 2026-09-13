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

    @Test func testLocallyRequestedStreamIsNotYetActiveOnChannel() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)
        #expect(!sm.isActiveOnChannel, "The peer hasn't acknowledged the stream yet.")
        #expect(sm.isActiveOnNetwork, "But it is on the wire: our SYN has gone out.")

        #expect(try sm.receiveChannelOpenConfirmation(Self.ack(1)) == .process)
        #expect(sm.isActiveOnChannel)
    }

    /// Granting inbound window on a stream we've only SYN'd is legal, (`sendWindowUpdate`
    /// never gates on stream state), and it's reachable, pre-ACK data is delivered to the
    /// application, and once half the window has been consumed `deliverSingleRead` emits an
    /// increment. This used to be a `preconditionFailure`, i.e. a remotely-reachable crash.
    @Test func testSendingWindowUpdateBeforeAckIsLegal() throws {
        var locally = Self.makeLocallyRequestedChannel(id: 1)
        #expect(throws: Never.self) {
            try locally.sendChannelWindowAdjust(.init(recipientChannel: 1, bytesToAdd: Self.window / 2))
        }

        var remotely = ChildChannelStateMachine(localChannelID: 2)
        remotely.receiveChannelOpen(
            .init(senderChannel: 2, initialWindowSize: Self.window, maximumPacketSize: Self.window)
        )
        #expect(throws: Never.self) {
            try remotely.sendChannelWindowAdjust(.init(recipientChannel: 2, bytesToAdd: Self.window / 2))
        }
    }

    /// Our own FIN closes our WRITE side only. We're still reading, so we must still return
    /// window, otherwise a peer answering a one-shot request with more than a full window
    /// stalls forever. See `HalfClosureFlowControlTests` for the end-to-end version.
    @Test func testSendingWindowUpdateAfterOurOwnCloseIsLegal() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)
        #expect(try sm.receiveChannelOpenConfirmation(Self.ack(1)) == .process)
        try sm.sendChannelClose(.init(recipientChannel: 1))

        #expect(throws: Never.self) {
            try sm.sendChannelWindowAdjust(.init(recipientChannel: 1, bytesToAdd: Self.window / 2))
        }
    }

    /// Once the stream is fully closed a window update really is wrong, but it's rejected with
    /// a thrown error, never a trap, because every caller of this is driven by inbound data.
    @Test func testSendingWindowUpdateOnAClosedStreamThrowsRatherThanTraps() throws {
        var sm = Self.makeLocallyRequestedChannel(id: 1)
        #expect(try sm.receiveChannelOpenConfirmation(Self.ack(1)) == .process)
        try sm.sendChannelClose(.init(recipientChannel: 1))
        try sm.receiveChannelClose(.init(recipientChannel: 1))
        #expect(sm.isClosed, "Precondition: both directions are closed.")

        #expect(throws: YAMUX.Error.self) {
            try sm.sendChannelWindowAdjust(.init(recipientChannel: 1, bytesToAdd: Self.window / 2))
        }
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

    /// The other half of the same burst, if the child's initializer *fails* after the peer's FIN
    /// has already half-closed the stream, we still owe the peer a rejection. Sending it from
    /// `.closedRemotely` used to hit `preconditionFailure("Duplicate open failure sent.")`.
    @Test func testOpenFailureAfterRemoteFinIsLegal() throws {
        var sm = ChildChannelStateMachine(localChannelID: 2)
        sm.receiveChannelOpen(.init(senderChannel: 2, initialWindowSize: Self.window, maximumPacketSize: Self.window))
        try sm.receiveChannelClose(.init(recipientChannel: 2))

        sm.sendChannelOpenFailure(.init(recipientChannel: 2, reasonCode: 2, description: "", language: "en-US"))
        #expect(sm.isClosed, "Rejecting the open is terminal.")
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

    /// A stream-level failure is answered with an RST, not a FIN.
    @Test func testStreamLevelErrorSendsResetNotFin() throws {
        let harness = try MultiplexerHarness()
        defer { harness.tearDown() }

        try harness.openInboundStream(id: 1)
        harness.clearWrittenFrames()

        // Peer half-closes and then sends data anyway: a genuine violation.
        try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 1)))
        try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 1, data: Self.payload())))
        harness.run()

        #expect(harness.multiplexer.channels[1] == nil, "The stream is torn down.")
        let frames = harness.writtenFrames.filter { $0.header.streamID == 1 }
        #expect(
            frames.contains { $0.header.flags.contains(.reset) },
            "A stream-level error must RST: \(frames)"
        )
        #expect(
            !frames.contains { $0.header.flags.contains(.fin) },
            "A FIN would tell the peer to keep writing into a stream we've already dropped: \(frames)"
        )
    }

    /// The same, on a stream we haven't ACKed yet. `sendChannelReset` used to refuse
    /// `.requestedRemotely`, so the RST was swallowed and the peer was told nothing at all.
    @Test func testErrorBeforeOurAckStillResetsTheStream() throws {
        let gate = NIOLockedValueBox<EventLoopPromise<Void>?>(nil)
        let harness = try MultiplexerHarness(childChannelInitializer: { child in
            let promise = child.eventLoop.makePromise(of: Void.self)
            gate.withLockedValue { $0 = promise }
            return promise.futureResult
        })
        defer { harness.tearDown() }

        // The initializer never completes, so our ACK never goes out, the stream stays
        // `.requestedRemotely`.
        try harness.receiveSyn(id: 1)
        harness.run()
        #expect(harness.writtenFrames.isEmpty, "Precondition: we haven't acknowledged the stream.")

        // A peer cannot acknowledge a stream it opened itself. This is a real violation.
        try harness.multiplexer.receiveMessage(.channelOpenConfirmation(Self.ack(1)))
        harness.run()

        #expect(harness.multiplexer.channels[1] == nil, "The stream is torn down.")
        #expect(
            harness.writtenFrames.contains { $0.header.streamID == 1 && $0.header.flags.contains(.reset) },
            "Even an unacknowledged stream must be RST so the peer stops waiting: \(harness.writtenFrames)"
        )
    }

    /// We FIN (done sending our request) and then read a response bigger than the window. Our
    /// read side is still open, so window has to keep flowing back, otherwise the peer runs out
    /// and the stream stalls with the response half-delivered.
    @Test func testWindowIsReturnedAfterOurOwnHalfClose() throws {
        let harness = try MultiplexerHarness(mode: .initiator)
        defer { harness.tearDown() }

        let streamPromise = harness.parent.eventLoop.makePromise(of: YAMUXStream.self)
        harness.multiplexer.createOutboundChildChannel(streamPromise) { $0.eventLoop.makeSucceededVoidFuture() }
        harness.run()
        let stream = try streamPromise.futureResult.wait()
        let id = UInt32(stream.id)

        // The peer acknowledges, then we say "done sending" without closing our read side.
        try harness.multiplexer.receiveMessage(.channelOpenConfirmation(Self.ack(id)))

        // `close(mode: .output)` is unsupported on this channel, so a full `close()` is how the
        // half-close happens, it sends the FIN and leaves the stream in `.closedLocally`,
        // registered and still reading, until the peer closes too.
        _ = stream.channel.close()
        harness.run()
        #expect(harness.multiplexer.channels[id] != nil, "A half-close must not tear the stream down.")

        // Ensure that we've sent our FIN.
        #expect(
            harness.writtenFrames.contains { $0.header.streamID == id && $0.header.flags.contains(.fin) },
            "Precondition: we've sent our FIN, so `sentClose` is true: \(harness.writtenFrames)"
        )
        harness.clearWrittenFrames()

        // The response arrives, more than half the window of it.
        let chunk = ByteBuffer(repeating: 0x61, count: Int(Self.window) / 2 + 1)
        #expect(throws: Never.self) {
            try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: id, data: chunk)))
        }
        harness.multiplexer.parentChannelReadComplete()
        harness.run()

        let updates = harness.writtenFrames.filter {
            $0.header.messageType == .windowUpdate && $0.header.streamID == id && $0.header.length > 0
        }
        #expect(
            !updates.isEmpty,
            "Our own FIN closed our write side, the read side must still return window: \(harness.writtenFrames)"
        )
    }

    /// A write after our own FIN must fail that write and leave the stream alone. It used to
    /// throw a protocol violation out of `sendChannelData`, which `processOutboundMessage`
    /// escalated to `errorEncountered`, tearing down a stream whose read side was still good,
    /// since `errorEncountered` skips the RST once `sentClose` is set. One stray write
    /// (a retry, a trailing flush) destroyed the response path.
    @Test func testWriteAfterOurOwnHalfCloseFailsWithoutTerminatingTheStream() throws {
        let harness = try MultiplexerHarness(mode: .initiator)
        defer { harness.tearDown() }

        let streamPromise = harness.parent.eventLoop.makePromise(of: YAMUXStream.self)
        harness.multiplexer.createOutboundChildChannel(streamPromise) { $0.eventLoop.makeSucceededVoidFuture() }
        harness.run()
        let stream = try streamPromise.futureResult.wait()
        let id = UInt32(stream.id)

        try harness.multiplexer.receiveMessage(.channelOpenConfirmation(Self.ack(id)))
        _ = stream.channel.close()
        harness.run()
        harness.clearWrittenFrames()

        let write = stream.channel.writeAndFlush(Self.payload("late"))
        harness.run()

        #expect(throws: ChannelError.outputClosed) { try write.wait() }
        #expect(harness.multiplexer.channels[id] != nil, "The stream must survive a rejected write.")
        #expect(harness.writtenFrames.isEmpty, "Nothing should reach the peer: \(harness.writtenFrames)")

        // And the read side still works, which is the whole point of the half-close.
        try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: id, data: Self.payload("resp"))))
        harness.multiplexer.parentChannelReadComplete()
        harness.run()
        #expect(harness.multiplexer.channels[id] != nil, "Still reading after the rejected write.")
    }

    /// `parentChannelInactive` errors every child in a loop, and `errorEncountered` deregisters
    /// synchronously, so the collection is mutated while it's being iterated. It must iterate a snapshot.
    @Test func testParentGoingInactiveWhileChildrenDeregisterIsSafe() throws {
        let harness = try MultiplexerHarness()
        defer { harness.tearDown() }

        let ids: [UInt32] = [1, 3, 5]
        for id in ids {
            try harness.openInboundStream(id: id)
        }
        #expect(harness.multiplexer.channels.count == ids.count)

        #expect(throws: Never.self) {
            harness.multiplexer.parentChannelInactive()
        }
        harness.run()

        #expect(harness.multiplexer.channels.isEmpty, "Every child errored out and deregistered.")
    }

    /// Same hazard in `shouldQuiesce`, which closes every child in a loop. A child the peer has
    /// already half-closed goes straight to fully-closed on our FIN, deregistering mid-loop.
    @Test func testQuiesceWhileChildrenDeregisterIsSafe() throws {
        let harness = try MultiplexerHarness()
        defer { harness.tearDown() }

        let ids: [UInt32] = [1, 3, 5]
        for id in ids {
            try harness.openInboundStream(id: id)
            // Peer half-closes, so our own close completes the teardown synchronously.
            try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: id)))
        }
        #expect(harness.multiplexer.channels.count == ids.count)

        #expect(throws: Never.self) {
            _ = harness.multiplexer.shouldQuiesce(on: harness.parent.eventLoop)
        }
        harness.run()

        #expect(harness.multiplexer.channels.isEmpty, "Quiescing a half-closed stream closes it outright.")
    }

    /// `parentChannelReadComplete` iterates the same collection to flush each child's buffered
    /// reads, and the application can close from inside that flush. Today a close from `.active`
    /// only half-closes (FIN out, stream stays registered), so this loop can't be made to mutate
    /// the collection, but it iterates a snapshot for the same reason, and this pins the
    /// behavior in case that ever changes.
    @Test func testChildClosingDuringReadCompleteIsSafe() throws {
        let harness = try MultiplexerHarness(childChannelInitializer: { child in
            child.pipeline.addHandler(ClosesOnRead())
        })
        defer { harness.tearDown() }

        let ids: [UInt32] = [1, 3, 5]
        for id in ids {
            try harness.openInboundStream(id: id)
            // Buffered, not delivered: `handleInboundChannelData` only appends to `pendingReads`.
            try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: id, data: Self.payload())))
        }

        // Every child closes itself on its first read, all from inside this one loop.
        #expect(throws: Never.self) {
            harness.multiplexer.parentChannelReadComplete()
        }
        harness.run()

        let fins = harness.writtenFrames.filter { $0.header.flags.contains(.fin) }
        #expect(fins.count == ids.count, "Each child should have FIN'd from inside the read it was given.")
    }

    // MARK: - End to end

    /// Open an outbound stream, then hand the muxer a bare `DATA` frame (no ACK) followed by
    /// the ACK on a later frame. The bytes must reach the stream's handler and nothing may be
    /// reported as an error.
    @Test func testDataBeforeAckIsDeliveredToTheStream() throws {
        let received = NIOLockedValueBox<[UInt8]>([])
        let errors = NIOLockedValueBox<[String]>([])

        let connection = try DummyConnection(peer: PeerID(.Ed25519), direction: .outbound)
        // DummyConnection gives us AsyncTestingChannels and we need EmbeddedChannels for
        // the synchronous testing we're doing...
        let channel = EmbeddedChannel()
        connection.channel = channel
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
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

    /// More than half the flow-control window arrives on a stream we've SYN'd but that the peer
    /// hasn't ACKed. The bytes reach the application, which means window has to be returned.
    @Test func testPreAckDataBeyondHalfTheWindowEmitsAWindowUpdate() throws {
        let harness = try MultiplexerHarness(mode: .initiator)
        defer { harness.tearDown() }

        let streamPromise = harness.parent.eventLoop.makePromise(of: YAMUXStream.self)
        harness.multiplexer.createOutboundChildChannel(streamPromise) { $0.eventLoop.makeSucceededVoidFuture() }
        harness.run()
        let stream = try streamPromise.futureResult.wait()
        let id = UInt32(stream.id)

        // The peer answers with a big response and still hasn't acknowledged the stream.
        let chunk = ByteBuffer(repeating: 0x61, count: Int(Self.window) / 2 + 1)
        #expect(throws: Never.self) {
            try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: id, data: chunk)))
        }
        harness.multiplexer.parentChannelReadComplete()
        harness.run()

        let updates = harness.writtenFrames.filter {
            $0.header.messageType == .windowUpdate && $0.header.streamID == id && $0.header.length > 0
        }
        #expect(
            !updates.isEmpty,
            "Consuming half the window must return it, even before the peer's ACK: \(harness.writtenFrames)"
        )
        #expect(harness.multiplexer.channels[id] != nil, "The stream must survive returning window pre-ACK.")
    }

    /// The `SYN` + request + `FIN` burst that a one-shot libp2p request looks like, landing while
    /// the child's initializer is still running. Nothing may reach the pipeline before
    /// `channelActive`, so the read-EOF is staged and replayed on activation, in order, with a
    /// single `channelReadComplete`, and with our write side still usable afterwards.
    @Test func testBurstBeforeActivationIsReplayedInOrderOnActivation() throws {
        let events = NIOLockedValueBox<[LifecycleRecorder.Event]>([])
        let gate = NIOLockedValueBox<EventLoopPromise<Void>?>(nil)

        let harness = try MultiplexerHarness(childChannelInitializer: { child in
            let promise = child.eventLoop.makePromise(of: Void.self)
            gate.withLockedValue { $0 = promise }
            return promise.futureResult.flatMap {
                child.pipeline.addHandler(LifecycleRecorder(events: events))
            }
        })
        defer { harness.tearDown() }

        // The whole burst arrives before the initializer completes, so our ACK hasn't gone out.
        try harness.receiveSyn(id: 1)
        try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 1, data: Self.payload("request"))))
        try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 1)))
        harness.multiplexer.parentChannelReadComplete()
        harness.run()

        #expect(events.withLockedValue { $0 }.isEmpty, "Nothing may be delivered before channelActive.")

        // Initializer completes: we ACK, activate, and only now replay the burst.
        gate.withLockedValue { $0 }?.succeed(())
        harness.run()

        #expect(
            events.withLockedValue { $0 } == [.active, .read("request"), .readComplete, .inputClosed],
            "Expected activate -> read -> one readComplete -> EOF, got \(events.withLockedValue { $0 })"
        )

        // Ensure our write side is still open and we can respond if necessary.
        let child = try #require(harness.multiplexer.channels[1])
        #expect(child.channel.isActive)
        try child.channel.writeAndFlush(Self.payload("response")).wait()
        harness.run()

        let responses = harness.writtenFrames.filter {
            $0.header.messageType == .data && $0.header.streamID == 1
        }
        #expect(responses.count == 1, "The response must go out after the peer's FIN.")
        #expect(events.withLockedValue { $0 }.filter { $0 == .readComplete }.count == 1, "No duplicate readComplete.")
    }

    /// The same burst, but the initializer fails once the stream is already half-closed. We owe
    /// the peer a rejection, and emitting it from `.closedRemotely` used to trap.
    @Test func testFailingInitializerAfterRemoteFinDoesNotTrap() throws {
        let gate = NIOLockedValueBox<EventLoopPromise<Void>?>(nil)

        let harness = try MultiplexerHarness(childChannelInitializer: { child in
            let promise = child.eventLoop.makePromise(of: Void.self)
            gate.withLockedValue { $0 = promise }
            return promise.futureResult
        })
        defer { harness.tearDown() }

        try harness.receiveSyn(id: 1)
        try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 1, data: Self.payload("request"))))
        try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 1)))
        harness.run()

        gate.withLockedValue { $0 }?.fail(InitializerRejected())
        harness.run()

        #expect(harness.multiplexer.channels[1] == nil, "A rejected stream must be torn down, not trapped on.")
        // And the peer's in-flight leftovers for that id are harmless.
        #expect(throws: Never.self) {
            try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 1, data: Self.payload())))
        }
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

        /// Every frame the multiplexer handed to its parent, in order.
        var writtenFrames: [Frame] { self.delegate.frames.withLockedValue { $0 } }

        init(
            mode: LibP2PCore.Mode = .listener,
            childChannelInitializer: @escaping ChildChannel.Initializer = { $0.eventLoop.makeSucceededVoidFuture() }
        ) throws {
            self.parent = EmbeddedChannel()
            try self.parent.connect(to: .init(unixDomainSocketPath: "/parent")).wait()
            self.delegate = Delegate(channel: self.parent)
            self.multiplexer = ChannelMultiplexer(
                delegate: self.delegate,
                allocator: self.parent.allocator,
                mode: mode,
                initialWindowSize: PreAcknowledgementTests.window,
                logger: Logger(label: "test.yamux"),
                childChannelInitializer: childChannelInitializer
            )
        }

        /// Delivers the peer's `SYN` for `id`. Whether this reaches `.active` depends on the
        /// child initializer, our `ACK` only goes out once that completes.
        func receiveSyn(id: UInt32) throws {
            try self.multiplexer.receiveMessage(
                .channelOpen(
                    .init(
                        senderChannel: id,
                        initialWindowSize: PreAcknowledgementTests.window,
                        maximumPacketSize: PreAcknowledgementTests.window
                    )
                )
            )
        }

        /// Drives a remotely-initiated stream to `.active` (peer SYN, our ACK).
        func openInboundStream(id: UInt32) throws {
            try self.receiveSyn(id: id)
            self.run()
        }

        func run() {
            (self.parent.eventLoop as! EmbeddedEventLoop).run()
        }

        func clearWrittenFrames() {
            self.delegate.frames.withLockedValue { $0.removeAll() }
        }

        func tearDown() {
            self.multiplexer.parentHandlerRemoved()
            _ = try? self.parent.finish(acceptAlreadyClosed: true)
        }

        /// The minimum a multiplexer needs from its parent handler.
        private final class Delegate: MultiplexerDelegate {
            let channel: Channel?
            let frames = NIOLockedValueBox<[Frame]>([])
            init(channel: Channel) { self.channel = channel }
            func writeFromChildChannel(_ frame: Frame, _ promise: EventLoopPromise<Void>?) {
                self.frames.withLockedValue { $0.append(frame) }
                promise?.succeed(())
            }
            func flushFromChildChannel() {}
            func childChannelCreated(stream: any LibP2PCore._Stream) {}
            func childChannelRemoved(stream: any LibP2PCore._Stream) {}
        }
    }

    /// An error to fail a child channel's initializer with.
    fileprivate struct InitializerRejected: Error {}

    /// Records the inbound lifecycle a child channel's pipeline actually sees, in order, so tests
    /// can assert on `channelActive` / `channelRead` / `channelReadComplete` / `inputClosed`
    /// ordering rather than just on final state.
    fileprivate final class LifecycleRecorder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        enum Event: Equatable {
            case active
            case read(String)
            case readComplete
            case inputClosed
            case inactive
        }

        let events: NIOLockedValueBox<[Event]>

        init(events: NIOLockedValueBox<[Event]>) {
            self.events = events
        }

        private func record(_ event: Event) {
            self.events.withLockedValue { $0.append(event) }
        }

        func channelActive(context: ChannelHandlerContext) {
            self.record(.active)
            context.fireChannelActive()
        }

        func channelInactive(context: ChannelHandlerContext) {
            self.record(.inactive)
            context.fireChannelInactive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = self.unwrapInboundIn(data)
            self.record(.read(String(decoding: buffer.readableBytesView, as: UTF8.self)))
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            self.record(.readComplete)
            context.fireChannelReadComplete()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case ChannelEvent.inputClosed = event {
                self.record(.inputClosed)
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    /// Closes its channel the moment it sees a read, so the multiplexer's channel registry is
    /// mutated part-way through whatever loop delivered that read.
    fileprivate final class ClosesOnRead: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.close(promise: nil)
        }
    }
}
