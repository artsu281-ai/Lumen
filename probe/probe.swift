import Foundation
setvbuf(stdout, nil, _IONBF, 0)
import CoreGraphics

// Приватные фреймворки грузим динамически: линковаться с ними нельзя.
let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)

func sym(_ h: UnsafeMutableRawPointer?, _ n: String) -> UnsafeMutableRawPointer? {
    guard let h else { return nil }
    return dlsym(h, n)
}

typealias FnGetFloat   = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias FnRange      = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
typealias FnCanChange  = @convention(c) (CGDirectDisplayID) -> Bool
typealias FnRetDouble  = @convention(c) (CGDirectDisplayID) -> Double
typealias FnRetFloat   = @convention(c) (CGDirectDisplayID) -> Float
typealias FnRetBool    = @convention(c) (CGDirectDisplayID) -> Bool

// --- находим встроенный дисплей ---
var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)

guard let builtIn = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
    print("встроенный дисплей не найден"); exit(1)
}
print("=== дисплей ===")
print("CGDirectDisplayID : \(builtIn)")
print("разрешение        : \(CGDisplayPixelsWide(builtIn))x\(CGDisplayPixelsHigh(builtIn))")

// --- DisplayServices: шкала яркости ---
print("\n=== DisplayServices ===")
if let p = sym(ds, "DisplayServicesCanChangeBrightness") {
    print("CanChangeBrightness            : \(unsafeBitCast(p, to: FnCanChange.self)(builtIn))")
}
for name in ["DisplayServicesGetBrightness", "DisplayServicesGetLinearBrightness"] {
    if let p = sym(ds, name) {
        var v: Float = -1
        let rc = unsafeBitCast(p, to: FnGetFloat.self)(builtIn, &v)
        print("\(name.padding(toLength: 31, withPad: " ", startingAt: 0)): \(v)   (rc=\(rc))")
    } else { print("\(name): НЕ НАЙДЕН") }
}
if let p = sym(ds, "DisplayServicesGetLinearBrightnessUsableRange") {
    var lo: Int32 = -1, hi: Int32 = -1
    let rc = unsafeBitCast(p, to: FnRange.self)(builtIn, &lo, &hi)
    print("LinearBrightnessUsableRange    : \(lo) ... \(hi)   (rc=\(rc))")
}

// --- CoreDisplay: ниты и EDR ---
print("\n=== CoreDisplay: ниты ===")
for name in ["CoreDisplay_Display_GetDisplayBrightnessInNits",
             "CoreDisplay_Display_GetNominalPixelNits",
             "CoreDisplay_Display_GetUserBrightness",
             "CoreDisplay_Display_GetLinearBrightness",
             "CoreDisplay_Display_GetDynamicLinearBrightness"] {
    guard let p = sym(cd, name) else { print("\(name): НЕ НАЙДЕН"); continue }
    let d = unsafeBitCast(p, to: FnRetDouble.self)(builtIn)
    let f = unsafeBitCast(p, to: FnRetFloat.self)(builtIn)
    print("\(name.dropFirst(22).padding(toLength: 30, withPad: " ", startingAt: 0)): double=\(d)  float=\(f)")
}

print("\n=== CoreDisplay: EDR ===")
for name in ["CoreDisplay_Display_IsEDREnabled",
             "CoreDisplay_Display_IsHDRModeEnabled",
             "CoreDisplay_Display_IsHDR10"] {
    guard let p = sym(cd, name) else { print("\(name): НЕ НАЙДЕН"); continue }
    print("\(name.dropFirst(22).padding(toLength: 30, withPad: " ", startingAt: 0)): \(unsafeBitCast(p, to: FnRetBool.self)(builtIn))")
}
for name in ["CoreDisplay_Display_GetCurrentHeadroom",
             "CoreDisplay_Display_GetPotentialHeadroom",
             "CoreDisplay_Display_GetReferenceHeadroom"] {
    guard let p = sym(cd, name) else { print("\(name): НЕ НАЙДЕН"); continue }
    let d = unsafeBitCast(p, to: FnRetDouble.self)(builtIn)
    let f = unsafeBitCast(p, to: FnRetFloat.self)(builtIn)
    print("\(name.dropFirst(22).padding(toLength: 30, withPad: " ", startingAt: 0)): double=\(d)  float=\(f)")
}
