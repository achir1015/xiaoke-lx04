import AVKit
import SwiftUI

@main
struct XiaoKeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            GeometryReader { geo in
                FaceCanvas(face: app.face, renderer: app.renderer)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.6).onEnded { _ in app.showInfo() }
                            .exclusively(before: SpatialTapGesture().onEnded { v in app.tap(v.location, in: geo.size) })
                    )
            }
            .ignoresSafeArea()

            if app.webShown {
                WebViewRep(web: app.web).ignoresSafeArea(edges: .bottom)
                VStack {
                    HStack {
                        Button(app.webBarTitle) { app.webBack() }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color(red: 0x16 / 255, green: 0x2A / 255, blue: 0x42 / 255).opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .opacity(app.webBarAlpha)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }

            if let p = app.mvPlayer {
                ZStack(alignment: .topLeading) {
                    Color.black.ignoresSafeArea()
                    VideoPlayer(player: p).ignoresSafeArea()
                    HStack(spacing: 10) {
                        mvButton(app.mvPaused ? "▶︎ 繼續" : "⏸ 暫停") { app.toggleMVPause() }
                        mvButton("⏹ 停止") { app.closeMV() }
                        Text(app.mvTitle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 3)
                    }
                    .padding(8)
                }
            }

            if let t = app.toast {
                Text(t)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.5)))
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { app.scene(phase) }
        .onChange(of: phase) { _, p in app.scene(p) }
    }
}

/// MV 畫面左上角的大按鈕。
private func mvButton(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button(title, action: action)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25)))
}
