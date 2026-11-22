import Foundation
import AVFoundation
import CoreMedia
import SwiftUI
import UIKit
import VideoToolbox

/// fMP4 + VideoToolbox 高清路（Phase 2，B 路实现）。
///
/// 数据流：go2rtc /api/stream.mp4?src=<xiaomi URL> 输出 fMP4
/// （ftyp + moov + moof/mdat 片段；moov 里视频 sample entry 为 hev1，
/// 内含 hvcC 盒；mdat 里的样本是 4 字节长度前缀的 NAL）。
/// 本文件用 URLSession.bytes(for:) 流式读，增量 demux 成 CMSampleBuffer，
/// 经 AVSampleBufferDisplayLayer 用 VideoToolbox 硬解显示。
/// 音频轨（Opus）直接忽略，不解码。
///
/// 注意 hev1 vs hvc1：这里不依赖 sample entry 的类型，而是直接从 hvcC
/// 的 VPS/SPS/PPS 建 CMFormatDescription，所以 hev1 样条也能解。
final class Fmp4Player: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var lastError: String?

    /// 渲染层由 Fmp4PlayerView 挂接（view 持有，player 只弱引用）。
    private(set) weak var displayLayer: AVSampleBufferDisplayLayer?

    private var readTask: Task<Void, Never>?
    private let demuxer = Fmp4Demuxer()
    private let demuxerLock = NSLock()

    override init() {
        super.init()
        demuxer.onFormatDescription = { [weak self] _ in
            guard let self = self else { return }
            Task { await self.flushLayerForNewFormat() }
        }
        demuxer.onSample = { [weak self] sample in
            guard let self = self else { return }
            Task { await self.enqueueSample(sample) }
        }
        demuxer.onError = { [weak self] message in
            guard let self = self else { return }
            Task { await self.setError(message) }
        }
    }

    /// Fmp4PlayerView 在 makeUIView / updateUIView 里挂接渲染层。
    func attach(layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
    }

    /// Fmp4PlayerView 在 updateUIView 里发现 layer.status == .failed 时上报。
    func reportLayerError(_ error: Error) {
        Task { await setError("视频层失败：\(error.localizedDescription)") }
    }

    func play(streamURL: URL) {
        stop()
        lastError = nil
        isPlaying = true
        demuxerReset()
        readTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runLoop(url: streamURL)
        }
    }

    /// 取消读取 Task、清空 demuxer 缓冲、停掉画面（不销毁渲染层）。
    func stop() {
        readTask?.cancel()
        readTask = nil
        demuxerReset()
        isPlaying = false
        displayLayer?.flush()
    }

    // MARK: - 读取循环

    private func runLoop(url: URL) async {
        var request = URLRequest(url: url)
        // 显式 UA：防止 go2rtc 把请求 301 到 HLS（URLSession 默认 UA 不含 Safari
        // 本来也不会触发重定向，这里再显式钉死一次）。
        request.setValue("IMILAN-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await setError("播放失败：服务器未返回 HTTP 响应")
                return
            }
            guard httpResponse.statusCode == 200 else {
                // 非 200 时把 body 前 200 字符写进错误（go2rtc 的报错文本在里面）。
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 200 { break }
                }
                let text = String(data: body.prefix(200), encoding: .utf8) ?? ""
                await setError("播放失败：HTTP \(httpResponse.statusCode)" + (text.isEmpty ? "" : "：\(text)"))
                return
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                demuxerAppend(byte)
            }
            // 服务器正常关闭了流（go2rtc 的直播流正常情况下不会结束）。
            await setEnded()
        } catch is CancellationError {
            // stop() 主动取消：不是错误。
        } catch {
            await setError("播放失败：\(error.localizedDescription)")
        }
    }

    // MARK: - MainActor 状态更新

    @MainActor
    private func setError(_ message: String) {
        lastError = message
        isPlaying = false
        readTask?.cancel()
    }

    @MainActor
    private func setEnded() {
        lastError = "流已断开（服务器关闭了连接）"
        isPlaying = false
    }

    @MainActor
    private func flushLayerForNewFormat() {
        displayLayer?.flushAndRemoveImage()
    }

    @MainActor
    private func enqueueSample(_ sample: CMSampleBuffer) {
        guard let layer = displayLayer else { return }
        if layer.status == .failed {
            lastError = layer.error.map { "视频层失败：\($0.localizedDescription)" } ?? "视频层失败"
            isPlaying = false
            readTask?.cancel()
            return
        }
        layer.enqueue(sample)
        if layer.status == .failed {
            lastError = layer.error.map { "视频层失败：\($0.localizedDescription)" } ?? "视频层失败"
            isPlaying = false
            readTask?.cancel()
        }
    }

    // MARK: - demuxer 访问（读取 Task 与 stop() 可能并发，加锁串行化）

    private func demuxerAppend(_ byte: UInt8) {
        demuxerLock.lock()
        defer { demuxerLock.unlock() }
        demuxer.append(byte)
    }

    private func demuxerReset() {
        demuxerLock.lock()
        defer { demuxerLock.unlock() }
        demuxer.reset()
    }
}

