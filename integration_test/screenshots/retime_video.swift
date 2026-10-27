// Speeds a recording up and writes it as a small, muted H.264 MP4 at a steady
// frame rate. Run by `record_video.sh`:
//
//   swift retime_video.swift <source> <output.mp4> <factor> <fps> <bits per second>
//
// For each output frame, the newest source frame at or before that moment (in
// sped-up time) is used. A plain time-squeeze keeps every source frame, which
// at 4x made a 178 fps file over the 2 MB budget; resampling to a fixed rate
// keeps the motion smooth and the file small. Apple's own AVFoundation, because
// there is no ffmpeg on this machine.
import AVFoundation
let a = CommandLine.arguments
let src = URL(fileURLWithPath: a[1]), dst = URL(fileURLWithPath: a[2])
let factor = Double(a[3])!, fps = Int32(a[4])!, bitrate = Int(a[5])!
let sem = DispatchSemaphore(value: 0)
Task {
  let asset = AVURLAsset(url: src)
  let vt = try await asset.loadTracks(withMediaType: .video).first!
  let size = try await vt.load(.naturalSize)
  let reader = try AVAssetReader(asset: asset)
  let out = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(out); reader.startReading()
  try? FileManager.default.removeItem(at: dst)
  let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
  let w = Int(size.width) & ~1, h = Int(size.height) & ~1
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: fps,
                                      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
  writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
  var first: Double? = nil, prev: CVPixelBuffer? = nil, tick: Int64 = 0, written = 0
  func emit(_ pb: CVPixelBuffer, _ k: Int64) {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    adaptor.append(pb, withPresentationTime: CMTime(value: k, timescale: fps)); written += 1
  }
  while let sb = out.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
    if first == nil { first = t }
    let scaled = (t - first!) / factor
    // every tick that falls before this frame shows the previous frame
    while let p = prev, Double(tick) / Double(fps) < scaled { emit(p, tick); tick += 1 }
    prev = pb
  }
  if let p = prev { emit(p, tick); tick += 1 }
  input.markAsFinished()
  await writer.finishWriting()
  print("wrote \(written) frames, \(Double(tick)/Double(fps)) s at \(fps) fps, status \(writer.status.rawValue)", writer.error ?? "")
  sem.signal()
}
sem.wait()
