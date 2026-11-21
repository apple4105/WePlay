"""RTP 打包 / Input 解析的 Python 校准版：与 WePlay/Output/Display/*.swift 逐行对应。
在没有 Mac 的情况下验证字节级编解码。跑法： python -I rtp_selftest.py
"""
import struct

MAX_PAYLOAD = 1200
PT_VIDEO = 96
PT_AUDIO = 97


# ---------- RTP 头 ----------
def rtp_packet(payload, marker, payload_type, sequence, timestamp, ssrc):
    b0 = 0x80 | (0x20 if marker else 0x00)
    return struct.pack(">BBHII", b0, payload_type, sequence & 0xFFFF, timestamp & 0xFFFFFFFF, ssrc) + payload


# ---------- Annex-B 切分 ----------
def split_annexb(data: bytes):
    nals, start, j, n = [], None, 0, len(data)
    while j < n:
        if j + 2 < n and data[j] == 0 and data[j+1] == 0 and data[j+2] == 1:
            if start is not None:
                nals.append(data[start:j])
            j += 3
            start = j
            continue
        if j + 3 < n and data[j] == 0 and data[j+1] == 0 and data[j+2] == 0 and data[j+3] == 1:
            if start is not None:
                nals.append(data[start:j])
            j += 4
            start = j
            continue
        j += 1
    if start is not None and start < n:
        nals.append(data[start:])
    return [x for x in nals if x]


def contains_idr(data: bytes) -> bool:
    return any((nal[0] & 0x1F) == 5 for nal in split_annexb(data) if nal)


# ---------- H.264 打包 ----------
def packetize_h264(annexb: bytes, timestamp: int, seq_start: int = 0, ssrc: int = 0x11223344):
    nals = split_annexb(annexb)
    packets, seq = [], seq_start
    for i, nal in enumerate(nals):
        is_last = (i == len(nals) - 1)
        if len(nal) <= MAX_PAYLOAD:
            packets.append(rtp_packet(nal, is_last, PT_VIDEO, seq, timestamp, ssrc))
            seq = (seq + 1) & 0xFFFF
        else:
            frags, seq = fragment_fu_a(nal, is_last, timestamp, seq, ssrc)
            packets.extend(frags)
    return packets, seq


def fragment_fu_a(nal: bytes, is_last: bool, timestamp: int, seq: int, ssrc: int):
    header = nal[0]
    fu_indicator = (header & 0xE0) | 28
    max_frag = MAX_PAYLOAD - 2
    packets, offset, first = [], 1, True
    end = len(nal)
    while offset < end:
        chunk_end = min(offset + max_frag, end)
        last = chunk_end >= end
        fu_header = header & 0x1F
        if first:
            fu_header |= 0x80
        if last:
            fu_header |= 0x40
        payload = bytes([fu_indicator, fu_header]) + nal[offset:chunk_end]
        packets.append(rtp_packet(payload, is_last and last, PT_VIDEO, seq, timestamp, ssrc))
        seq = (seq + 1) & 0xFFFF
        offset, first = chunk_end, False
    return packets, seq


# ---------- AAC 打包 ----------
def packetize_aac(au: bytes, timestamp: int, seq: int, ssrc: int = 0x55667788):
    payload = struct.pack(">H", len(au)) + au
    return rtp_packet(payload, True, PT_AUDIO, seq, timestamp, ssrc)


# ---------- RTP 解析（打包的逆操作，用来验证） ----------
def parse_rtp(pkt: bytes):
    b0, pt, seq, ts, ssrc = struct.unpack(">BBHII", pkt[:12])
    return dict(version=b0 >> 6, marker=bool(b0 & 0x20), payload_type=pt, sequence=seq,
                timestamp=ts, ssrc=ssrc, payload=pkt[12:])


def reassemble_fu_a(fragments):
    """把 FU-A 片段拼回原 NAL（含 NAL header）"""
    out = bytearray()
    for f in fragments:
        p = parse_rtp(f)["payload"]
        ind, hdr = p[0], p[1]
        nal_type = hdr & 0x1F
        if not out:
            out.append((ind & 0xE0) | nal_type)
        out.extend(p[2:])
    return bytes(out)


# ---------- Input ----------
def parse_single_touch(payload: bytes):
    """返回 (phase, x, y)；payload = Input 报文体（4 字节头 + GENERIC 4 字节头 + SingleTouch 载荷）"""
    version = payload[0] >> 4
    category = struct.unpack_from("<H", payload, 2)[0]
    assert version == 0, version
    assert category == 1, category
    input_type = struct.unpack_from("<H", payload, 4)[0]
    assert input_type == 2, input_type
    body = payload[8:]
    event = body[0]
    x, y = struct.unpack_from("<HH", body, 3)
    phase = {0: "down", 1: "move", 2: "up"}.get(event)
    assert phase, event
    return phase, x, y


def build_single_touch(phase: str, x: int, y: int) -> bytes:
    """反向构造一条 Input SingleTouch（自测 round-trip 用）"""
    ev = {"down": 0, "move": 1, "up": 2}[phase]
    body = bytes([ev, 0, 0]) + struct.pack("<HH", x, y)
    generic = struct.pack("<HH", 2, len(body)) + body
    return bytes([0x00, 0x00]) + struct.pack("<H", 1) + generic


