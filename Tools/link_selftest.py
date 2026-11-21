"""Link 编解码的 Python 校准版：与 WePlay/Link/Link/*.swift 逐行对应。
用途：在没有 Mac 的情况下验证编解码 round-trip 与校验和算法。
跑法： python -I link_selftest.py
"""
import struct

SOP = bytes([0xFF, 0x5A])
SYN, ACK, EAK, RST, SLP = 0x80, 0x40, 0x20, 0x10, 0x08
HEADER = 9


def checksum(bs: bytes) -> int:
    """2 的补码和：covered + checksum ≡ 0 (mod 256)"""
    return (256 - (sum(bs) % 256)) % 256


def verify(covered: bytes, ck: int) -> bool:
    return (sum(covered) + ck) % 256 == 0


def encode_packet(control, sequence, session_id, payload=b""):
    # 总长先定下来（9 头 + 载荷 + 1 载荷校验），头校验必须覆盖真实长度
    total = HEADER + len(payload) + 1
    out = bytearray(SOP)
    out += struct.pack("<H", total)
    out.append(control)
    out.append(sequence)
    out += struct.pack("<H", session_id)    # 会话 ID 小端 16 位
    out.append(checksum(bytes(out[2:8])))   # 头校验覆盖 偏移2..7（6 字节，不含 SOP）
    out += payload
    out.append(checksum(payload))
    assert len(out) == total, (len(out), total)
    return bytes(out)


def decode_packet(data: bytes):
    if len(data) < HEADER:
        return ("needMore", None)
    if data[0:2] != SOP:
        return ("badSync", None)
    length = struct.unpack_from("<H", data, 2)[0]
    if length < HEADER + 1:
        return ("badSync", None)
    if len(data) < length:
        return ("needMore", None)
    control, seq = data[4], data[5]
    session = struct.unpack_from("<H", data, 6)[0]
    hdr_ck = data[8]
    if not verify(data[2:8], hdr_ck):
        return ("badSync", None)
    payload = data[HEADER:length - 1]
    if not verify(payload, data[length - 1]):
        return ("badSync", None)
    return ("packet", dict(control=control, sequence=seq, session=session,
                           payload=payload, consumed=length))


# ---------- 消息层 ----------
SOM = bytes([0x40, 0x40])


def encode_param(pid, value):
    return struct.pack("<H", pid) + value


def encode_message(mid, params):
    body = struct.pack("<H", mid)
    for pid, val in params:
        enc = encode_param(pid, val)
        body += struct.pack("<H", len(enc) + 2) + enc
    return SOM + struct.pack("<H", len(body)) + body


def parse_message(data):
    if len(data) < 6:
        return ("needMore", None)
    if data[0:2] != SOM:
        return ("badFormat", None)
    length = struct.unpack_from("<H", data, 2)[0]
    total = 4 + length
    if len(data) < total:
        return ("needMore", None)
    mid = struct.unpack_from("<H", data, 4)[0]
    params, off = [], 6
    while off < total:
        plen = struct.unpack_from("<H", data, off)[0]
        if plen < 2 or off + plen > total:
            return ("badFormat", None)
        pid = struct.unpack_from("<H", data, off + 2)[0]
        params.append((pid, data[off + 4:off + plen]))
        off += plen
    if off != total:
        return ("badFormat", None)
    return ("message", dict(id=mid, params=params, consumed=total))


# ---------- 自测 ----------
def main():
    ok = True

    # 1. 空载荷包 round-trip
    raw = encode_packet(ACK, 7, 0x0000)
    kind, pkt = decode_packet(raw)
    assert kind == "packet", kind
    assert pkt["control"] == ACK and pkt["sequence"] == 7 and pkt["session"] == 0
    assert pkt["payload"] == b"" and pkt["consumed"] == len(raw)
    print("1. 空载荷包 round-trip OK  (%d B, %s)" % (len(raw), raw.hex()))

    # 2. 带载荷包 round-trip
    payload = b"\xde\xad\xbe\xef"
    raw = encode_packet(ACK | SYN, 1, 0x0000, payload)
    kind, pkt = decode_packet(raw)
    assert kind == "packet" and pkt["payload"] == payload and pkt["consumed"] == len(raw)
    print("2. 带载荷包 round-trip OK  (%d B, %s)" % (len(raw), raw.hex()))

    # 3. 会话 ID 非零（EA 会话 0x0002）
    raw = encode_packet(ACK, 3, 0x0002, b"xy")
    kind, pkt = decode_packet(raw)
    assert kind == "packet" and pkt["session"] == 2
    print("3. 非零会话 ID OK")

    # 4. 校验和被破坏 → badSync
    bad = bytearray(encode_packet(ACK, 1, 0, b"ab"))
    bad[5] ^= 0xFF
    kind, _ = decode_packet(bytes(bad))
    assert kind == "badSync", kind
    print("4. 破坏校验和被检出 OK")

    # 5. SOP 不对 → badSync
    kind, _ = decode_packet(b"\x00\x00" + encode_packet(ACK, 1, 0)[2:])
    assert kind == "badSync"
    print("5. SOP 错误被检出 OK")

    # 6. 半个包 → needMore
    raw = encode_packet(ACK, 1, 0, b"abcdef")
    kind, _ = decode_packet(raw[:len(raw) - 3])
    assert kind == "needMore"
    print("6. 半包 → needMore OK")

    # 7. 消息 round-trip
    msg = encode_message(0x1EAE, [(0x0000, b"\x00\x00\x00\x00"), (0x0001, "WePlay".encode())])
    kind, m = parse_message(msg)
    assert kind == "message", kind
    assert m["id"] == 0x1EAE
    assert m["params"][0][1] == b"\x00\x00\x00\x00"
    assert m["params"][1][1] == "WePlay".encode()
    assert m["consumed"] == len(msg)
    print("7. 消息 round-trip OK  (%d B, %s)" % (len(msg), msg.hex()))

    # 8. 流式累积：把包+消息拆成碎片喂进去，最终应完整解出
    wire = encode_packet(ACK, 1, 0x0000, msg)
    buf = bytearray()
    got_pkt = got_msg = None
    for i in range(len(wire)):
        buf += wire[i:i + 1]
        kind, pkt = decode_packet(bytes(buf))
        if kind == "packet":
            got_pkt = pkt
            buf = bytearray()
            kind2, m = parse_message(pkt["payload"])
            if kind2 == "message":
                got_msg = m
    assert got_pkt is not None and got_msg is not None and got_msg["id"] == 0x1EAE
    print("8. 逐字节流式累积解包 OK")

    # 9. 最小包结构：10 字节（9 头 + 1 载荷校验）
    raw = encode_packet(ACK, 0, 0x0000)
    assert len(raw) == 10, len(raw)
    print("9. 最小包 10 字节 OK  (%s)" % raw.hex())

    print("\n全部通过 [OK]   （若真机握手日志与此不一致，只需改 encode/decode 里偏移 6..7 一处）")


if __name__ == "__main__":
    main()
