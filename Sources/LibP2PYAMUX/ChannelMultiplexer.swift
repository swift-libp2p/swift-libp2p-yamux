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

import LibP2P
import NIOCore

/// An object that controls multiplexing messages to multiple child channels.
final class ChannelMultiplexer {

    internal var channels: [UInt32: YAMUXStream]

    /// The highest remotely-initiated stream id we've accepted.
    ///
    /// Yamux stream ids are monotonic and never reused, so any inbound `SYN` at or below this
    /// mark names a stream that's currently in use or already existed.
    ///
    /// Initializes to 0, stream 0 is yamux's reserved session id and is never a real stream.
    private var highestInboundChannelID: UInt32

    /// The main delegate (parent channel) that we write to and read from
    ///
    /// - Warning:This object can cause a reference cycle, so we require it to be optional so that we can break the cycle manually.
    private var delegate: MultiplexerDelegate?

    /// The next local channel ID to use.
    private var nextChannelID: UInt32

    private let allocator: ByteBufferAllocator

    private var childChannelInitializer: ChildChannel.Initializer?

    /// Whether new channels are allowed. Set to `false` once the parent channel is shut down at the TCP level.
    private var canCreateNewChannels: Bool

    /// Whether we're opperating as the client or server in this connection
    private var mode: LibP2PCore.Mode

    /// The Initial window size for each child channel
    private var initialWindowSize: UInt32

    /// The maximum number of concurrent remotely-initiated (inbound) streams we allow.
    ///
    /// The yamux spec recommends bounding the unacknowledged/inbound stream backlog to
    /// at most 256 to provide backpressure and mitigate denial-of-service attacks. When a
    /// peer tries to open more than this, we reset the new stream rather than allocate it.
    private let maxInboundStreams: Int

    /// The logger we'll pass into each child channel
    private var logger: Logger

    init(
        delegate: MultiplexerDelegate,
        allocator: ByteBufferAllocator,
        mode: LibP2PCore.Mode,
        initialWindowSize: UInt32,
        maxInboundStreams: Int = 64,
        logger: Logger,
        childChannelInitializer: ChildChannel.Initializer?
    ) {
        self.channels = [:]
        self.channels.reserveCapacity(8)
        self.highestInboundChannelID = 0
        self.delegate = delegate
        self.nextChannelID = mode == .initiator ? 1 : 2
        self.allocator = allocator
        self.mode = mode
        self.initialWindowSize = initialWindowSize
        self.maxInboundStreams = maxInboundStreams
        self.childChannelInitializer = childChannelInitializer
        self.canCreateNewChannels = true
        self.logger = logger
        self.logger[metadataKey: "YAMUX"] = .string("Muxer")
    }

    // Time to clean up. We drop references to things that may be keeping us alive.
    // Note that we don't drop the child channels because we expect that they'll be cleaning themselves up.
    func parentHandlerRemoved() {
        self.delegate = nil
        self.childChannelInitializer = nil
        self.canCreateNewChannels = false
    }
}

// MARK: Calls from child channels

extension ChannelMultiplexer {
    /// A `ChildChannel` has issued a write.
    func writeFromChannel(_ message: Frame, _ promise: EventLoopPromise<Void>?) {
        guard let delegate = self.delegate else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        delegate.writeFromChildChannel(message, promise)
    }

    /// A `ChildChannel` has issued a flush.
    func childChannelFlush() {
        // Nothing to do.
        guard let delegate = self.delegate else {
            return
        }

        delegate.flushFromChildChannel()
    }

    func childChannelClosed(channelID: UInt32) {
        // This should never return `nil`, but we don't want to assert on it because
        // even if the object was never in the map, nothing bad will happen: it's gone!
        if let s = self.channels.removeValue(forKey: channelID) {
            self.delegate?.childChannelRemoved(stream: s)
        } else {
            self.logger.warning("Removed unregistered child channel")
        }
    }

    func childChannelErrored(channelID: UInt32) {
        // This should never return `nil`, but we don't want to assert on it because
        // even if the object was never in the map, nothing bad will happen: it's gone!
        self.channels.removeValue(forKey: channelID)
    }
}

// MARK: Calls from YAMUX handlers.

