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
