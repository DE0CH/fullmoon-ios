//
//  OnboardingDownloadingModelProgressView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftUI

struct OnboardingDownloadingModelProgressView: View {
    @Binding var showOnboarding: Bool
    @EnvironmentObject var appManager: AppManager
    @Environment(ModelDownloader.self) var downloader

    var title: String {
        switch downloader.phase {
        case .notStarted: "download gemma"
        case .downloading: "downloading"
        case .paused: "paused"
        case .verifying: "checking"
        case .ready: "ready"
        case .failed: "download stopped"
        }
    }

    var detail: String {
        let got = ModelDownloader.format(downloader.receivedBytes)
        let total = ModelDownloader.format(downloader.totalBytes)
        switch downloader.phase {
        case .notStarted:
            return "a one-time \(total) download. after that, everything runs on this iPhone, even offline."
        case .downloading:
            var parts = ["\(got) of \(total)"]
            if downloader.bytesPerSecond > 1 {
                parts.append("\(ModelDownloader.format(Int64(downloader.bytesPerSecond)))/s")
            }
            if let left = downloader.secondsLeft {
                parts.append(Self.formatLeft(left))
            }
            return parts.joined(separator: " · ")
        case .paused:
            return "\(got) of \(total)"
        case .verifying:
            return "making sure every byte arrived intact"
        case .ready:
            return "everything runs on this iPhone now"
        case .failed(let reason):
            return reason
        }
    }

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 16) {
                MoonAnimationView(isDone: downloader.isReady)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.title)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("downloadTitle")
                    Text(downloader.spec.displayName)
                        .foregroundStyle(.secondary)
                }

                if downloader.phase != .notStarted {
                    ProgressView(value: downloader.fraction, total: 1)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 48)
                }

                Text(detail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("downloadDetail")

                if let note = downloader.note, downloader.phase == .downloading {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            if downloader.phase == .downloading || downloader.phase == .paused {
                Text("the download keeps going when you leave the app or lock your phone. you'll get a notification when it's done.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            actionButton
        }
        .padding()
        .navigationTitle("")
        .toolbar(.hidden)
        .navigationBarBackButtonHidden()
        .animation(.default, value: downloader.phase)
        .sensoryFeedback(.success, trigger: downloader.isReady)
        .interactiveDismissDisabled(!downloader.isReady)
    }

    @ViewBuilder var actionButton: some View {
        switch downloader.phase {
        case .notStarted:
            capsule("download", id: "download", prominent: true) { downloader.start() }
        case .downloading:
            capsule("pause", id: "pause", prominent: false) { downloader.pause() }
        case .paused, .failed:
            capsule("resume", id: "resume", prominent: true) { downloader.start() }
        case .verifying:
            capsule("checking…", id: "checking", prominent: false) {}
                .disabled(true)
        case .ready:
            capsule("start chatting", id: "done", prominent: true) { showOnboarding = false }
        }
    }

    func capsule(_ label: String, id: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            appManager.playHaptic()
            action()
        } label: {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundStyle(prominent ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
        }
        .if(prominent) { $0.buttonStyle(.borderedProminent) }
        .if(!prominent) { $0.buttonStyle(.bordered) }
        .buttonBorderShape(.capsule)
        .padding(.horizontal)
        .accessibilityIdentifier(id)
    }

    static func formatLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "under a minute left" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return "\(formatter.string(from: seconds) ?? "") left"
    }
}

#Preview {
    OnboardingDownloadingModelProgressView(showOnboarding: .constant(true))
        .environmentObject(AppManager())
        .environment(ModelDownloader.shared)
}
