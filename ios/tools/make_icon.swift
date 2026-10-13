import SwiftUI
import AppKit
// 用法：mkicon 輸出.png [邊長=1024] [圖案縮放=1]
MainActor.assumeIsolated {
  let args = CommandLine.arguments
  let px = args.count > 2 ? Int(args[2])! : 1024
  let scale = args.count > 3 ? CGFloat(Double(args[3])!) : 1
  let r = FaceRenderer()
  let v = Canvas { ctx, size in r.drawIcon(ctx, size: size, contentScale: scale) }.frame(width: CGFloat(px), height: CGFloat(px))
  let ir = ImageRenderer(content: v); ir.scale = 1
  let cg = ir.cgImage!
  // 去掉 alpha（App Store 圖示不可透明）
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
  print("ok", args[1])
}
