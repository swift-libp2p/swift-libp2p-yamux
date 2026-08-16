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
import NIOTestUtils
import Testing

@testable import LibP2PYAMUX

@Suite("Yamux Tests")
struct LibP2PYAMUXTests {

    @Test func testAppConfiguration() throws {
        let app = try Application(.detect())
        app.muxers.use(.yamux)
        #expect(app.muxers.available.map { $0.description } == ["/yamux/1.0.0"])
        let _ = try #require(app.muxers.upgrader(for: YAMUX.self))
        let _ = try #require(app.muxers.upgrader(forKey: YAMUX.key))
    }

}

@Suite("Inbound Stream Backlog Tests")
struct InboundStreamBacklogTests {

    /// A minimal `MultiplexerDelegate` that records the frames the multiplexer writes.
    private final class RecordingDelegate: MultiplexerDelegate, @unchecked Sendable {
        var channel: Channel? { nil }
        private(set) var written: [Frame] = []
        func writeFromChildChannel(_ message: Frame, _ promise: EventLoopPromise<Void>?) {
            self.written.append(message)
            promise?.succeed()
        }
        func flushFromChildChannel() {}
        func childChannelCreated(stream: any LibP2PCore._Stream) {}
        func childChannelRemoved(stream: any LibP2PCore._Stream) {}
    }

    /// When the inbound-stream limit is reached, a further `channelOpen` is answered
    /// with a `RST` and no child channel is allocated.
    @Test func testExceedingInboundLimitResetsTheStream() throws {
        let delegate = RecordingDelegate()
        // maxInboundStreams: 0 means the very first inbound open is over the limit.
        let mux = ChannelMultiplexer(
            delegate: delegate,
            allocator: ByteBufferAllocator(),
            mode: .listener,
            initialWindowSize: YAMUXHandler.initialWindowSize,
            maxInboundStreams: 0,
            logger: Logger(label: "test.backlog"),
            childChannelInitializer: nil
        )

        // Inbound (remote-initiated) streams on a listener use odd ids.
        try mux.receiveMessage(
            .channelOpen(.init(senderChannel: 1, initialWindowSize: 0, maximumPacketSize: 0))
        )

        #expect(mux.channels.isEmpty, "No child channel should be created once the backlog is full.")
        #expect(delegate.written.count == 1, "A single reset frame should be emitted.")
        let reset = try #require(delegate.written.first)
        #expect(reset.header.streamID == 1)
        #expect(reset.header.flags.contains(.reset), "The rejecting frame must carry the RST flag.")
    }

    /// Streams within the limit are still accepted normally.
    @Test func testInboundStreamsWithinLimitAreNotReset() throws {
        let delegate = RecordingDelegate()
        let mux = ChannelMultiplexer(
            delegate: delegate,
            allocator: ByteBufferAllocator(),
            mode: .listener,
            initialWindowSize: YAMUXHandler.initialWindowSize,
            maxInboundStreams: 4,
            logger: Logger(label: "test.backlog"),
            childChannelInitializer: nil
        )

        // openNewChannel requires a live parent channel; without one it throws rather
        // than resetting. The point here is simply that we do NOT emit an RST for a
        // stream that's within the backlog limit.
        _ = try? mux.receiveMessage(
            .channelOpen(.init(senderChannel: 1, initialWindowSize: 0, maximumPacketSize: 0))
        )
        #expect(
            !delegate.written.contains { $0.header.flags.contains(.reset) },
            "A stream within the limit must not be reset."
        )
    }
}

struct TestHelper {
    static var internalIntegrationTestsEnabled: Bool {
        if let b = ProcessInfo.processInfo.environment["PerformInternalIntegrationTests"], b == "true" {
            return true
        }
        return false
    }

    static var externalIntegrationTestsEnabled: Bool {
        if let b = ProcessInfo.processInfo.environment["PerformExternalIntegrationTests"], b == "true" {
            return true
        }
        return false
    }
}

extension Trait where Self == ConditionTrait {
    /// This test is only available when the `PerformInternalIntegrationTests` environment variable is set to `true`
    public static var internalIntegrationTestsEnabled: Self {
        enabled(
            if: TestHelper.internalIntegrationTestsEnabled,
            "This test is only available when the `PerformInternalIntegrationTests` environment variable is set to `true`"
        )
    }

    /// This test is only available when the `PerformExternalIntegrationTests` environment variable is set to `true`
    public static var externalIntegrationTestsEnabled: Self {
        enabled(
            if: TestHelper.externalIntegrationTestsEnabled,
            "This test is only available when the `PerformExternalIntegrationTests` environment variable is set to `true`"
        )
    }
}
