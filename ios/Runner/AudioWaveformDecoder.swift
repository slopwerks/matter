import AVFoundation
import Flutter

/// AVAssetReader returns bounded PCM buffers; only RMS buckets are retained.
enum AudioWaveformDecoder {
  private static let queue = DispatchQueue(label: "matter.audio.waveform", qos: .utility)
  private static var jobs: [String: Job] = [:] // Accessed on the platform/main thread.

  private final class Job {
    let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let values = call.arguments as? [String: Any], let id = values["jobId"] as? String else {
      result(FlutterError(code: "waveform_invalid", message: "波形请求无效", details: nil)); return
    }
    if call.method == "cancelWaveform" {
      jobs[id]?.cancel(); result(nil); return
    }
    guard let path = values["path"] as? String, let count = (values["sampleCount"] as? NSNumber)?.intValue,
      (1...512).contains(count), id.count <= 80, jobs.count < 8, jobs[id] == nil
    else {
      result(FlutterError(code: "waveform_invalid", message: "波形请求无效", details: nil)); return
    }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let root = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
    guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path) else {
      result(FlutterError(code: "waveform_invalid", message: "波形来源无效", details: nil)); return
    }
    let job = Job()
    jobs[id] = job
    queue.async {
      let outcome = Result { try decode(url: url, count: count, job: job) }
      DispatchQueue.main.async {
        jobs.removeValue(forKey: id)
        switch outcome {
        case .success(let points): result(points)
        case .failure: result(FlutterError(code: "waveform_failed", message: "无法提取此音频的波形", details: nil))
        }
      }
    }
  }

  private static func decode(url: URL, count: Int, job: Job) throws -> [Double] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else { throw DecodeError.unavailable }
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration.isFinite, duration > 0 else { throw DecodeError.unavailable }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw DecodeError.unavailable }
    reader.add(output)
    guard reader.startReading() else { throw DecodeError.unavailable }
    defer { reader.cancelReading() }
    let deadline = Date().addingTimeInterval(45)
    var energy = [Double](repeating: 0, count: count)
    var counts = [Int](repeating: 0, count: count)
    var framesRead = 0
    while let sample = output.copyNextSampleBuffer() {
      guard !job.isCancelled(), Date() < deadline else { throw DecodeError.cancelled }
      guard let format = CMSampleBufferGetFormatDescription(sample),
        let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format),
        let block = CMSampleBufferGetDataBuffer(sample)
      else { throw DecodeError.unavailable }
      let rate = audio.pointee.mSampleRate
      let channels = Int(audio.pointee.mChannelsPerFrame)
      guard rate > 0, channels > 0 else { throw DecodeError.unavailable }
      let length = CMBlockBufferGetDataLength(block)
      guard length > 0 else { continue }
      guard length <= 4 * 1024 * 1024 else { throw DecodeError.unavailable }
      var bytes = Data(count: length)
      let status = bytes.withUnsafeMutableBytes { raw in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { throw DecodeError.unavailable }
      let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
      guard timestamp.isFinite else { throw DecodeError.unavailable }
      bytes.withUnsafeBytes { raw in
        let frames = length / (2 * channels)
        for frame in 0..<frames {
          let time = max(0, timestamp) + Double(frame) / rate
          let bucket = min(count - 1, max(0, Int(time / duration * Double(count))))
          for channel in 0..<channels {
            let integer = raw.loadUnaligned(fromByteOffset: (frame * channels + channel) * 2, as: Int16.self).littleEndian
            let value = Double(integer) / 32768
            energy[bucket] += value * value
            counts[bucket] += 1
          }
          framesRead += 1
        }
      }
    }
    guard reader.status == .completed, !job.isCancelled(), framesRead > 0 else { throw DecodeError.unavailable }
    let rms = energy.indices.map { counts[$0] == 0 ? 0 : sqrt(energy[$0] / Double(counts[$0])) }
    let maximum = rms.max() ?? 0
    return maximum == 0 ? rms : rms.map { $0 / maximum }
  }

  private enum DecodeError: Error { case unavailable, cancelled }
}
