import XCTest
@testable import WePlay

final class ProtocolTests: XCTestCase {
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
        var ids: [UInt16] = []
        parser.onMessage = { ids.append($0.id) }

        parser.append(packet)

        XCTAssertEqual(ids, [0x0021, 0x0023])
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
