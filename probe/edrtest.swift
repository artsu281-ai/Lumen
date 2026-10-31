import Cocoa
import Metal
import QuartzCore

setvbuf(stdout, nil, _IONBF, 0)

let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
typealias FRet = @convention(c) (CGDirectDisplayID) -> Float
let cur = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetCurrentHeadroom")!, to: FRet.self)
let pot = unsafeBitCast(dlsym(cd, "CoreDisplay_Display_GetPotentialHeadroom")!, to: FRet.self)

var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let disp = ids.first(where: { CGDisplayIsBuiltin($0) != 0 })!

var drawOK = 0, drawFail = 0
func headroom(_ tag: String) {
    let scr = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == disp
    }) ?? NSScreen.main!
    let edr = scr.maximumExtendedDynamicRangeColorComponentValue
    let pedr = scr.maximumPotentialExtendedDynamicRangeColorComponentValue
    let redr = scr.maximumReferenceExtendedDynamicRangeColorComponentValue
    print("\(tag) CoreDisplay cur=\(cur(disp)) pot=\(pot(disp)) | NSScreen edr=\(edr) pot=\(pedr) ref=\(redr) | drawable ok=\(drawOK) fail=\(drawFail)")
}

headroom("до создания слоя:")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .rgba16Float
layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
layer.wantsExtendedDynamicRangeContent = true   // ключевой флаг: просим EDR у системы
layer.framebufferOnly = false
layer.drawableSize = CGSize(width: 128, height: 128)

let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 128),
                   styleMask: .borderless, backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.ignoresMouseEvents = true
win.level = .normal
win.setFrameOrigin(NSPoint(x: 400, y: 400))
let view = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
view.wantsLayer = true
view.layer = layer
win.contentView = view
win.orderFrontRegardless()

// Заливаем слой значением сильно выше 1.0 — это и есть HDR-контент.
func draw(_ level: Double) {
    guard let d = layer.nextDrawable() else { drawFail += 1; return }
    drawOK += 1
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = d.texture
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(red: level, green: level, blue: level, alpha: 1)
    let cb = queue.makeCommandBuffer()!
    cb.makeRenderCommandEncoder(descriptor: rp)!.endEncoding()
    cb.present(d)
    cb.commit()
}

var tick = 0
let timer = Timer(timeInterval: 0.5, repeats: true) { t in
    draw(8.0)
    tick += 1
    headroom("слой активен, тик \(tick):")
    if tick >= 10 { t.invalidate(); headroom("итог:"); exit(0) }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
