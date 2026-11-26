import XCTest
@testable import WePlay

final class ProtocolTests: XCTestCase {
    func testSYNTableParsesNegotiatedControlSession() throws {
        let payload = Data([
            1, 8, 0xFF, 0xFF, 0x03, 0xE8, 0x00, 0x0A, 30, 0,
            10, 0, 0,       // control session 10
            11, 2, 0,       // external accessory session 11
            12, 1, 0        // file/data session 12
        ])

        let syn = try LinkPacket.SYNParameters.parse(payload)

        XCTAssertEqual(syn.controlSessionID, 10)
        XCTAssertEqual(syn.entries.map(\.id), [10, 11, 12])
        XCTAssertEqual(syn.entries.map(\.type), [0, 2, 1])
        XCTAssertEqual(syn.raw, payload)
    }

    func testSYNTableRejectsDuplicateOrFlaggedEntries() {
        let duplicate = Data([1, 8, 0xFF, 0xFF, 0x03, 0xE8, 0x00, 0x0A, 30, 0,
                              10, 0, 0, 10, 2, 0])
        XCTAssertThrowsError(try LinkPacket.SYNParameters.parse(duplicate))

        let flagged = Data([1, 8, 0xFF, 0xFF, 0x03, 0xE8, 0x00, 0x0A, 30, 0,
                            10, 0x80, 0])
        XCTAssertThrowsError(try LinkPacket.SYNParameters.parse(flagged))
    }

    func testLinkParserUsesNegotiatedNonzeroControlSession() {
        let message = LinkMessage(id: 0x1D01,
                                  parameters: [LinkParameter(id: 1, string: "WePlay")]).encoded()
        let packet = LinkPacket(control: LinkPacket.controlACK, sequence: 1,
                                sessionID: 10, payload: message).encode()
        let parser = LinkParser()
        parser.controlSessionID = 10
        var ids: [UInt16] = []
        parser.onMessage = { ids.append($0.id) }

        parser.append(packet)

        XCTAssertEqual(ids, [0x1D01])
    }

    func testLinkParserDoesNotTreatOtherSessionAsControl() {
        let message = LinkMessage(id: 0x1D01).encoded()
        let packet = LinkPacket(control: LinkPacket.controlACK, sequence: 1,
                                sessionID: 11, payload: message).encode()
        let parser = LinkParser()
        parser.controlSessionID = 10
        var called = false
        parser.onMessage = { _ in called = true }

        parser.append(packet)

        XCTAssertFalse(called)
    }

    func testLinkParserCarriesMessageAcrossPackets() {
        let message = LinkMessage(id: 0x1D01, parameters: [
            LinkParameter(id: 1, string: "WePlay"),
            LinkParameter(id: 2, value: Data([0x01, 0x02]))
        ]).encoded()
        let split = message.count / 2
        let first = LinkPacket(control: LinkPacket.controlACK, sequence: 1,
                               sessionID: LinkPacket.controlSessionID,
                               payload: message.prefix(split)).encode()
        let second = LinkPacket(control: LinkPacket.controlACK, sequence: 2,
                                sessionID: LinkPacket.controlSessionID,
                                payload: message.dropFirst(split)).encode()
        let parser = LinkParser()
        parser.controlSessionID = LinkPacket.controlSessionID
        var messages: [LinkMessage] = []
        parser.onMessage = { messages.append($0) }

        parser.append(first)
        XCTAssertTrue(messages.isEmpty)
        parser.append(second)

        XCTAssertEqual(messages, [LinkMessage(id: 0x1D01, parameters: [
            LinkParameter(id: 1, string: "WePlay"),
            LinkParameter(id: 2, value: Data([0x01, 0x02]))
        ])])
    }

    func testLinkParserHandlesMultipleMessagesInOnePacket() {
        let first = LinkMessage(id: 0x0021, parameters: [
            LinkParameter(id: 0x000B, value: Data([0xAA]))
        ]).encoded()
        let second = LinkMessage(id: 0x0023, parameters: [
            LinkParameter(id: 0x000E, value: Data([0xBB, 0xCC]))
        ]).encoded()
        let packet = LinkPacket(control: LinkPacket.controlACK, sequence: 3,
                                sessionID: LinkPacket.controlSessionID,
                                payload: first + second).encode()
        let parser = LinkParser()
        parser.controlSessionID = LinkPacket.controlSessionID
        var ids: [UInt16] = []
        parser.onMessage = { ids.append($0.id) }

        parser.append(packet)

        XCTAssertEqual(ids, [0x0021, 0x0023])
    }

    func testLinkParserConsumesFragmentedPresenceBeforePacket() {
        let parser = LinkParser()
        var presenceCount = 0
        var packetCount = 0
        parser.onPresence = { presenceCount += 1 }
        parser.onPacket = { _ in packetCount += 1 }
        let packet = LinkPacket(control: LinkPacket.controlACK, sequence: 1).encode()
        let wire = LinkPacket.presence + packet

        parser.append(wire.prefix(3))
        XCTAssertEqual(presenceCount, 0)
        parser.append(wire.dropFirst(3))

        XCTAssertEqual(presenceCount, 1)
        XCTAssertEqual(packetCount, 1)
    }

    func testAuthenticationMessagesUseAAFamilyAndParameterZero() {
        let certificate = AccessoryMessages.authenticationCertificate(chain: Data([0xAA, 0xBB]))
        XCTAssertEqual(certificate.id, 0xAA01)
        XCTAssertEqual(certificate.parameters.map(\.id), [0])
        XCTAssertEqual(certificate.parameters.first?.value, Data([0xAA, 0xBB]))

        let response = AccessoryMessages.authenticationResponse(signature: Data([0xCC]))
        XCTAssertEqual(response.id, 0xAA03)
        XCTAssertEqual(response.parameters.map(\.id), [0])
        XCTAssertEqual(response.parameters.first?.value, Data([0xCC]))
    }

    func testRTSPStreamParserWaitsForContentLengthAndHandlesStickyResponses() throws {
        let body = "wfd_client_rtp_ports: RTP/AVP/UDP;unicast 19000 0\r\n"
        let response = "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let second = "RTSP/1.0 200 OK\r\nCSeq: 3\r\n\r\n"
        var parser = RTSPResponseStreamParser()
        let bytes = Data((response + second).utf8)

        let first = try parser.append(bytes.prefix(18))
        XCTAssertTrue(first.isEmpty)
        let result = try parser.append(bytes.dropFirst(18))

        XCTAssertEqual(result.map(\.cSeq), [2, 3])
        XCTAssertEqual(result[0].bodyParameters.first?.key, "wfd_client_rtp_ports")
        XCTAssertEqual(result[0].bodyParameters.first?.value, "RTP/AVP/UDP;unicast 19000 0")
    }

    func testRTSPStreamParserRejectsNegativeContentLength() {
        var parser = RTSPResponseStreamParser()
        let bytes = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: -1\r\n\r\n".utf8)

        XCTAssertThrowsError(try parser.append(bytes)) { error in
            XCTAssertEqual(error as? RTSPResponseError, .invalidContentLength)
        }
    }
}
