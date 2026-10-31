import Foundation
// Выгружает первые N байт функции по имени — для дизассемблирования снаружи.
let libs = ["/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"]
let handles = libs.map { dlopen($0, RTLD_NOW) }
let name = CommandLine.arguments[1]
let n = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 96
var p: UnsafeMutableRawPointer? = nil
for h in handles { if let s = dlsym(h, name) { p = s; break } }
guard let fn = p else { FileHandle.standardError.write("НЕ НАЙДЕН \(name)\n".data(using: .utf8)!); exit(1) }
let bytes = UnsafeRawBufferPointer(start: fn, count: n)
print(bytes.map { String(format: "0x%02x", $0) }.joined(separator: " "))
