import Foundation
import CoreGraphics
setvbuf(stdout, nil, _IONBF, 0)
let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
typealias FnCopy = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
typealias FnSetData = @convention(c) (CGDirectDisplayID, Int32, CFDictionary) -> Int32
typealias FnB = @convention(c) (CGDirectDisplayID, Int32) -> Bool
var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 })!
let copyD = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_CopyPresetData")!, to: FnCopy.self)
let setD  = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_SetPresetData")!, to: FnSetData.self)
let setP  = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_SetPreset")!, to: FnSetData.self)
let wr    = unsafeBitCast(dlsym(cd,"CoreDisplay_Display_IsPresetWritable")!, to: FnB.self)
let base  = copyD(d, 0)!.takeRetainedValue() as! [String: Any]
let SLOT: Int32 = 11
print("слот \(SLOT) записываемый: \(wr(d, SLOT))")

func newUUID() -> Data { var b = [UInt8](repeating: 0, count: 16); _ = SecRandomCopyBytes(kSecRandomDefault, 16, &b); return Data(b) }

func attempt(_ label: String, _ fn: FnSetData, _ dict: [String: Any]) {
    let rc = fn(d, SLOT, dict as CFDictionary)
    let back = (copyD(d, SLOT)?.takeRetainedValue() as? [String: Any])?["PresetName"] as? String
    print("  \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) rc=\(rc)  слот=\(back ?? "пусто")")
}

var a = base; a["PresetMaxSDRLuminance"] = 1000; a["PresetName"] = "Lumen A"
attempt("SetPresetData, весь базовый словарь как есть", setD, a)

var b = base; b["PresetMaxSDRLuminance"] = 1000; b["PresetName"] = "Lumen B"
b["PresetUniqueID"] = newUUID(); b["PresetValid"] = 1
attempt("SetPresetData, новый UUID + Valid=1", setD, b)

var c = base; c["PresetMaxSDRLuminance"] = 1000; c["PresetName"] = "Lumen C"
c["PresetUniqueID"] = newUUID(); c["PresetValid"] = 1; c["PresetOrigin"] = 1
attempt("SetPresetData, + Origin=1 (пользовательский)", setD, c)

var e = base; e["PresetMaxSDRLuminance"] = 1000; e["PresetName"] = "Lumen E"
e["PresetUniqueID"] = newUUID(); e["PresetValid"] = 1
attempt("SetPreset (другая функция)", setP, e)

let f: [String: Any] = ["PresetName": "Lumen F", "PresetMaxSDRLuminance": 1000,
                        "PresetMaxHDRLuminance": 1600, "PresetValid": 1,
                        "PresetUniqueID": newUUID()]
attempt("SetPresetData, минимальный словарь", setD, f)

print("\nuid=\(getuid())  euid=\(geteuid())")
