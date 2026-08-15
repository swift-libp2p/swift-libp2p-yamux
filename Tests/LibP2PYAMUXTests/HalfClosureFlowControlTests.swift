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
import Testing

@testable import LibP2PYAMUX

@Suite("Half-Closure State Machine Tests")
struct HalfClosureStateMachineTests {

    /// A payload at least half the window is what makes the window manager emit
    /// an increment — i.e. what would put a `channelWindowAdjust` on the wire.
    /// This is the "large payload" precondition shared by the two bugs below.
    static let window: UInt32 = 1024 * 256
    static let largePayload = Int(window) - 1024

    /// Demonstrates that a large inbound request (>= half the window) forces the
    /// window manager to emit an increment when it's delivered to the handler.
    @Test func testLargeRequestEmitsWindowIncrement() throws {
        var manager = ChildChannelWindowManager(targetWindowSize: Self.window)

        // Peer sends a large request; we buffer it (consuming our receive window).
        try manager.bufferFlowControlledBytes(Self.largePayload)

        // We deliver it up to the handler. Because we've now handed more than
        // half the window to the application without granting it back, the
        // manager tells us to top the peer's window back up.
        let increment = manager.unbufferBytes(Self.largePayload)

        #expect(
            increment != nil,
            "A request >= half the window must emit a window increment."
        )
    }

    /// Scenario: peer sends `request + FIN`, then we start streaming a *large*
    /// response. As the peer consumes it, its (still-open) read side sends us
    /// `WINDOW_UPDATE` frames so we can keep writing past the initial window.
    @Test func testInboundWindowAdjustAfterRemoteHalfCloseIsAccepted() throws {
        var sm = makeRemotelyHalfClosedInboundChannel(id: 1)

        #expect(
            throws: Never.self,
            "A half-closed peer's read side stays open and legitimately sends window updates so we can finish a large response."
        ) {
            try sm.receiveChannelWindowAdjust(
                .init(recipientChannel: 1, bytesToAdd: Self.window)
            )
        }
    }

    /// Scenario: peer sends `large-request + FIN` in one burst. The data is
    /// buffered, then the FIN drives us to `.closedRemotely`, at which point
    /// `handleInboundChannelClose` flushes the buffered read. Delivering a
    /// large request emits a window increment (see
    /// `testLargeRequestEmitsWindowIncrement`), which `ChildChannel` sends via
    /// `sendChannelWindowAdjust`.
    @Test func testDeliveringLargeRequestAfterRemoteHalfCloseSucceeds() throws {
        var sm = makeRemotelyHalfClosedInboundChannel(id: 1)

        #expect(throws: Never.self) {
            try sm.sendChannelWindowAdjust(
                .init(recipientChannel: 1, bytesToAdd: Self.window)
            )
        }
    }

    /// Closing from `.requestedLocally` is possible
    /// the FIN is addressed with our own id and the stream moves to
    /// `.closedLocally`, exactly like an active-stream close.
    @Test func testCloseWhileRequestedLocallySendsFin() throws {
        var sm = ChildChannelStateMachine(localChannelID: 5)
        sm.sendChannelOpen(.init(senderChannel: 5, initialWindowSize: Self.window, maximumPacketSize: Self.window))

        // Symmetric id is known the instant we send the SYN.
        #expect(sm.remoteChannelIdentifier == 5)

        // Closing from `.requestedLocally` now succeeds (sends a FIN) rather than
        // throwing, so the clean-teardown path PR #3 added still holds.
        #expect(throws: Never.self) {
            try sm.sendChannelClose(.init(recipientChannel: 5))
        }
        #expect(sm.sentClose, "Closing a still-opening stream should record that we've sent our FIN.")
    }

    // MARK: - Helpers

    /// Drives a fresh inbound (listener-side) child-channel state machine to
    /// `.active` and then to `.closedRemotely` (peer sent us a FIN).
    private static func makeRemotelyHalfClosedInboundChannel(id: UInt32) -> ChildChannelStateMachine {
        var sm = ChildChannelStateMachine(localChannelID: id)
        // Peer opens the stream (SYN).
        sm.receiveChannelOpen(.init(senderChannel: id, initialWindowSize: window, maximumPacketSize: window))
        // We accept it (ACK) -> .active
        sm.sendChannelOpenConfirmation(
            .init(recipientChannel: id, senderChannel: id, initialWindowSize: window, maximumPacketSize: window)
        )
        // Peer half-closes its write side (FIN) -> .closedRemotely
        try! sm.receiveChannelClose(.init(recipientChannel: id))
        return sm
    }

    private func makeRemotelyHalfClosedInboundChannel(id: UInt32) -> ChildChannelStateMachine {
        Self.makeRemotelyHalfClosedInboundChannel(id: id)
    }
}
