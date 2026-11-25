"""Link 编解码的 Python 校准版：与 WePlay/Link/Protocol/*.swift 逐行对应。

2026-11-21 定稿格式（Wireshark 公开解析器 + CarWithin 二进制双源一致，全部大端）：
  包头   SOP FF5A | 长度BE16(含9字节头+载荷+载荷校验) | 控制 | 序列 | 确认 | 会话(1B) | 头校验
  消息   SOM 4040 | 长度BE16(含自身6字节头) | 消息ID BE16 | 参数…
  参数   长度BE16(含自身4字节头) | ID BE16 | 数据

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


def encode_packet(control, sequence, acknowledgement, session_id, payload=b""):
    # 无载荷帧总长 9（不追加载荷校验）；有载荷时再加 载荷 + 载荷校验
    total = HEADER if not payload else HEADER + len(payload) + 1
    out = bytearray(SOP)
    out += struct.pack(">H", total)         # 长度大端
    out.append(control)
    out.append(sequence)
    out.append(acknowledgement)             # 确认号 1 字节
    out.append(session_id)                  # 会话 ID 1 字节（控制会话 = 0x00）
    # 头校验覆盖全部 8 个头部字节（含 FF 5A）——carvex 固件规范 R-2.7
    out.append(checksum(bytes(out[:8])))
    if payload:
        out += payload
        out.append(checksum(payload))
    assert len(out) == total, (len(out), total)
    return bytes(out)


def decode_packet(data: bytes):
    if len(data) < HEADER:
        return ("needMore", None)
    if data[0:2] != SOP:
        return ("badSync", None)
    length = struct.unpack_from(">H", data, 2)[0]
    # 合法长度：9（无载荷）或 >= 11；10 非法
    if length < HEADER or length == HEADER + 1:
        return ("badSync", None)
    if len(data) < length:
        return ("needMore", None)
    control, seq, ack, session = data[4], data[5], data[6], data[7]
    hdr_ck = data[8]
    # 头校验覆盖全部 8 个头部字节（含 SOP）——固件规范 R-2.7
    if not verify(data[:8], hdr_ck):
        return ("badSync", None)
    if length == HEADER:
        payload = b""
    else:
        payload = data[HEADER:length - 1]
        if not verify(payload, data[length - 1]):
            return ("badSync", None)
    return ("packet", dict(control=control, sequence=seq, acknowledgement=ack,
                           session=session, payload=payload, consumed=length))


# ---------- 消息层 ----------
SOM = bytes([0x40, 0x40])


def encode_param(pid, value):
    return struct.pack(">H", len(value) + 4) + struct.pack(">H", pid) + value


def encode_message(mid, params):
    body = b"".join(encode_param(pid, val) for pid, val in params)
    # 长度含自身 6 字节头（SOM+长度+ID），最小 6
    return SOM + struct.pack(">H", 6 + len(body)) + struct.pack(">H", mid) + body


def parse_message(data):
    if len(data) < 6:
        return ("needMore", None)
    if data[0:2] != SOM:
        return ("badFormat", None)
    length = struct.unpack_from(">H", data, 2)[0]
    if length < 6:
        return ("badFormat", None)
    if len(data) < length:
        return ("needMore", None)
    mid = struct.unpack_from(">H", data, 4)[0]
    params, off = [], 6
    while off < length:
        plen = struct.unpack_from(">H", data, off)[0]
        if plen < 4 or off + plen > length:
            return ("badFormat", None)
        pid = struct.unpack_from(">H", data, off + 2)[0]
        params.append((pid, data[off + 4:off + plen]))
        off += plen
    if off != length:
        return ("badFormat", None)
    return ("message", dict(id=mid, params=params, consumed=length))


# ---------- 自测 ----------
def main():
    ok = True

    # 1. 空载荷包 round-trip
    raw = encode_packet(ACK, 7, 5, 0x00)
    kind, pkt = decode_packet(raw)
    assert kind == "packet", kind
    assert pkt["control"] == ACK and pkt["sequence"] == 7
    assert pkt["acknowledgement"] == 5 and pkt["session"] == 0
    assert pkt["payload"] == b"" and pkt["consumed"] == len(raw)
    print("1. 空载荷包 round-trip OK  (%d B, %s)" % (len(raw), raw.hex()))

    # 2. 带载荷包 round-trip
    payload = b"\xde\xad\xbe\xef"
    raw = encode_packet(ACK | SYN, 1, 0, 0x00, payload)
    kind, pkt = decode_packet(raw)
    assert kind == "packet" and pkt["payload"] == payload and pkt["consumed"] == len(raw)
    print("2. 带载荷包 round-trip OK  (%d B, %s)" % (len(raw), raw.hex()))

    # 3. 非零会话 ID（EA 会话 0x02）
    raw = encode_packet(ACK, 3, 2, 0x02, b"xy")
    kind, pkt = decode_packet(raw)
    assert kind == "packet" and pkt["session"] == 2
    print("3. 非零会话 ID OK")

    # 4. 校验和被破坏 → badSync
    bad = bytearray(encode_packet(ACK, 1, 0, 0, b"ab"))
    bad[5] ^= 0xFF
    kind, _ = decode_packet(bytes(bad))
    assert kind == "badSync", kind
    print("4. 破坏校验和被检出 OK")

    # 5. SOP 不对 → badSync
    kind, _ = decode_packet(b"\x00\x00" + encode_packet(ACK, 1, 0, 0)[2:])
    assert kind == "badSync"
    print("5. SOP 错误被检出 OK")

    # 6. 半个包 → needMore
    raw = encode_packet(ACK, 1, 0, 0, b"abcdef")
    kind, _ = decode_packet(raw[:len(raw) - 3])
    assert kind == "needMore"
    print("6. 半包 → needMore OK")

    # 7. 消息 round-trip（含空值参数 = 长度恰为 4）
    msg = encode_message(0x1D01, [
        (0x0000, "CP-Receiver-1".encode()),
        (0x0002, b""),                     # nil 占位参数
        (0x0001, "WePlay".encode()),
    ])
    kind, m = parse_message(msg)
    assert kind == "message", kind
    assert m["id"] == 0x1D01
    assert m["params"][0][1] == "CP-Receiver-1".encode()
    assert m["params"][1][1] == b""
    assert m["params"][2][1] == "WePlay".encode()
    assert m["consumed"] == len(msg)
    print("7. 消息 round-trip OK  (%d B, %s)" % (len(msg), msg.hex()))

    # 8. 长度字段自包含：SOM(2)+长度(2)+ID(2)+参数 = 长度值
    assert m["consumed"] == 6 + sum(4 + len(v) for _, v in m["params"])
    print("8. 消息长度自包含（6 + 参数）OK")

    # 9. 流式累积：把包+消息拆成碎片喂进去，最终应完整解出
    wire = encode_packet(ACK, 1, 0, 0x00, msg)
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
    assert got_pkt is not None and got_msg is not None and got_msg["id"] == 0x1D01
    print("9. 逐字节流式累积解包 OK")

    # 10. 一条消息跨两个链路包仍可在消息层拼回
    first_half = msg[:len(msg) // 2]
    second_half = msg[len(msg) // 2:]
    fragments = [
        encode_packet(ACK, 2, 0, 0x00, first_half),
        encode_packet(ACK, 3, 2, 0x00, second_half),
    ]
    message_buf = bytearray()
    recovered = None
    for fragment in fragments:
        kind, packet = decode_packet(fragment)
        assert kind == "packet"
        message_buf += packet["payload"]
        kind2, candidate = parse_message(bytes(message_buf))
        if kind2 == "message":
            recovered = candidate
            message_buf.clear()
    assert recovered is not None and recovered["id"] == 0x1D01
    print("10. 消息跨链路包边界拼接 OK")

    # 11. SYN session table：控制/EA/文件 session 必须由线上条目决定
    syn_payload = bytes([
        1, 8, 0xFF, 0xFF, 0x03, 0xE8, 0x00, 0x0A, 30, 0,
        10, 0, 0, 11, 2, 0, 12, 1, 0,
    ])
    # v1 的条目从偏移 10 起，每条 3 字节；type 0 是控制 session。
    assert len(syn_payload) == 19
    entries = [syn_payload[i:i + 3] for i in range(10, len(syn_payload), 3)]
    assert [(e[0], e[1] & 0x7F, e[2]) for e in entries] == [(10, 0, 0), (11, 2, 0), (12, 1, 0)]
    assert all(e[0] != 0 and (e[1] & 0x80) == 0 for e in entries)
    assert len({e[0] for e in entries}) == len(entries)
    assert len({e[1] & 0x7F for e in entries}) == len(entries)
    print("11. SYN session table 解析/唯一性检查 OK")

    # 12. identification 实际编码形状抽查：param 1 = "CP-Receiver-1"
    ident = encode_message(0x1D01, [(1, b"CP-Receiver-1")])
    assert ident[0:2] == b"\x40\x40"
    assert ident[2:4] == struct.pack(">H", len(ident))   # 长度 = 整条消息字节数
    assert ident[4:6] == b"\x1d\x01"
    print("12. identification 编码形状 OK  (%s)" % ident.hex())

    print("\n全部通过 [OK]   （若真机握手日志与此不一致，按诊断 hex 只改 encode/decode 一处）")


if __name__ == "__main__":
    main()