extension ChannelMultiplexer {
    func receiveMessage(_ message: Message) throws {
        let channel: ChildChannel?

        switch message {
        case .channelOpen(let message):
            let newChannelID = message.senderChannel
            self.logger.trace("receiveMessage::channelOpen -> New Channel Requested with ID:\(newChannelID)")

            // If the channel open message is for an invalid channelID, we send a
            // reset to the remote.
            if let rejection = self.inboundChannelIDRejection(newChannelID) {
                self.logger.warning("receiveMessage::channelOpen -> Rejecting stream \(newChannelID): \(rejection.reason)")
                self.sendReset(channelID: newChannelID)
                return
            }

            self.logger.trace("receiveMessage::channelOpen -> Attempting to open new channel ID:\(newChannelID)")
            // Create / Open the new Channel
            channel = try self.openNewChannel(
                channelID: newChannelID,
                initializer: self.childChannelInitializer
            )
            // Only advance the mark once the stream really exists, so a failed allocation
            // doesn't burn the id.
            self.highestInboundChannelID = newChannelID

        case .channelOpenConfirmation(let message):
            channel = self.existingChannel(localID: message.recipientChannel)

        case .channelOpenFailure(let message):
            channel = self.existingChannel(localID: message.recipientChannel)

        case .channelClose(let message):
            channel = self.existingChannel(localID: message.recipientChannel)

        case .channelReset(let message):
            channel = self.existingChannel(localID: message.recipientChannel)

        case .channelWindowAdjust(let message):
            channel = self.existingChannel(localID: message.recipientChannel)

        case .channelData(let message):
            channel = self.existingChannel(localID: message.recipientChannel)

        default:
            // Not a channel message, we don't do anything more with this.
            self.logger.warning("Warning - Unsupported message type")
            self.logger.trace("\(message)")
            self.logger.trace("----")
            return
        }

        if let channel = channel {
            self.logger.trace("Sending message to channel")
            channel.receiveInboundMessage(message)
        } else {
            // A frame for a stream we no longer have, just drop it.
            self.logger.debug("Dropping frame for unknown or closed stream")
            self.logger.trace("\(message)")
            self.logger.trace("----")
        }
    }

    func createInboundChildChannel(
        channelID: UInt32,
        _ promise: EventLoopPromise<Channel>? = nil,
        _ channelInitializer: ChildChannel.Initializer?
    ) {
        do {
            guard let el = self.delegate?.channel?.eventLoop else {
                throw YAMUX.Error.channelSetupRejected(
                    reasonCode: 0,
                    reason: "Multiplexer lost reference to parent/delegate"
                )
            }
            // Ensure the proposed ChannelID is valid. This is a programmatic call rather than a
            // frame off the wire, so the refusal goes back through the promise, not as an RST.
            if let rejected = self.inboundChannelIDRejection(channelID) {
                throw YAMUX.Error.channelSetupRejected(reasonCode: 0, reason: rejected.reason)
            }
            // Open the Channel
            let channel = try self.openNewChannel(
                channelID: channelID,
                initializer: channelInitializer ?? childChannelInitializer
            )
            // This registers an inbound id, so it has to move the mark too — otherwise a later
            // SYN from the peer for the same id would sail past `inboundChannelIDRejection`.
            self.highestInboundChannelID = channelID

            let channelConfigPromise = el.makePromise(of: Channel.self)

            channel.configure(userPromise: channelConfigPromise)

            promise?.completeWith(
                channelConfigPromise.futureResult.map { _ in
                    let s = self.channels[channelID]!
                    // inform our delegate
                    self.delegate?.childChannelCreated(stream: s)
                    // Return the stream
                    return s._channel
                }
            )
        } catch {
            promise?.fail(error)
        }
    }

    func createOutboundChildChannel(
        _ promise: EventLoopPromise<YAMUXStream>? = nil,
        _ channelInitializer: ChildChannel.Initializer?
    ) {
        do {
            guard let el = self.delegate?.channel?.eventLoop else {
                throw YAMUX.Error.channelSetupRejected(
                    reasonCode: 0,
                    reason: "Multiplexer lost reference to parent/delegate"
                )
            }

            let channelID = self.nextChannelID
            self.nextChannelID &+= 2

            if self.nextChannelID >= UInt32.max - 1 {
                throw YAMUX.Error.channelSetupRejected(reasonCode: 0, reason: "Stream Count Exhaustion")
            }

            let channel = try self.openNewChannel(channelID: channelID, initializer: channelInitializer)

            let channelConfigPromise = el.makePromise(of: Channel.self)

            channel.configure(userPromise: channelConfigPromise)

            promise?.completeWith(
                channelConfigPromise.futureResult.map { _ in
                    let s = self.channels[channelID]!
                    // inform our delegate
                    self.delegate?.childChannelCreated(stream: s)
                    // Return the stream
                    return s
                }
            )
        } catch {
            promise?.fail(error)
        }
    }

    func parentChannelReadComplete() {
        // Iterate over a snapshot of our channels. Delivering reads can close or error a
        // child channel, which can mutate the list while we iterate over it.
        for channel in Array(self.channels.values) {
            channel._channel.receiveParentChannelReadComplete()
        }
    }

    func parentChannelInactive() {
        self.canCreateNewChannels = false
        // Iterate over a snapshot of our channels.
        for channel in Array(self.channels.values) {
            channel._channel.parentChannelInactive()
        }
    }