# ================= 自测 =================
def main():
    # 1. RTP 头编码
    pkt = rtp_packet(b"\x65\x88\x84\x00", True, PT_VIDEO, 1234, 90000, 0xAABBCCDD)
    assert len(pkt) == 16
    info = parse_rtp(pkt)
    assert info["version"] == 2 and info["marker"] and info["payload_type"] == PT_VIDEO
    assert info["sequence"] == 1234 and info["timestamp"] == 90000 and info["ssrc"] == 0xAABBCCDD
    assert info["payload"] == b"\x65\x88\x84\x00"
    print("1. RTP 头编码/解析 round-trip OK")

    # 2. 小 NAL → Single NAL
    nal = bytes([0x65, 0x88, 0x84, 0x00, 0xFF])
    annexb = b"\x00\x00\x00\x01" + nal
    pkts, seq = packetize_h264(annexb, 90000)
    assert len(pkts) == 1 and seq == 1
    assert parse_rtp(pkts[0])["payload"] == nal and parse_rtp(pkts[0])["marker"] is True
    print("2. 小 NAL → Single NAL OK")

    # 3. 大 NAL → FU-A，且能拼回原样
    big = bytes([0x65]) + bytes(range(256)) * 10      # 2561 字节 > 1200
    annexb = b"\x00\x00\x00\x01" + big
    pkts, seq = packetize_h264(annexb, 90000)
    assert len(pkts) == 3, len(pkts)                 # ceil(2560/1198) = 3
    # 第一个片段 start 位置、最后一个 end 位置
    p0 = parse_rtp(pkts[0])["payload"]
    pN = parse_rtp(pkts[-1])["payload"]
    assert (p0[1] & 0x80) and not (p0[1] & 0x40), "首片应有 Start"
    assert (pN[1] & 0x40) and not (pN[1] & 0x80), "末片应有 End"
    assert (p0[1] & 0x1F) == 5, "FU-A 应保留原 NAL type"
    reassembled = reassemble_fu_a(pkts)
    assert reassembled == big, "FU-A 拼回后应与原 NAL 一致"
    assert parse_rtp(pkts[-1])["marker"] is True
    print("3. 大 NAL → FU-A（3 片，Start/End 位正确，可拼回）OK")

    # 4. 关键帧：SPS + PPS + IDR 三 NAL
    sps = bytes([0x67, 0x42, 0x00, 0x1F])
    pps = bytes([0x68, 0xCE, 0x3C, 0x80])
    idr = bytes([0x65]) + bytes(range(256)) * 8      # 2049 字节 → 2 片
    annexb = b"\x00\x00\x00\x01".join([sps, pps, idr])
    annexb = b"\x00\x00\x00\x01" + sps + b"\x00\x00\x00\x01" + pps + b"\x00\x00\x00\x01" + idr
    pkts, seq = packetize_h264(annexb, 180000)
    # SPS 1 包 + PPS 1 包 + IDR 2 包 = 4
    assert len(pkts) == 4, len(pkts)
    markers = [parse_rtp(p)["marker"] for p in pkts]
    assert markers == [False, False, False, True], markers
    # 序列号连续
    seqs = [parse_rtp(p)["sequence"] for p in pkts]
    assert seqs == [0, 1, 2, 3], seqs
    print("4. 关键帧（SPS+PPS+IDR）→ 4 包，marker/序列号正确 OK")

    # 5. containsIDR
    assert contains_idr(annexb) is True
    assert contains_idr(b"\x00\x00\x00\x01" + sps) is False
    print("5. containsIDR 判定 OK")

    # 6. AAC 打包
    au = bytes(range(64))
    pkt = packetize_aac(au, 45000, 7)
    info = parse_rtp(pkt)
    assert info["payload_type"] == PT_AUDIO and info["marker"]
    assert info["payload"] == struct.pack(">H", len(au)) + au
    print("6. AAC 打包（AU 长度前缀 + 载荷）OK")

    # 7. Input SingleTouch round-trip
    payload = build_single_touch("move", 32768, 16384)
    phase, x, y = parse_single_touch(payload)
    assert (phase, x, y) == ("move", 32768, 16384), (phase, x, y)
    print("7. Input SingleTouch round-trip OK  (%s)" % payload.hex())

    # 8. Input 归一化坐标 → 显示端像素（1920x720）
    #    65535 → 满量程；32768 ≈ 半 → 960；16384 ≈ 1/4 → 180
    for nx, ny, ex, ey in [(0, 0, 0, 0), (65535, 65535, 1920, 720),
                           (32768, 32768, 960, 360), (16384, 16384, 480, 180)]:
        x = nx * 1920 // 65535
        y = ny * 720 // 65535
        assert (x, y) == (ex, ey), (nx, ny, x, y, ex, ey)
    print("8. Input 归一化坐标 → 1920x720 像素换算 OK")

    print("\n全部通过 [OK]")


if __name__ == "__main__":
    main()
