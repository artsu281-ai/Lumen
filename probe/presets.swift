import Foundation
import CoreGraphics
setvbuf(stdout, nil, _IONBF, 0)

let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
typealias FnInt   = @convention(c) (CGDirectDisplayID) -> Int32
typealias FnCopy  = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
typealias FnValid = @convention(c) (CGDirectDisplayID, Int32) -> Bool

var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 })!

let count  = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetPresetCount")!,       to: FnInt.self)(d)
let active = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetActivePresetIndex")!, to: FnInt.self)(d)
let deflt  = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetFactoryDefaultPresetIndex")!, to: FnInt.self)(d)
print("дисплей id=\(d)   пресетов=\(count)   активный=\(active)   заводской=\(deflt)")

let copyData = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_CopyPresetData")!, to: FnCopy.self)
let writable = dlsym(cd, "CoreDisplay_Display_IsPresetWritable").map { unsafeBitCast($0, to: FnValid.self) }

guard count > 0 else { print("пресетов нет — путь закрыт"); exit(0) }

for i in 0..<count {
    print("\n=== пресет \(i)\(i == active ? "  ← АКТИВНЫЙ" : "")\(i == deflt ? "  (заводской)" : "") ===")
    if let w = writable { print("  записываемый: \(w(d, i))") }
    guard let dict = copyData(d, i)?.takeRetainedValue() as? [String: Any] else {
        print("  данные не получены"); continue
    }
    for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
        let vs = "\(v)".replacingOccurrences(of: "\n", with: " ")
        print("  \(k.padding(toLength: 42, withPad: " ", startingAt: 0)) = \(vs.prefix(90))")
    }
}
