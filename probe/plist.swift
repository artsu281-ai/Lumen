import Foundation
import CoreGraphics
setvbuf(stdout, nil, _IONBF, 0)
let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
typealias FnInt  = @convention(c) (CGDirectDisplayID) -> Int32
typealias FnCopy = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
typealias FnB    = @convention(c) (CGDirectDisplayID, Int32) -> Bool
var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 })!
let count  = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetPresetCount")!, to: FnInt.self)(d)
let active = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetActivePresetIndex")!, to: FnInt.self)(d)
let copyD  = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_CopyPresetData")!, to: FnCopy.self)
let wr     = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_IsPresetWritable")!, to: FnB.self)
let vd     = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_IsPresetValid")!, to: FnB.self)
print("idx  зап вал  maxSDR maxHDR  slider    headroom  имя")
for i in 0..<count {
    guard let dict = copyD(d, i)?.takeRetainedValue() as? [String: Any] else { continue }
    let name = (dict["PresetName"] as? String) ?? "—"
    let sdr  = dict["PresetMaxSDRLuminance"] ?? "—"
    let hdr  = dict["PresetMaxHDRLuminance"] ?? "—"
    let smax = dict["PresetHostMaxSliderBrightness"] ?? "—"
    let hr   = dict["PresetHostAlwaysRequestMaxHeadroom"] ?? "—"
    let mark = i == active ? "←" : " "
    print(String(format: "%3d%@ %-3@ %-3@  %-6@ %-6@  %-8@  %-8@  %@", i, mark,
                 "\(wr(d,i) ? "да" : "нет")" as NSString, "\(vd(d,i) ? "да" : "нет")" as NSString,
                 "\(sdr)" as NSString, "\(hdr)" as NSString, "\(smax)" as NSString,
                 "\(hr)" as NSString, name as NSString))
}
