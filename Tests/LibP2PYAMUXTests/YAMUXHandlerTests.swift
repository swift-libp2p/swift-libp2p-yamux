//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore
import NIOEmbedded
import XCTest

@testable import LibP2P

class YAMUXHandlerTests: XCTestCase {
    func testHandlerInitializationOnAdd_WhenListener() throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .inbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Activate the channel
        _ = try channel.connect(to: .init(unixDomainSocketPath: "/foo"))

        // Add our handler to the already activated channel
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        // Ensure we emit the Session Open message
        XCTAssertEqual(
            try channel.readOutbound(as: Frame.self),
            .init(header: .init(version: .v0, messageType: .windowUpdate, flags: [.syn], streamID: 0, length: 0))
        )
    }
    
    func testHandlerInitializationOnAdd_WhenInitiator() throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .outbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Activate the channel
        _ = try channel.connect(to: .init(unixDomainSocketPath: "/foo"))

        // Add our handler to the already activated channel
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        XCTAssertNil(
            try channel.readOutbound(as: Frame.self)
        )
    }

    func testHandlerInitializationActive_WhenListener() throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .inbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Add our handler to the inactive channel
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        // Ensure we can't read
        XCTAssertNil(try channel.readOutbound())

        // Activate the channel
        _ = try channel.connect(to: .init(unixDomainSocketPath: "/foo"))
        // Ensure we emit the Session Open message
        XCTAssertEqual(
            try channel.readOutbound(as: Frame.self),
            .init(header: .init(version: .v0, messageType: .windowUpdate, flags: [.syn], streamID: 0, length: 0))
        )
    }
    
    func testHandlerInitializationActive_WhenInitiator() throws {
        let peerID = try PeerID(.Ed25519)
        let connection = LibP2P.DummyConnection(peer: peerID, direction: .outbound)
        let channel = connection.channel as! EmbeddedChannel
        let promise = channel.eventLoop.makePromise(of: Muxer.self)
        let handler = YAMUXHandler(connection: connection, muxedPromise: promise, supportedProtocols: [])

        // Add our handler to the inactive channel
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        // Ensure we can't read
        XCTAssertNil(try channel.readOutbound())

        // Activate the channel
        _ = try channel.connect(to: .init(unixDomainSocketPath: "/foo"))
        // Ensure we emit the Session Open message
        XCTAssertNil(
            try channel.readOutbound(as: Frame.self),
        )
    }
    
}