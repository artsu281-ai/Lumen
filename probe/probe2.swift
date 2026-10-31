import Foundation
import CoreGraphics

setvbuf(stdout, nil, _IONBF, 0)

let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)
let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 })!

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: probe2 <symbol> <variant>"); exit(2) }
let name = args[1], variant = args[2]
guard let p = dlsym(cd, name) ?? dlsym(ds, name) else { print("НЕ НАЙДЕН"); exit(3) }

typealias A_RetDouble = @convention(c) (CGDirectDisplayID) -> Double
typealias A_RetFloat  = @convention(c) (CGDirectDisplayID) -> Float
typealias A_RetInt    = @convention(c) (CGDirectDisplayID) -> Int32
typealias B_OutFloat  = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>)  -> Int32
typealias B_OutDouble = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Double>) -> Int32
typealias R_OutFF     = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>,  UnsafeMutablePointer<Float>)  -> Int32
typealias R_OutII     = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>,  UnsafeMutablePointer<Int32>)  -> Int32

switch variant {
case "d":  print(unsafeBitCast(p, to: A_RetDouble.self)(d))
case "f":  print(unsafeBitCast(p, to: A_RetFloat.self)(d))
case "i":  print(unsafeBitCast(p, to: A_RetInt.self)(d))
case "of": var v: Float  = -12345; let rc = unsafeBitCast(p, to: B_OutFloat.self)(d, &v);  print("v=\(v) rc=\(rc)")
case "od": var v: Double = -12345; let rc = unsafeBitCast(p, to: B_OutDouble.self)(d, &v); print("v=\(v) rc=\(rc)")
case "rff": var a: Float = -1, b: Float = -1; let rc = unsafeBitCast(p, to: R_OutFF.self)(d, &a, &b); print("\(a) ... \(b)  rc=\(rc)")
case "rii": var a: Int32 = -1, b: Int32 = -1; let rc = unsafeBitCast(p, to: R_OutII.self)(d, &a, &b); print("\(a) ... \(b)  rc=\(rc)")
default: print("неизвестный вариант"); exit(2)
}
