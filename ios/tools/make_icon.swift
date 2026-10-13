import SwiftUI
import AppKit
MainActor.assumeIsolated {
  let r = FaceRenderer()
  let v = Canvas { ctx, size in r.drawIcon(ctx, size: size) }.frame(width: 1024, height: 1024)
  let ir = ImageRenderer(content: v); ir.scale = 1
  let cg = ir.cgImage!
  // 去掉 alpha（App Store 圖示不可透明）
  let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
  print("ok")
}