// MARK: - 增量 fMP4 demuxer

/// 逐字节喂入、增量切 box 的 fMP4 解析器。
///
/// 顶层 box 按 [u32 size][4 字节 type] 切；ftyp 跳过；moov 等完整到达后解析；
/// moof 解析出样本表；mdat 不等整个 box 到齐，按样本表边到边切样本、边发。
/// 只有视频轨（hdlr handler_type == vide）参与解码，音频轨直接跳过。
private final class Fmp4Demuxer {
    /// 新 moov 到达、格式描述重建后回调（player 用来 flush 渲染层）。
    var onFormatDescription: ((CMFormatDescription) -> Void)?
    /// 一个完整视频样本就绪后回调（已包成 CMSampleBuffer）。
    var onSample: ((CMSampleBuffer) -> Void)?
    /// 致命解析错误回调（player 据此写 lastError 并停流）。
    var onError: ((String) -> Void)?

    private struct PendingSample {
        var size: Int
        var duration: UInt32
        var pts: Int64
        var dts: Int64
        var nonSync: Bool
    }

    private var bytes: [UInt8] = []
    private var readIndex = 0
    private var failed = false

    private var formatDescription: CMFormatDescription?
    private var videoTimescale: UInt32 = 0
    private var videoTrackID: UInt32 = 0
    private var nalLengthSize = 4

    // 当前 mdat 的流式切分状态
    private var inMdat = false
    private var mdatBytesRemaining = 0
    private var pendingSamples: [PendingSample] = []
    private var pendingIndex = 0
    private var currentSampleBytes: [UInt8] = []
    private var currentSampleRemaining = 0

    func reset() {
        bytes.removeAll(keepingCapacity: true)
        readIndex = 0
        failed = false
        formatDescription = nil
        videoTimescale = 0
        videoTrackID = 0
        nalLengthSize = 4
        inMdat = false
        mdatBytesRemaining = 0
        pendingSamples.removeAll(keepingCapacity: true)
        pendingIndex = 0
        currentSampleBytes.removeAll(keepingCapacity: true)
        currentSampleRemaining = 0
    }

    func append(_ byte: UInt8) {
        bytes.append(byte)
        process()
    }

    // MARK: 顶层切 box

