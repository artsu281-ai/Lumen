import Foundation
import CoreGraphics
setvbuf(stdout, nil, _IONBF, 0)
let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
typealias FnGet = @convention(c) (CGDirectDisplayID) -> Int32
typealias FnSet = @convention(c) (CGDirectDisplayID, Int32) -> Int32
typealias FnCopy = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
typealias FnSetData = @convention(c) (CGDirectDisplayID, Int32, CFDictionary) -> Int32
typealias FnF = @convention(c) (CGDirectDisplayID) -> Float
var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 })!
let getIdx = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_GetActivePresetIndex")!, to: FnGet.self)
let setIdx = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_SetActivePresetIndex")!, to: FnSet.self)
let copyD  = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_CopyPresetData")!, to: FnCopy.self)
let setD   = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_SetPresetData")!, to: FnSetData.self)
let head   = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_GetCurrentHeadroom")!, to: FnF.self)
let SLOT: Int32 = 11

func state(_ t: String) {
    let i = getIdx(d)
    let nm = (copyD(d, i)?.takeRetainedValue() as? [String: Any])?["PresetName"] as? String ?? "—"
    print("\(t) активный=\(i) «\(nm)» headroom=\(head(d))")
}

state("исходно: ")
var p = (copyD(d, 0)!.takeRetainedValue() as! [String: Any])
p["PresetMaxSDRLuminance"]              = 1000
p["PresetHostMaxSliderBrightness"]      = 1000
p["PresetHostAlwaysRequestMaxHeadroom"] = 1
p["PresetName"]                         = "Lumen 1000 nits"
p["PresetUniqueID"]                     = nil

let rcWrite = setD(d, SLOT, p as CFDictionary)
print("SetPresetData(слот \(SLOT)) rc=\(rcWrite)")
if let back = copyD(d, SLOT)?.takeRetainedValue() as? [String: Any] {
    print("  прочитано обратно: «\(back["PresetName"] ?? "—")» maxSDR=\(back["PresetMaxSDRLuminance"] ?? "—") headroomFlag=\(back["PresetHostAlwaysRequestMaxHeadroom"] ?? "—")")
} else { print("  слот всё ещё пуст — запись не прошла") }

let rcAct = setIdx(d, SLOT)
print("SetActivePresetIndex(\(SLOT)) rc=\(rcAct)")
usleep(2_500_000)
state("после:   ")
print("→ откат")
_ = setIdx(d, 0)
usleep(1_500_000)
state("итог:    ")
