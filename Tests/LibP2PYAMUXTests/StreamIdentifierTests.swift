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

/// Tests for how the multiplexer handles remotely-initiated stream ids.
///
/// Yamux stream ids are monotonic and never reused, so the multiplexer tracks a single
/// high-water mark (`highestInboundChannelID`) and refuses any inbound `SYN` at or below it.
///
/// Every refusal is answered with a stream `RST`. Previously the parity and id-in-use paths
/// threw instead, which `YAMUXHandler.forwardToMultiplexer` swallowed into a log line, leaving
/// the peer waiting on a stream we'd silently declined.
@Suite("Stream Identifier Tests")
struct StreamIdentifierTests {

    static let window: UInt32 = 1024 * 256

    // MARK: - Ids are never reused

    @Test func testSynForACleanlyClosedStreamIDIsReset() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        try harness.openInboundStream(id: 1)
        // Peer half-closes, then we close: a full, clean teardown.
        try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 1)))
        let child = try #require(harness.multiplexer.channels[1])
        _ = child.channel.close()
        harness.run()
        #expect(harness.multiplexer.channels[1] == nil, "Precondition: the stream is gone.")

        harness.clearWrittenFrames()
        try harness.receiveSyn(id: 1)
        harness.run()

        #expect(harness.multiplexer.channels[1] == nil, "A closed ID must not be reusable.")
        try harness.expectSingleReset(streamID: 1)
    }

    @Test func testSynForATornDownStreamIDIsReset() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        try harness.openInboundStream(id: 1)
        // Peer half-closes and then sends data anyway, a real violation that errors the child.
        try harness.multiplexer.receiveMessage(.channelClose(.init(recipientChannel: 1)))
        try harness.multiplexer.receiveMessage(.channelData(.init(recipientChannel: 1, data: Self.payload())))
        harness.run()
        #expect(harness.multiplexer.channels[1] == nil, "Precondition: the stream was torn down.")

        harness.clearWrittenFrames()
        try harness.receiveSyn(id: 1)
        harness.run()

        #expect(harness.multiplexer.channels[1] == nil, "A torn-down ID must not be reusable.")
        try harness.expectSingleReset(streamID: 1)
    }

    @Test func testSynForAnOpenStreamIDIsReset() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        try harness.openInboundStream(id: 1)
        harness.clearWrittenFrames()

        try harness.receiveSyn(id: 1)
        harness.run()

        #expect(harness.multiplexer.channels.count == 1, "The live stream must be left alone.")
        try harness.expectSingleReset(streamID: 1)
    }

    @Test func testStreamIDsMayIncreaseNonContiguously() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        try harness.openInboundStream(id: 1)
        try harness.openInboundStream(id: 5)
        #expect(harness.multiplexer.channels.count == 2, "Skipping IDs is legal.")

        harness.clearWrittenFrames()
        try harness.receiveSyn(id: 3)
        harness.run()

        #expect(harness.multiplexer.channels[3] == nil, "Going backwards is not.")
        try harness.expectSingleReset(streamID: 3)
    }

    // MARK: - Parity and the reserved session ID

    /// A listener's own streams are even, so an even inbound `SYN` is the peer claiming an id
    /// that belongs to us. This used to throw into a log line and tell the peer nothing.
    @Test func testSynWithWrongParityIsReset() throws {
        let harness = try Harness(mode: .listener)
        defer { harness.tearDown() }

        try harness.receiveSyn(id: 2)
        harness.run()

        #expect(harness.multiplexer.channels.isEmpty)
        try harness.expectSingleReset(streamID: 2)
    }

    /// Stream 0 is yamux's session stream (pings, go-away) and is never a real stream. Because
    /// the high-water mark starts at 0, the monotonicity check rejects it for free, which
    /// matters for an initiator, where inbound ids are even and 0 passes the parity check.
    @Test func testSynOnTheSessionStreamIsReset() throws {
        let harness = try Harness(mode: .initiator)
        defer { harness.tearDown() }

        try harness.receiveSyn(id: 0)
        harness.run()

        #expect(harness.multiplexer.channels.isEmpty, "Stream 0 must never be allocated as a stream.")
        try harness.expectSingleReset(streamID: 0)
    }

    /// A rejected `SYN` must not move the mark, otherwise one bogus frame could lock the peer
    /// out of the IDs above it.
    @Test func testARejectedSynDoesNotBurnLaterIds() throws {
        let harness = try Harness(mode: .listener)
        defer { harness.tearDown() }

        // Wrong parity, refused, and the mark doesn't move.
        try harness.receiveSyn(id: 4)
        harness.run()
        #expect(harness.multiplexer.channels.isEmpty)

        // The peer's legitimate streams, including ones below the refused ID, still work.
        try harness.openInboundStream(id: 1)
        try harness.openInboundStream(id: 3)
        #expect(harness.multiplexer.channels.count == 2)
    }
}

// MARK: - Helpers

extension StreamIdentifierTests {

    fileprivate static func payload(_ string: String = "hello") -> ByteBuffer {
        ByteBuffer(string: string)
    }

    /// A `ChannelMultiplexer` wired to an embedded parent channel, recording every frame it
    /// hands back to that parent.
    fileprivate struct Harness {
        let parent: EmbeddedChannel
        let multiplexer: ChannelMultiplexer
        private let delegate: Delegate

        var writtenFrames: [Frame] { self.delegate.frames.withLockedValue { $0 } }

        init(mode: LibP2PCore.Mode = .listener) throws {
            self.parent = EmbeddedChannel()
            try self.parent.connect(to: .init(unixDomainSocketPath: "/parent")).wait()
            self.delegate = Delegate(channel: self.parent)
            self.multiplexer = ChannelMultiplexer(
                delegate: self.delegate,
                allocator: self.parent.allocator,
                mode: mode,
                initialWindowSize: StreamIdentifierTests.window,
                logger: Logger(label: "test.yamux.ids"),
                childChannelInitializer: { $0.eventLoop.makeSucceededVoidFuture() }
            )
        }

        func receiveSyn(id: UInt32) throws {
            try self.multiplexer.receiveMessage(
                .channelOpen(
                    .init(
                        senderChannel: id,
                        initialWindowSize: StreamIdentifierTests.window,
                        maximumPacketSize: StreamIdentifierTests.window
                    )
                )
            )
        }

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

        /// Asserts the only thing we told the peer was an `RST` for `streamID`.
        func expectSingleReset(streamID: UInt32, sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(
                self.writtenFrames.count == 1,
                "Expected one frame, got \(self.writtenFrames)",
                sourceLocation: sourceLocation
            )
            let reset = try #require(self.writtenFrames.first, sourceLocation: sourceLocation)
            #expect(reset.header.streamID == streamID, sourceLocation: sourceLocation)
            #expect(
                reset.header.flags.contains(.reset),
                "A refused stream must be answered with RST, not dropped silently.",
                sourceLocation: sourceLocation
            )
        }

        func tearDown() {
            self.multiplexer.parentHandlerRemoved()
            _ = try? self.parent.finish(acceptAlreadyClosed: true)
        }

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
}