    private func process() {
        defer { compact() }
        guard !failed else { return }
        while true {
            guard !failed else { return }
            if inMdat {
                if pendingIndex >= pendingSamples.count {
                    if mdatBytesRemaining > 0 {
                        // 本 mdat 的样本已发完，跳过剩余负载字节。
                        let avail = bytes.count - readIndex
                        if avail == 0 { return }
                        let skip = min(avail, mdatBytesRemaining)
                        readIndex += skip
                        mdatBytesRemaining -= skip
                        continue
                    }
                    inMdat = false
                    continue
                }
                if mdatBytesRemaining == 0 {
                    // 样本数与 mdat 长度对不上：丢弃剩余样本表，结束本 mdat。
                    pendingSamples.removeAll()
                    pendingIndex = 0
                    inMdat = false
                    continue
                }
                let sample = pendingSamples[pendingIndex]
                if currentSampleRemaining == 0 {
                    currentSampleRemaining = sample.size
                    currentSampleBytes.removeAll(keepingCapacity: true)
                    currentSampleBytes.reserveCapacity(sample.size)
                }
                let avail = bytes.count - readIndex
                if avail == 0 { return }
                let take = min(avail, currentSampleRemaining, mdatBytesRemaining)
                if take > 0 {
                    currentSampleBytes.append(contentsOf: bytes[readIndex..<(readIndex + take)])
                    readIndex += take
                    currentSampleRemaining -= take
                    mdatBytesRemaining -= take
                }
                if currentSampleRemaining == 0 {
                    emit(sample: sample, data: currentSampleBytes)
                    pendingIndex += 1
                }
                continue
            }

            guard bytes.count - readIndex >= 8 else { return }
            let size32 = readU32(at: readIndex)
            guard let type = fourCC(at: readIndex + 4) else { return }
            var headerSize = 8
            var boxSize: Int
            if size32 == 1 {
                guard bytes.count - readIndex >= 16 else { return }
                let large = readU64(at: readIndex + 8)
                guard large <= UInt64(Int.max) else {
                    fail("box 过大：\(type)")
                    return
                }
                boxSize = Int(large)
                headerSize = 16
            } else if size32 == 0 {
                fail("不支持的 box（size=0）：\(type)")
                return
            } else {
                boxSize = Int(size32)
            }
            guard boxSize >= headerSize else {
                fail("非法 box 大小：\(type) size=\(boxSize)")
                return
            }
            let payloadSize = boxSize - headerSize
            if type == "mdat" {
                // mdat 不等整个 box 到齐，读完头就进流式切分。
                readIndex += headerSize
                mdatBytesRemaining = payloadSize
                inMdat = true
                continue
            }
            // ftyp / moov / moof 等完整到达后再解析。
            guard bytes.count - readIndex >= boxSize else { return }
            let payloadStart = readIndex + headerSize
            let payload = Array(bytes[payloadStart..<(payloadStart + payloadSize)])
            switch type {
            case "ftyp":
                break
            case "moov":
                parseMoov(payload)
            case "moof":
                parseMoof(payload)
            default:
                break
            }
            readIndex += boxSize
        }
    }

