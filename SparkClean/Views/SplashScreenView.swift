//
//  SplashScreenView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AVKit

struct SplashScreenView: View {
    let onFinished: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black

            if let player {
                VideoPlayerView(player: player)
                    .scaleEffect(1.15)
                    .clipped()
            }

            Button {
                player?.pause()
                onFinished()
            } label: {
                HStack(spacing: 4) {
                    Text("Skip")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "forward.fill")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .padding(20)
        }
        .onAppear {
            guard let url = Bundle.main.url(forResource: "Spinning_Logo_Video_Generation", withExtension: "mp4") else {
                onFinished()
                return
            }
            let avPlayer = AVPlayer(url: url)
            avPlayer.volume = 1.0
            self.player = avPlayer

            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                onFinished()
            }

            avPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let playerLayer = nsView.layer?.sublayers?.first as? AVPlayerLayer {
            playerLayer.frame = nsView.bounds
        }
    }
}
