//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A state machine that manages the state of child channels.
///
/// Child channels move through a weird set of states, because they can "exist" before the protocol is aware of them. In particular, there
/// are a few strange states that don't correspond to what the wire protocol looks like.
struct ChildChannelStateMachine {
    private var state: State
    private var channelID: UInt32

    init(localChannelID: UInt32) {
        self.state = .idle
        self.channelID = localChannelID
    }
}

extension ChildChannelStateMachine {
    typealias ChannelIdentifier = UInt32
    fileprivate enum State: Hashable {
        /// `idle` represents a child channel that has been allocated locally, but where we haven't asked the wire
        /// protocol to do anything with it yet: that is, we have not requested the channel. Such a channel is purely
        /// virtual. It exists only because we're attempting to start a channel locally and we haven't configured it yet.
        case idle

        /// `requestedLocally` is a channel for which we have sent a channel request, but haven't received a response yet.
        /// This channel is "active on the network" in the sense that the remote peer will come to know of its existence,
        /// but it's not yet a real channel that can perform any kind of I/O, so from the perspective of the user of the
        /// channel this channel isn't active yet.
        case requestedLocally

        /// `requestedRemotely` is a channel for which the remote peer has sent a channel request, but we have not yet
        /// responded. This channel is also "active on the network" in the sense that if our initialization fails we have
        /// to take some kind of action to terminate this channel. However, this channel can't do I/O yet, so from the perspective
        /// of the user of the channel this channel isn't active yet.
        case requestedRemotely

        /// `active` is a channel that has been both requested and accepted. Data can flow freely on this channel in both directions.
        /// We have neither sent nor received either a `CHANNEL_CLOSE` so all I/O is flowing appropriately.
        case active

        /// `closedRemotely` is a channel where the remote peer has sent `CHANNEL_CLOSE` but we have not yet sent `CHANNEL_CLOSE` back.
        case closedRemotely

        /// `closedLocally` is a channel where we have sent `CHANNEL_CLOSE` but have not yet received a `CHANNEL_CLOSE` back.
        case closedLocally

        /// `closed` is a channel where we have both sent and received `CHANNEL_CLOSE`.
        /// No further activity is possible. The channel identifier may now be re-used.
        case closed
    }
}

extension ChildChannelStateMachine {
    mutating func receive(frame: Frame) throws -> Frame? {
        guard frame.header.streamID == self.channelID else { throw YamuxError.streamIncorrectChannelID }
        var messages = frame.messages

        var responses: [Message] = []
        for message in messages {
            if let res = try self.receive(message: message) {
                responses.append(res)
            }
        }

        // TODO: Bundle responses into an outbound frame and return one if necessary
        return nil
    }

    mutating func receive(message: Message) throws -> Message? {
        switch (self.state, message) {
        // We received a newStream request from our peer
        case (.idle, .newStream):
            self.state = .requestedRemotely
            // We need to acknowledge the fact that we accepted the stream
            return .openConfirmation

        case (.active, .data(let payload)):
            print("Active -> Data")

        case (.active, .windowUpdate(let delta)):
            print("Active -> Window Update")

        case (.active, .ping(let payload)):
            guard channelID == 0 else { throw YamuxError.streamIncorrectChannelID }
            print("Received Ping[\(payload)]")
            return .ping(payload: payload)

        case (.active, .goAway(let errorCode)):
            guard channelID == 0 else { throw YamuxError.streamIncorrectChannelID }
            print("Received GoAway[\(errorCode)]")
            self.state = .closedRemotely

        case (.active, .close):
            self.state = .closedRemotely
            return .close

        case (.active, .reset):
            self.state = .closedRemotely
            return .close

        case (.closedLocally, .close):
            print("Fully Closed the Channel Cleanly")
            self.state = .closed

        case (.closedLocally, .reset):
            print("ClosedLocally -> Reset")
            // Do nothing?
            self.state = .closed

        default:
            throw YamuxError.invalidStreamStateTransition(state: "\(self.state)", message: message)
        }

        return nil
    }
}

// MARK: Helper computed properties

extension ChildChannelStateMachine {
    /// Whether this channel is currently active on the network.
    var isActiveOnNetwork: Bool {
        switch self.state {
        case .idle, .closed:
            return false
        case .requestedLocally, .requestedRemotely, .active, .closedLocally, .closedRemotely:
            return true
        }
    }

    /// Whether this channel is closed.
    var isClosed: Bool {
        switch self.state {
        case .closed:
            return true
        case .idle, .requestedLocally, .requestedRemotely, .active, .closedLocally, .closedRemotely:
            return false
        }
    }

    /// Whether `Channel.isActive` should be true.
    var isActiveOnChannel: Bool {
        switch self.state {
        case .active, .closedLocally, .closedRemotely:
            return true
        case .idle, .requestedLocally, .requestedRemotely, .closed:
            return false
        }
    }

    // Whether we've sent a channel close message.
    var sentClose: Bool {
        switch self.state {
        case .closedLocally, .closed:
            return true
        case .idle, .requestedLocally, .requestedRemotely, .active, .closedRemotely:
            return false
        }
    }

    // Whether we have activated yet.
    var awaitingActivation: Bool {
        switch self.state {
        case .idle, .requestedLocally, .requestedRemotely:
            return true

        case .active, .closedLocally, .closedRemotely, .closed:
            return false
        }
    }
}

extension ChildChannelStateMachine {
    /// An action to take in response to a specific operation.
    enum Action {
        /// Ignore this message: do nothing.
        case ignore

        /// The message should be processed as normal.
        case process
    }
}
