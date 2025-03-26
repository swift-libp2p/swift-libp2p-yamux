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

enum YamuxError: Error {
    case headerDecodingError
    case frameDecodingError
    case streamIncorrectChannelID
    case invalidStreamStateTransition(state: String, message: Message)
}