    private func compact() {
        if readIndex == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 65536 {
            bytes.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private func fail(_ message: String) {
        failed = true
        onError?(message)
    }

    private func readU32(at i: Int) -> UInt32 {
        (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16)
            | (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
    }

    private func readU64(at i: Int) -> UInt64 {
        (UInt64(readU32(at: i)) << 32) | UInt64(readU32(at: i + 4))
    }

    private func fourCC(at i: Int) -> String? {
        String(bytes: bytes[i..<(i + 4)], encoding: .ascii)
    }

    // MARK: moov（视频轨 + hvcC → 格式描述）

    private func parseMoov(_ payload: [UInt8]) {
        let reader = BoxReader(payload)
        var foundVideo = false
        for (type, box) in reader.children() {
            guard type == "trak" else { continue }
            if parseTrak(box) {
                foundVideo = true
                break
            }
        }
        if !foundVideo {
            fail("moov 里没有 H.265 视频轨")
        }
    }

    /// 返回 true 表示该 trak 是视频轨且已建好格式描述。
    private func parseTrak(_ trak: BoxReader) -> Bool {
        var trackID: UInt32 = 0
        var mdiaBox: BoxReader?
        for (type, box) in trak.children() {
            switch type {
            case "tkhd":
                var r = box
                guard let verFlags = r.u32() else { continue }
                let version = verFlags >> 24
                if version == 1 {
                    guard r.skip(16), let id = r.u32() else { continue }
                    trackID = id
                } else {
                    guard r.skip(8), let id = r.u32() else { continue }
                    trackID = id
                }
            case "mdia":
                mdiaBox = box
            default:
                break
            }
        }
        guard let mdia = mdiaBox, trackID != 0 else { return false }
        return parseMdia(mdia, trackID: trackID)
    }

    private func parseMdia(_ mdia: BoxReader, trackID: UInt32) -> Bool {
        var timescale: UInt32 = 0
        var isVideo = false
        var minfBox: BoxReader?
        for (type, box) in mdia.children() {
            switch type {
            case "mdhd":
                // version/flags(4) + creation(4/8) + modification(4/8) + timescale(4)。
                var r = box
                guard let verFlags = r.u32() else { continue }
                let version = verFlags >> 24
                if version == 1 {
                    guard r.skip(16), let ts = r.u32() else { continue }
                    timescale = ts
                } else {
                    guard r.skip(8), let ts = r.u32() else { continue }
                    timescale = ts
                }
            case "hdlr":
                // version/flags(4) + pre_defined(4) + handler_type(4)。
                var r = box
                guard r.skip(4), let _ = r.u32(), let handler = r.fourCC() else { continue }
                isVideo = (handler == "vide")
            case "minf":
                minfBox = box
            default:
                break
            }
        }
        guard isVideo, timescale > 0, let minf = minfBox else { return false }
        guard let parsed = parseMinf(minf) else { return false }
        // 重连收到新 moov 时重建格式描述（旧的直接替换）。
        videoTrackID = trackID
        videoTimescale = timescale
        nalLengthSize = parsed.nalLengthSize
        formatDescription = parsed.formatDescription
        onFormatDescription?(parsed.formatDescription)
        return true
    }

    private func parseMinf(_ minf: BoxReader) -> (formatDescription: CMFormatDescription, nalLengthSize: Int)? {
        for (type, box) in minf.children() {
            guard type == "stbl" else { continue }
            for (type2, box2) in box.children() {
                guard type2 == "stsd" else { continue }
                return parseStsd(box2)
            }
        }
        return nil
    }

    private func parseStsd(_ stsd: BoxReader) -> (formatDescription: CMFormatDescription, nalLengthSize: Int)? {
        var r = stsd
        guard r.skip(4), let entryCount = r.u32(), entryCount >= 1 else { return nil }
        let entryStart = r.offset
        guard let size32 = r.u32(), let type = r.fourCC() else { return nil }
        guard type == "hev1" || type == "hvc1" else { return nil }
        let entrySize = Int(size32)
        // visual sample entry：8 字节 box 头 + 78 字节固定字段，之后是子 box。
        guard entrySize >= 86, entryStart + entrySize <= r.end else { return nil }
        let childrenReader = BoxReader(r.bytes, range: (entryStart + 8 + 78)..<(entryStart + entrySize))
        for (childType, childBox) in childrenReader.children() {
            guard childType == "hvcC" else { continue }
            let payload = Array(childBox.bytes[childBox.offset..<childBox.end])
            return parseHvcC(payload)
        }
        return nil
    }

    /// hvcC：23 字节头后是 NAL 数组；取 VPS(32)/SPS(33)/PPS(34) 建格式描述。
    /// numOfArrays 在第 22 字节；lengthSizeMinusOne 在第 21 字节低 2 位。
    private func parseHvcC(_ payload: [UInt8]) -> (formatDescription: CMFormatDescription, nalLengthSize: Int)? {
        guard payload.count >= 23, payload[0] == 1 else { return nil }
        let nalLength = Int(payload[21] & 0x03) + 1
        let numArrays = Int(payload[22])
        var offset = 23
        var parameterSets: [Data] = []
        for _ in 0..<numArrays {
            guard offset + 3 <= payload.count else { return nil }
            let nalType = payload[offset] & 0x3F
            let numNalus = (Int(payload[offset + 1]) << 8) | Int(payload[offset + 2])
            offset += 3
            for _ in 0..<numNalus {
                guard offset + 2 <= payload.count else { return nil }
                let len = (Int(payload[offset]) << 8) | Int(payload[offset + 1])
                offset += 2
                guard offset + len <= payload.count else { return nil }
                if nalType == 32 || nalType == 33 || nalType == 34 {
                    parameterSets.append(Data(payload[offset..<(offset + len)]))
                }
                offset += len
            }
        }
        guard !parameterSets.isEmpty else { return nil }
        guard let desc = makeHVCFormatDescription(parameterSets: parameterSets, nalLengthSize: nalLength) else { return nil }
        return (desc, nalLength)
    }

    private func makeHVCFormatDescription(parameterSets: [Data], nalLengthSize: Int) -> CMFormatDescription? {
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        buffers.reserveCapacity(parameterSets.count)
        for data in parameterSets {
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
            data.copyBytes(to: ptr, count: data.count)
            buffers.append(ptr)
        }
        defer { buffers.forEach { $0.deallocate() } }
        var pointers: [UnsafePointer<UInt8>?] = buffers.map { UnsafePointer($0) }
        var sizes: [Int] = parameterSets.map { $0.count }
        var desc: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrBuf in
            sizes.withUnsafeBufferPointer { sizeBuf in
                CMVideoFormatDescriptionCreateFromHVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSets: ptrBuf.baseAddress!,
                    parameterSetSizes: sizeBuf.baseAddress!,
                    nalUnitHeaderLength: Int32(nalLengthSize),
                    formatDescriptionOut: &desc)
            }
        }
        guard status == noErr else { return nil }
        return desc
    }

    // MARK: moof（样本表）

    private func parseMoof(_ payload: [UInt8]) {
        let reader = BoxReader(payload)
        for (type, box) in reader.children() {
            guard type == "traf" else { continue }
            guard let samples = parseTraf(box), !samples.isEmpty else { continue }
            pendingSamples = samples
            pendingIndex = 0
            break
        }
    }

    private func parseTraf(_ traf: BoxReader) -> [PendingSample]? {
        var trackID: UInt32 = 0
        var defaultDuration: UInt32?
        var defaultSize: UInt32?
        var defaultFlags: UInt32?
        var baseDecodeTime: Int64 = 0
        var trunBox: BoxReader?
        for (type, box) in traf.children() {
            switch type {
            case "tfhd":
                var r = box
                guard let verFlags = r.u32(), let id = r.u32() else { return nil }
                trackID = id
                let flags = verFlags & 0x00FF_FFFF
                if (flags & 0x000001) != 0 { _ = r.u64() } // base-data-offset
                if (flags & 0x000002) != 0 { _ = r.u32() } // sample-description-index
                if (flags & 0x000008) != 0 { defaultDuration = r.u32() }
                if (flags & 0x000010) != 0 { defaultSize = r.u32() }
                if (flags & 0x000020) != 0 { defaultFlags = r.u32() }
            case "tfdt":
                var r = box
                guard let verFlags = r.u32() else { return nil }
                let version = verFlags >> 24
                if version == 1 {
                    guard let v = r.u64() else { return nil }
                    baseDecodeTime = Int64(bitPattern: v)
                } else {
                    guard let v = r.u32() else { return nil }
                    baseDecodeTime = Int64(v)
                }
            case "trun":
                trunBox = box
            default:
                break
            }
        }
        // 只要视频轨的样本；moov 未到（videoTrackID == 0）时也跳过。
        guard trackID != 0, trackID == videoTrackID, let trun = trunBox else { return nil }
        return parseTrun(trun, baseDecodeTime: baseDecodeTime,
                         defaultDuration: defaultDuration,
                         defaultSize: defaultSize,
                         defaultFlags: defaultFlags)
    }

    private func parseTrun(_ trun: BoxReader, baseDecodeTime: Int64,
                           defaultDuration: UInt32?, defaultSize: UInt32?,
                           defaultFlags: UInt32?) -> [PendingSample] {
        var r = trun
        guard let verFlags = r.u32(), let sampleCount = r.u32() else { return [] }
        let version = verFlags >> 24
        let flags = verFlags & 0x00FF_FFFF
        if (flags & 0x000001) != 0 { _ = r.i32() } // data-offset
        var firstSampleFlags: UInt32?
        if (flags & 0x000004) != 0 { firstSampleFlags = r.u32() }
        var dts = baseDecodeTime
        var out: [PendingSample] = []
        out.reserveCapacity(Int(sampleCount))
        for i in 0..<Int(sampleCount) {
            let duration = ((flags & 0x000100) != 0) ? (r.u32() ?? 0) : (defaultDuration ?? 0)
            let size = ((flags & 0x000200) != 0) ? (r.u32() ?? 0) : (defaultSize ?? 0)
            var sampleFlags: UInt32?
            if (flags & 0x000400) != 0 { sampleFlags = r.u32() }
            var cts: Int64 = 0
            if (flags & 0x000800) != 0 {
                if version == 1 {
                    cts = Int64(r.i32() ?? 0)
                } else {
                    cts = Int64(r.u32() ?? 0)
                }
            }
            // 优先级：trun 单样本 flags > 首样本 flags > tfhd 默认 flags > 同步样本默认值。
            let resolvedFlags = sampleFlags ?? (i == 0 ? firstSampleFlags : nil) ?? defaultFlags ?? 0x0200_0000
            // sample-flags bit 16（sample_is_non_sync_sample）置位 = 非同步样本。
            let nonSync = (resolvedFlags & 0x0001_0000) != 0
            out.append(PendingSample(size: Int(size), duration: duration,
                                     pts: dts + cts, dts: dts, nonSync: nonSync))
            dts += Int64(duration)
        }
        return out
    }

    // MARK: 样本 → CMSampleBuffer

    private func emit(sample: PendingSample, data: [UInt8]) {
        guard let formatDescription = formatDescription, videoTimescale > 0 else { return }
        guard sample.size > 0, data.count == sample.size else { return }
        guard let sampleBuffer = makeSampleBuffer(data: data, sample: sample,
                                                  formatDescription: formatDescription) else { return }
        onSample?(sampleBuffer)
    }

    private func makeSampleBuffer(data: [UInt8], sample: PendingSample,
                                  formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        let mem = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        data.withUnsafeBytes { src in
            mem.copyMemory(from: src.baseAddress!, byteCount: data.count)
        }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mem,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: CMBlockBufferFlags(0),
            blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer = blockBuffer else {
            mem.deallocate()
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(sample.duration), timescale: Int32(videoTimescale)),
            presentationTimeStamp: CMTime(value: sample.pts, timescale: Int32(videoTimescale)),
            decodeTimeStamp: CMTime(value: sample.dts, timescale: Int32(videoTimescale)))
        var size = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer = sampleBuffer else { return nil }
        CMSetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        if sample.nonSync {
            CMSetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_NotSync,
                            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return sampleBuffer
    }
}

// MARK: - box 游标

/// 在 [UInt8] 上按大端读数的游标（moov/moof 解析用；越界返回 nil，不崩）。
private struct BoxReader {
    let bytes: [UInt8]
    var offset: Int
    let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.end = bytes.count
    }

