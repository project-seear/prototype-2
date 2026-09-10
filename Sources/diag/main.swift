import AVFoundation
import Core
import Foundation

// Acoustic fingerprint of each stimulus. Run after any change to Stimulus.swift:
// the FNV hashes for `original` and `sharp` must never move, since those two are
// frozen baselines shared with earlier sessions.
//
//   original  fnv1a=13103158ac5a43bb
//   sharp     fnv1a=527fab1e6dbd247f
let sr = 48000.0
func fnv(_ x: [Float]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for v in x {
        var b = v.bitPattern
        for _ in 0..<4 { h = (h ^ UInt64(b & 0xff)) &* 0x100000001b3; b >>= 8 }
    }
    return h
}
func band(_ x: [Float], _ lo: Double?, _ hi: Double?) -> Double {
    var y = x.map { Double($0) }
    if let f = lo {
        var a = Biquad.highpass(f, q: 0.707, sr: sr), b = Biquad.highpass(f, q: 0.707, sr: sr)
        a.runCircular(&y); b.runCircular(&y)
    }
    if let f = hi {
        var a = Biquad.lowpass(f, q: 0.707, sr: sr), b = Biquad.lowpass(f, q: 0.707, sr: sr)
        a.runCircular(&y); b.runCircular(&y)
    }
    let r = (y.map { $0 * $0 }.reduce(0, +) / Double(y.count)).squareRoot()
    let t = (x.map { Double($0) * Double($0) }.reduce(0, +) / Double(x.count)).squareRoot()
    return r / max(t, 1e-12)
}
print(String(format: "%-9@ %18@ %8@ %8@ %8@ %9@ %9@ %8@", "stimulus" as NSString,
             "fnv1a" as NSString, "rms" as NSString, "peak" as NSString, "crest" as NSString,
             "<300Hz" as NSString, "350-1.5k" as NSString, "2-8kHz" as NSString))
for s in Stimulus.allCases {
    let b = StimulusGenerator.buffer(s, format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!)
    let p = b.floatChannelData![0]
    let a = (0..<Int(b.frameLength)).map { p[$0] }
    var peak = 0.0, sum = 0.0
    for v in a { peak = max(peak, abs(Double(v))); sum += Double(v) * Double(v) }
    let rms = (sum / Double(a.count)).squareRoot()
    print(String(format: "%-9@ %016llx %9.4f %8.4f %8.2f %9.3f %9.3f %8.3f",
                 s.rawValue as NSString, fnv(a), rms, peak, peak / rms,
                 band(a, nil, 300), band(a, 350, 1500), band(a, 2000, 8000)))
}
