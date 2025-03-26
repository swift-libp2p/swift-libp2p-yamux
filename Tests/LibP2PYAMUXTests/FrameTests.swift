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
import XCTest

@testable import LibP2PYAMUX

final class FrameTests: XCTestCase {

    /// Header frame encoding / decoding
    func testFrameToMessages() throws {
        // Create a basic header frame
        var payload = ByteBuffer()
        payload.writeString("Hello World!")
        let header = Header(
            version: .v0,
            messageType: .data,
            flags: [.syn, .fin],
            streamID: 1,
            length: UInt32(payload.readableBytes)
        )
        let frame = Frame(header: header, payload: payload)

        // To messages
        XCTAssertEqual(
            frame.messages,
            [.newStream, .data(payload: payload), .close]
        )

        // Serialize
        var wireBuffer = ByteBuffer()
        wireBuffer.write(frame: frame)

        // Ensure the header encoded within 12 bytes
        XCTAssertEqual(wireBuffer.readableBytes, 12 + Int(header.length))
        // Ensure all bytes are 0 for this particular header
        XCTAssertEqual(
            wireBuffer.readableBytesView.withUnsafeBytes { Array($0) },
            [0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 12] + [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33]
        )

        let recoveredFrame = try wireBuffer.readFrame()

        XCTAssertEqual(recoveredFrame.header, header)
        XCTAssertEqual(recoveredFrame.payload, payload)
        XCTAssertEqual(
            recoveredFrame.messages,
            [.newStream, .data(payload: payload), .close]
        )
        XCTAssertEqual(wireBuffer.readableBytes, 0)
    }

    /// Header frame encoding / decoding
    func testFrameToMessages2() throws {
        // Create a basic header frame
        let payload = ByteBuffer(string: "Hello World!")
        let frame = try Frame(streamID: 1, message: .data(payload: payload), additionalFlags: [.syn, .fin])

        // To messages
        XCTAssertEqual(
            frame.messages,
            [.newStream, .data(payload: payload), .close]
        )

        // Serialize
        var wireBuffer = ByteBuffer()
        wireBuffer.write(frame: frame)

        // Ensure the header encoded within 12 bytes
        XCTAssertEqual(wireBuffer.readableBytes, 12 + Int(frame.header.length))
        // Ensure all bytes are 0 for this particular header
        XCTAssertEqual(
            wireBuffer.readableBytesView.withUnsafeBytes { Array($0) },
            [0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 12] + [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33]
        )

        let recoveredFrame = try wireBuffer.readFrame()

        XCTAssertEqual(recoveredFrame.header, frame.header)
        XCTAssertEqual(recoveredFrame.payload, payload)
        XCTAssertEqual(
            recoveredFrame.messages,
            [.newStream, .data(payload: payload), .close]
        )
        XCTAssertEqual(wireBuffer.readableBytes, 0)
    }

    /// Header frame encoding / decoding
    func testFrameToMessages_AddFlags() throws {
        // Create a basic header frame
        let payload = ByteBuffer(string: "Hello World!")
        var frame = try Frame(streamID: 1, message: .data(payload: payload))
        frame.addFlag(.syn)
        frame.addFlag(.fin)

        // To messages
        XCTAssertEqual(
            frame.messages,
            [.newStream, .data(payload: payload), .close]
        )

        // Attempt to add a duplicate flag
        frame.addFlag(.syn)

        // Ensure we can't add duplicate flags
        XCTAssertEqual(
            frame.messages,
            [.newStream, .data(payload: payload), .close]
        )

        // Add another flag
        frame.addFlag(.ack)

        // Ensure we can't add duplicate flags
        XCTAssertEqual(
            frame.messages,
            [.newStream, .openConfirmation, .data(payload: payload), .close]
        )

        // Add another flag
        frame.addFlag(.reset)

        // Ensure we can't add duplicate flags
        XCTAssertEqual(
            frame.messages,
            [.newStream, .openConfirmation, .data(payload: payload), .close, .reset]
        )
    }
}