    func shouldQuiesce(on el: EventLoop) -> EventLoopFuture<Void> {
        // Stop accepting new channels
        self.canCreateNewChannels = false

        // Loop through our current child channels and issue closes on them.
        var tasks: [EventLoopFuture<Void>] = []
        // Iterate over a snapshot of our channels.
        for channel in Array(self.channels.values) {
            let _ = channel.close(gracefully: true)
            tasks.append(channel._channel.closeFuture)
        }

        // return the future result of the close calls
        return tasks.flatten(on: el)
    }

    /// Whether `id` belongs to a remotely-initiated (inbound) stream, per yamux's
    /// parity rule: the initiator uses odd ids, the listener even.
    private func isInboundChannelID(_ id: UInt32) -> Bool {
        self.mode == .initiator ? id.isEven : id.isOdd
    }

    /// The number of currently-open remotely-initiated (inbound) streams.
    private var inboundStreamCount: Int {
        self.channels.keys.lazy.filter { self.isInboundChannelID($0) }.count
    }

    /// Sends a stream `RST` (reset) to the peer for the given channel id.
    private func sendReset(channelID: UInt32) {
        guard let delegate = self.delegate else { return }
        let frame = Frame(
            header: Header(version: .v0, messageType: .windowUpdate, flags: [.reset], streamID: channelID, length: 0)
        )
        delegate.writeFromChildChannel(frame, nil)
        delegate.flushFromChildChannel()
    }

    enum InvalidChannelID {
        case incorrectParity
        case alreadyUsed(UInt32)
        case exceedsMaximum
        
        var reason: String {
            switch self {
            case .incorrectParity:
                "incorrect stream id parity"
            case .alreadyUsed(let id):
                "stream id already used (highest accepted: \(id))"
            case .exceedsMaximum:
                "inbound stream limit reached"
            }
        }
    }
    
    /// Why we can't accept a remotely-initiated stream with this id, or `nil` if we can.
    ///
    /// Returning a reason rather than throwing is deliberate: the caller decides how to refuse
    /// (`receiveMessage` sends the peer an RST; `createInboundChildChannel` fails its promise).
    private func inboundChannelIDRejection(_ id: UInt32) -> InvalidChannelID? {
        // Ensure the ChannelID has the correct polarity.
        guard self.isInboundChannelID(id) else {
            return .incorrectParity
        }
        // Ids must increase.
        guard id > self.highestInboundChannelID else {
            return .alreadyUsed(self.highestInboundChannelID)
        }
        // Bound the inbound-stream backlog (yamux spec DoS mitigation).
        guard self.inboundStreamCount < self.maxInboundStreams else {
            return .exceedsMaximum
        }
        return nil
    }

    /// Opens a new channel and adds it to the multiplexer.
    private func openNewChannel(channelID: UInt32, initializer: ChildChannel.Initializer?) throws -> ChildChannel {
        guard let parentChannel = self.delegate?.channel else {
            throw YAMUX.Error.protocolViolation(
                protocolName: "channel",
                violation: "Opening new channel after channel shutdown"
            )
        }

        guard self.canCreateNewChannels else {
            throw YAMUX.Error.tcpShutdown
        }

        // Determine this streams direction / mode
        let direction: LibP2P.Mode
        switch mode {
        case .listener:
            direction = (channelID % 2 == 0) ? .initiator : .listener
        case .initiator:
            direction = (channelID % 2 == 0) ? .listener : .initiator
        }

        // Create the ChildChannel
        let channel = ChildChannel(
            allocator: self.allocator,
            parent: parentChannel,
            multiplexer: self,
            initializer: initializer,
            localChannelID: channelID,
            targetWindowSize: Int32(self.initialWindowSize),
            initialOutboundWindowSize: self.initialWindowSize,
            direction: direction,
            logger: logger
        )

        // Init our Libp2p Stream
        let stream = YAMUXStream(
            channel: channel,
            mode: direction,
            id: UInt64(channelID),
            name: nil,
            proto: "",
            streamState: .initialized
        )

        // Store / register it
        self.channels[channelID] = stream

        return channel
    }

    /// The child channel for `localID`, or `nil` when we have no such stream.
    ///
    /// A miss shouldn't be fatal. Stream ids are monotonic and never reused, so a frame for
    /// an id we don't hold can only be a late frame for a stream that's already gone. Yamux
    /// spec says we can just drop the frame.
    private func existingChannel(localID: UInt32) -> ChildChannel? {
        self.channels[localID]?._channel
    }
}

extension UInt32 {
    var isEven: Bool {
        self % 2 == 0
    }

    var isOdd: Bool {
        !self.isEven
    }
}

/// An internal protocol to encapsulate the object that owns the multiplexer.
protocol MultiplexerDelegate {
    var channel: Channel? { get }

    func writeFromChildChannel(_: Frame, _: EventLoopPromise<Void>?)

    func flushFromChildChannel()

    func childChannelCreated(stream: any LibP2PCore._Stream)

    func childChannelRemoved(stream: any LibP2PCore._Stream)
}
