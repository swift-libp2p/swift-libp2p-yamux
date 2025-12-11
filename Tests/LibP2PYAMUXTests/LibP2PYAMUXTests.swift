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
import LibP2PNoise
import NIOTestUtils
import Testing

@testable import LibP2PYAMUX

@Suite("Yamux Tests", .serialized)
struct LibP2PYAMUXTests {

    @Test(.timeLimit(.minutes(1)))
    func testLibP2PInternalEchoMultiaddr() async throws {
        // Construct our Host instance
        let host = makeEchoHost()

        // Construct our Client instance
        let client = makeClient()

        // Start our libp2p instances
        try await host.startup()
        try await client.startup()

        let hostAddress = try #require(
            try host.listenAddresses.first?.encapsulate(
                proto: .p2p,
                address: host.peerID.traditionalB58String()
            )
        )

        let clientAddress = try #require(
            try client.listenAddresses.first?.encapsulate(
                proto: .p2p,
                address: client.peerID.traditionalB58String()
            )
        )

        #expect(try hostAddress.decapsulate(.p2p) == Multiaddr("/ip4/127.0.0.1/tcp/10000"))
        #expect(try clientAddress.decapsulate(.p2p) == Multiaddr("/ip4/127.0.0.1/tcp/10001"))

        let echoResponseExpectation = AsyncSemaphore(value: 0)

        // Have the client dial the host
        let echoMessage = "Hello from swift libp2p!"
        client.newRequest(
            to: hostAddress,
            forProtocol: "/echo/1.0.0",
            withRequest: Data(echoMessage.utf8),
            withHandlers: .handlers([.newLineDelimited]),
            withTimeout: .seconds(4)
        ).whenComplete { result in
            switch result {
            case .failure(let error):
                Issue.record("\(error)")
            case .success(let response):
                guard let str = String(data: Data(response), encoding: .utf8) else {
                    Issue.record("Failed to decode response data")
                    break
                }
                #expect(str == "Hello from swift libp2p!")
                #expect(str == echoMessage)
            }
            echoResponseExpectation.signal()
        }

        await echoResponseExpectation.wait()

        try await Task.sleep(for: .milliseconds(50))

        print("🔀🔀🔀 Client Connections 🔀🔀🔀")
        let clientConnections1 =
            (try? await client.connections.getConnectionsToPeer(peer: host.peerID, on: nil).get()) ?? []
        #expect(clientConnections1.count == 1)
        for connection in clientConnections1 {
            print(connection)
            #expect(connection.remotePeer == host.peerID)
            #expect(connection.remoteAddr == hostAddress)
            #expect(connection.direction == .outbound)
            #expect(connection.mode == .initiator)
            #expect(connection.isMuxed == true)
        }

        print("🔀🔀🔀 Host Connections 🔀🔀🔀")
        let hostConnections1 =
            (try? await host.connections.getConnectionsToPeer(peer: client.peerID, on: nil).get()) ?? []
        #expect(hostConnections1.count == 1)
        for connection in hostConnections1 {
            print(connection)
            #expect(connection.remotePeer == client.peerID)
            #expect(connection.direction == .inbound)
            #expect(connection.mode == .listener)
            #expect(connection.isMuxed == true)
        }

        try await Task.sleep(for: .milliseconds(500))

        // After 500ms of inactivity our connections between our peers should be pruned
        let clientConnections2 =
            (try? await client.connections.getConnectionsToPeer(peer: host.peerID, on: nil).get()) ?? []
        #expect(clientConnections2.count == 0)
        let hostConnections2 =
            (try? await host.connections.getConnectionsToPeer(peer: client.peerID, on: nil).get()) ?? []
        #expect(hostConnections2.count == 0)

        host.connections.dumpConnectionHistory()
        client.connections.dumpConnectionHistory()

        try await Task.sleep(for: .milliseconds(50))

        try await client.asyncShutdown()
        try await host.asyncShutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func testLibP2PInternalEchoMultiaddr_ConnectionReuse_Sequential() async throws {
        // Construct our Host instance
        let host = makeEchoHost()

        // Construct our Client instance
        let client = makeClient()

        // Start our libp2p instances
        try await host.startup()
        try await client.startup()

        let hostAddress = try #require(
            try host.listenAddresses.first?.encapsulate(
                proto: .p2p,
                address: host.peerID.traditionalB58String()
            )
        )

        let clientAddress = try #require(
            try client.listenAddresses.first?.encapsulate(
                proto: .p2p,
                address: client.peerID.traditionalB58String()
            )
        )

        #expect(try hostAddress.decapsulate(.p2p) == Multiaddr("/ip4/127.0.0.1/tcp/10000"))
        #expect(try clientAddress.decapsulate(.p2p) == Multiaddr("/ip4/127.0.0.1/tcp/10001"))

        let numberOfSequentialRequests = 10

        for _ in 0..<numberOfSequentialRequests {
            let echoResponseExpectation = AsyncSemaphore(value: 0)

            // Have the client dial the host
            let echoMessage = "Hello from swift libp2p!"
            client.newRequest(
                to: hostAddress,
                forProtocol: "/echo/1.0.0",
                withRequest: Data(echoMessage.utf8),
                withHandlers: .handlers([.newLineDelimited]),
                withTimeout: .seconds(4)
            ).whenComplete { result in
                switch result {
                case .failure(let error):
                    Issue.record("\(error)")
                case .success(let response):
                    guard let str = String(data: Data(response), encoding: .utf8) else {
                        Issue.record("Failed to decode response data")
                        break
                    }
                    #expect(str == "Hello from swift libp2p!")
                    #expect(str == echoMessage)
                    print(str)
                }
                echoResponseExpectation.signal()
            }

            await echoResponseExpectation.wait()
        }

        // We should still only have one connection after the second request
        let clientConnections1 =
            (try? await client.connections.getConnectionsToPeer(peer: host.peerID, on: nil).get()) ?? []
        #expect(clientConnections1.count == 1)
        for connection in clientConnections1 {
            #expect(connection.remotePeer == host.peerID)
            #expect(connection.remoteAddr == hostAddress)
            #expect(connection.direction == .outbound)
            #expect(connection.mode == .initiator)
            #expect(connection.isMuxed == true)
            #expect(connection.state == .muxed)
            //#expect(connection.streams.count == numberOfSequentialRequests + 2)
        }

        let hostConnections1 =
            (try? await host.connections.getConnectionsToPeer(peer: client.peerID, on: nil).get()) ?? []
        #expect(hostConnections1.count == 1)
        for connection in hostConnections1 {
            #expect(connection.remotePeer == client.peerID)
            #expect(connection.direction == .inbound)
            #expect(connection.mode == .listener)
            #expect(connection.isMuxed == true)
            #expect(connection.state == .muxed)
            //#expect(connection.streams.count == numberOfSequentialRequests + 2)
        }

        try await Task.sleep(for: .milliseconds(500))

        // After 500ms of inactivity our connections between our peers should be pruned
        let clientConnections2 =
            (try? await client.connections.getConnectionsToPeer(peer: host.peerID, on: nil).get()) ?? []
        #expect(clientConnections2.count == 0)

        let hostConnections2 =
            (try? await host.connections.getConnectionsToPeer(peer: client.peerID, on: nil).get()) ?? []
        #expect(hostConnections2.count == 0)

        try await Task.sleep(for: .milliseconds(50))

        try await client.asyncShutdown()
        try await host.asyncShutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func testLibP2PInternalEchoMultiaddr_ConnectionReuse_Concurrent() async throws {
        // Construct our Host instance
        let host = makeEchoHost()

        // Construct our Client instance
        let client = makeClient()

        // Start our libp2p instances
        try await host.startup()
        try await client.startup()

        let hostAddress = try #require(
            try host.listenAddresses.first?.encapsulate(
                proto: .p2p,
                address: host.peerID.traditionalB58String()
            )
        )

        let clientAddress = try #require(
            try client.listenAddresses.first?.encapsulate(
                proto: .p2p,
                address: client.peerID.traditionalB58String()
            )
        )

        #expect(try hostAddress.decapsulate(.p2p) == Multiaddr("/ip4/127.0.0.1/tcp/10000"))
        #expect(try clientAddress.decapsulate(.p2p) == Multiaddr("/ip4/127.0.0.1/tcp/10001"))

        func performEcho() async throws -> String {
            // Have the client dial the host
            let echoMessage = "Hello from swift libp2p!"
            let response = try await client.newRequest(
                to: hostAddress,
                forProtocol: "/echo/1.0.0",
                withRequest: Data(echoMessage.utf8),
                withHandlers: .handlers([.newLineDelimited]),
                withTimeout: .seconds(4)
            ).get()

            guard let str = String(data: Data(response), encoding: .utf8) else {
                throw NSError(domain: "Failed to decode response data", code: 0)
            }
            #expect(str == "Hello from swift libp2p!")
            #expect(str == echoMessage)
            return str
        }

        async let res1 = performEcho()
        async let res2 = performEcho()
        async let res3 = performEcho()

        let responses = try await (res1, res2, res3)

        print(responses)

        // We should still only have one connection after the second request
        let clientConnections1 =
            (try? await client.connections.getConnectionsToPeer(peer: host.peerID, on: nil).get()) ?? []
        withKnownIssue {
            #expect(clientConnections1.count == 1)
        }
        for connection in clientConnections1 {
            #expect(connection.remotePeer == host.peerID)
            #expect(connection.remoteAddr == hostAddress)
            #expect(connection.direction == .outbound)
            #expect(connection.mode == .initiator)
            #expect(connection.isMuxed == true)
            #expect(connection.state == .muxed)
            //#expect(connection.streams.count == numberOfSequentialRequests + 2)
        }

        let hostConnections1 =
            (try? await host.connections.getConnectionsToPeer(peer: client.peerID, on: nil).get()) ?? []
        withKnownIssue {
            #expect(hostConnections1.count == 1)
        }
        for connection in hostConnections1 {
            #expect(connection.remotePeer == client.peerID)
            #expect(connection.direction == .inbound)
            #expect(connection.mode == .listener)
            #expect(connection.isMuxed == true)
            #expect(connection.state == .muxed)
            //#expect(connection.streams.count == numberOfSequentialRequests + 2)
        }

        try await Task.sleep(for: .milliseconds(500))

        // After 500ms of inactivity our connections between our peers should be pruned
        let clientConnections2 =
            (try? await client.connections.getConnectionsToPeer(peer: host.peerID, on: nil).get()) ?? []
        #expect(clientConnections2.count == 0)

        let hostConnections2 =
            (try? await host.connections.getConnectionsToPeer(peer: client.peerID, on: nil).get()) ?? []
        #expect(hostConnections2.count == 0)

        try await Task.sleep(for: .milliseconds(50))

        try await client.asyncShutdown()
        try await host.asyncShutdown()
    }

    @Test(.timeLimit(.minutes(1)), .externalIntegrationTestsEnabled)
    func testLibP2PExternalGoEcho_Dialer() async throws {

        // Construct our Client instance
        let client = Application(.testing)
        client.servers.use(.tcp(host: "127.0.0.1", port: 10001))
        client.security.use(.noise)
        client.muxers.use(.yamux)
        client.logger.logLevel = .trace

        //client.connectionManager.use(connectionType: BasicConnectionLight.self)

        // Start our libp2p instance
        try await client.startup()

        #expect(try client.listenAddresses.first == Multiaddr("/ip4/127.0.0.1/tcp/10001"))

        //let echoResponseExpectation = expectation(description: "Echo Response Expectation")
        let echoResponseExpectation = AsyncSemaphore(value: 0)
        //let echoResponseExpectation2 = expectation(description: "Echo Response Expectation 2")
        let echoResponseExpectation2 = AsyncSemaphore(value: 0)

        let host = try Multiaddr("/ip4/127.0.0.1/tcp/10000/p2p/QmZLx897cqUUwcH5wkLTZiXShQBmrcWtStyEEDgggERPp1")

        // Have the client dial the host
        let echoMessage = "Hello from swift libp2p!"
        //let echoMessage = Array<String>(repeating: "H", count: 1024*64) // Fails somewhere between *32 & *64
        client.newRequest(
            to: host,
            forProtocol: "/echo/1.0.0",
            withRequest: Data(echoMessage.utf8),
            withHandlers: .handlers([.newLineDelimited]),
            withTimeout: .seconds(4)
        ).whenComplete { result in
            switch result {
            case .failure(let error):
                Issue.record("\(error)")
            case .success(let response):
                guard let str = String(data: Data(response), encoding: .utf8) else {
                    Issue.record("Failed to decode response data")
                    break
                }
                print("🥳 Got our echo response 🥳")
                print(str)
                print("---------------------------")
                #expect(str == "Hello from swift libp2p!")
            }
            echoResponseExpectation.signal()
        }

        try await Task.sleep(for: .milliseconds(100))

        // After 50ms we should have some active connections to between our peers
        print("🔀🔀🔀 Connections Between Peers 🔀🔀🔀")
        let clientConnections1 =
            (try? await client.connections.getConnectionsToPeer(peer: host.getPeerID(), on: nil).get()) ?? []
        #expect(clientConnections1.count == 1)
        for connection in clientConnections1 {
            print(connection)
        }
        print("----------------------------------------")

        try await Task.sleep(for: .milliseconds(50))

        // This request should reuse the current connection
        //let echoMessage2 = Array<String>(repeating: "Hello from swift libp2p!", count: 1024*16).joined() // Fails somewhere between *32 & *64
        client.newRequest(
            to: host,
            forProtocol: "/echo/1.0.0",
            withRequest: Data(echoMessage.utf8),
            withHandlers: .handlers([.newLineDelimited]),
            withTimeout: .seconds(4)
        ).whenComplete { result in
            switch result {
            case .failure(let error):
                Issue.record("\(error)")
            case .success(let response):
                guard let str = String(data: Data(response), encoding: .utf8) else {
                    Issue.record("Failed to decode response data")
                    break
                }
                print("🥳 Got our echo response 2 🥳")
                print(str)
                print("---------------------------")
                #expect(str == echoMessage)
            }
            echoResponseExpectation2.signal()
        }

        print("🔀🔀🔀 Connections Between Peers 🔀🔀🔀")
        let clientConnections2 =
            (try? await client.connections.getConnectionsToPeer(peer: host.getPeerID(), on: nil).get()) ?? []
        #expect(clientConnections2.count == 1)
        for connection in clientConnections2 {
            print(connection)
        }
        print("----------------------------------------")

        await echoResponseExpectation.wait()
        await echoResponseExpectation2.wait()

        try await Task.sleep(for: .milliseconds(1000))
        //try await client.connections.closeAllConnections().get()

        // After 500ms of inactivity our connections between our peers should be pruned
        print("🔀🔀🔀 Connections Between Peers 🔀🔀🔀")
        let clientConnections3 =
            (try? await client.connections.getConnectionsToPeer(peer: host.getPeerID(), on: nil).get()) ?? []
        #expect(clientConnections3.count == 0)
        for connection in clientConnections3 {
            print(connection)
        }
        print("----------------------------------------")

        //try await Task.sleep(for: .milliseconds(50))

        try await client.asyncShutdown()
    }

    @Test(.timeLimit(.minutes(1)), .externalIntegrationTestsEnabled)
    func testLibP2PExternalGoEcho_Listener() async throws {

        // Construct our Client instance
        let host = Application(.testing)
        host.servers.use(.tcp(host: "127.0.0.1", port: 10000))
        host.security.use(.noise)
        host.muxers.use(.yamux)
        host.logger.logLevel = .trace

        let echoExpectation = AsyncSemaphore(value: 0)

        // Register a route handler on our host
        // /echo/1.0.0 will echo inbound data delimited by newline characters
        host.routes.on("echo", "1.0.0", handlers: [.newLineDelimited]) { req -> Response<ByteBuffer> in
            print("Route Event: \(req.event)")
            switch req.event {
            case .ready:
                return .stayOpen
            case .data(let data):
                if let str = data.getString(at: data.readerIndex, length: data.readableBytes) {
                    print("Echoing Data: \(str)")
                } else {
                    print("Received data that's not a string -> \(data.readableBytesView)")
                }
                return .respondThenClose(data)
            case .closed:
                echoExpectation.signal()
                return .close
            case .error(let error):
                echoExpectation.signal()
                return .reset(error)
            }
        }

        // Start our libp2p instance
        try await host.startup()

        #expect(try host.listenAddresses.first == Multiaddr("/ip4/127.0.0.1/tcp/10000"))

        let listenAddresses = try host.listenAddresses.first!.encapsulate(proto: .p2p, address: host.peerID.b58String)
        print("Now run the following in the go-libp2p/examples/echo directory")
        print("./echo -l 10001 -d \(listenAddresses)")
        print("")

        await echoExpectation.wait()

        try await Task.sleep(for: .milliseconds(50))

        try await host.asyncShutdown()
    }
}

extension LibP2PYAMUXTests {
    func makeEchoHost(
        port: Int = 10_000,
        logLevel: Logger.Level = .info,
        connectionType: AppConnection.Type = ARCConnection.self
    ) -> Application {
        let host = Application(.testing)
        host.servers.use(.tcp(host: "127.0.0.1", port: port))
        host.security.use(.noise)
        host.muxers.use(.yamux)
        host.logger.logLevel = logLevel

        host.connectionManager.use(connectionType: connectionType)

        host.routes.on("echo", "1.0.0", handlers: [.newLineDelimited]) { req -> Response<ByteBuffer> in
            switch req.event {
            case .ready: return .stayOpen
            case .data(let data): return .respondThenClose(data)
            case .closed, .error: return .close
            }
        }

        return host
    }

    func makeClient(
        port: Int = 10_001,
        logLevel: Logger.Level = .info,
        connectionType: AppConnection.Type = ARCConnection.self
    ) -> Application {
        let client = Application(.testing)
        client.servers.use(.tcp(host: "127.0.0.1", port: port))
        client.security.use(.noise)
        client.muxers.use(.yamux)
        client.logger.logLevel = logLevel

        client.connectionManager.use(connectionType: connectionType)

        return client
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
