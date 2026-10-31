import Foundation
import CoreGraphics
setvbuf(stdout, nil, _IONBF, 0)
let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
typealias FnGet = @convention(c) (CGDirectDisplayID) -> Int32
typealias FnSet = @convention(c) (CGDirectDisplayID, Int32) -> Int32
typealias FnCopy = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 })!
let getIdx = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetActivePresetIndex")!, to: FnGet.self)
let setIdx = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_SetActivePresetIndex")!, to: FnSet.self)
let copyD  = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_CopyPresetData")!, to: FnCopy.self)

func describe(_ i: Int32) -> String {
    guard let dt = copyD(d, i)?.takeRetainedValue() as? [String: Any] else { return "слот \(i): пусто" }
    return "слот \(i): \((dt["PresetName"] as? String) ?? "—")  maxSDR=\(dt["PresetMaxSDRLuminance"] ?? "—") maxHDR=\(dt["PresetMaxHDRLuminance"] ?? "—")"
}
if CommandLine.arguments.count > 1, let target = Int32(CommandLine.arguments[1]) {
    print("было  → \(describe(getIdx(d)))")
    let rc = setIdx(d, target)
    usleep(1_500_000)
    print("rc=\(rc)")
    print("стало → \(describe(getIdx(d)))")
} else {
    print("активен → \(describe(getIdx(d)))")
}
