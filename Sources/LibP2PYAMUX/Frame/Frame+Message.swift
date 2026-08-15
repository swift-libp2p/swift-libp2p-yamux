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

extension Frame {
    var messages: [Message] {
        [Message](frame: self).sorted { lhs, rhs in
            lhs.rank < rhs.rank
        }
    }
}

extension Array where Element == Message {
    init(frame: Frame) {
        self = []

        if frame.header.streamID == 0 {

            switch frame.header.messageType {
            case .ping:
                // Every stream-0 ping frame is a yamux ping
                self.append(
                    .ping(.init(payload: frame.header.length, isResponse: frame.header.flags.contains(.ack)))
                )

            case .goAway:
                let netError = YAMUX.NetworkError(networkCode: Int(frame.header.length))
                self.append(
                    .disconnect(.init(reason: netError.code, description: "Session GoAway", tag: "\(netError)"))
                )

            default:
                print("INVALID FRAME MESSAGE ON SESSION CHANNEL")
                print("\(frame)")
                print("----------------------------------------")
            }

        } else {
            for flag in frame.header.flags {
                switch flag {
                case .syn:
                    self.append(
                        .channelOpen(
                            .init(
                                senderChannel: frame.header.streamID,
                                initialWindowSize: 0,
                                maximumPacketSize: YAMUXHandler.initialWindowSize
                            )
                        )
                    )
                case .ack:
                    self.append(
                        .channelOpenConfirmation(
                            .init(
                                recipientChannel: frame.header.streamID,
                                senderChannel: frame.header.streamID,
                                initialWindowSize: 0,
                                maximumPacketSize: YAMUXHandler.initialWindowSize
                            )
                        )
                    )
                default:
                    continue
                }
            }

            switch frame.header.messageType {
            case .data:
                if frame.header.length > 0, let payload = frame.payload {
                    self.append(.channelData(.init(recipientChannel: frame.header.streamID, data: payload)))
                }

            case .windowUpdate:
                if frame.header.length > 0 {
                    self.append(
                        .channelWindowAdjust(
                            .init(recipientChannel: frame.header.streamID, bytesToAdd: frame.header.length)
                        )
                    )
                }

            default:
                print("INVALID FRAME MESSAGE ON CHILD CHANNEL")
                print("\(frame)")
                print("--------------------------------------")
            }

            for flag in frame.header.flags {
                switch flag {
                case .fin:
                    self.append(.channelClose(.init(recipientChannel: frame.header.streamID)))
                case .reset:
                    self.append(
                        .channelReset(
                            .init(
                                recipientChannel: frame.header.streamID,
                                reasonCode: YAMUX.NetworkError.noError.code,
                                description: "Stream Reset"
                            )
                        )
                    )
                default:
                    continue
                }
            }
        }
    }
}