    init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.offset = range.lowerBound
        self.end = range.upperBound
    }

    var remaining: Int { end - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        let v = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        offset += 2
        return v
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let v = (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        offset += 4
        return v
    }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        guard let hi = u32(), let lo = u32() else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }

    mutating func i32() -> Int32? {
        guard let v = u32() else { return nil }
        return Int32(bitPattern: v)
    }

    @discardableResult
    mutating func skip(_ count: Int) -> Bool {
        guard remaining >= count else { return false }
        offset += count
        return true
    }

    mutating func take(_ count: Int) -> [UInt8]? {
        guard remaining >= count else { return nil }
        let out = Array(bytes[offset..<(offset + count)])
        offset += count
        return out
    }

    mutating func fourCC() -> String? {
        guard let b = take(4) else { return nil }
        return String(bytes: b, encoding: .ascii)
    }

    /// 迭代子 box，返回 (type, payload 游标)。
    /// size==1 读 64 位 largesize；size==0 视为到父 box 末尾。
    func children() -> [(String, BoxReader)] {
        var out: [(String, BoxReader)] = []
        var r = self
        while r.remaining >= 8 {
            let boxStart = r.offset
            guard let size32 = r.u32(), let type = r.fourCC() else { break }
            var headerSize = 8
            var size = Int(size32)
            if size32 == 1 {
                guard let large = r.u64(), large <= UInt64(Int.max) else { break }
                size = Int(large)
                headerSize = 16
            } else if size32 == 0 {
                size = r.end - boxStart
            }
            guard size >= headerSize else { break }
            let payloadStart = boxStart + headerSize
            let payloadEnd = boxStart + size
            guard payloadEnd <= r.end else { break }
            out.append((type, BoxReader(r.bytes, range: payloadStart..<payloadEnd)))
            r.offset = payloadEnd
        }
        return out
    }
}

// MARK: - SwiftUI 宿主视图

/// 以 AVSampleBufferDisplayLayer 为 layer 的 UIView（layerClass 方式挂接）。
final class Fmp4DisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 把 Fmp4Player 的画面嵌进 SwiftUI：内含 AVSampleBufferDisplayLayer，
/// videoGravity .resizeAspect（等比，不拉伸）。
struct Fmp4PlayerView: UIViewRepresentable {
    @ObservedObject var player: Fmp4Player

    func makeUIView(context: Context) -> Fmp4DisplayView {
        let view = Fmp4DisplayView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        player.attach(layer: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: Fmp4DisplayView, context: Context) {
        if uiView.displayLayer !== player.displayLayer {
            player.attach(layer: uiView.displayLayer)
        }
        if uiView.displayLayer.status == .failed, let error = uiView.displayLayer.error {
            player.reportLayerError(error)
        }
    }
}
