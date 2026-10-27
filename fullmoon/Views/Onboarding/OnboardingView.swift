//
//  OnboardingView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftUI

struct OnboardingView: View {
    @Binding var showOnboarding: Bool
    @Environment(ModelDownloader.self) var downloader
    
    var body: some View {
        NavigationStack {
            if downloader.phase == .notStarted {
                welcome
            } else {
                // a download already under way (or paused) goes straight to its progress
                OnboardingDownloadingModelProgressView(showOnboarding: $showOnboarding)
            }
        }
    }

    var welcome: some View {
            VStack {
                Spacer()
                
                VStack(spacing: 12) {
                    Image(.logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                    
                    VStack(spacing: 4) {
                        Text("lantern")
                            .font(.title)
                            .fontWeight(.semibold)
                        Text("private chat with Gemma, running entirely on your iPhone")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                Spacer()
                                
                VStack(alignment: .leading, spacing: 24) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("fast")
                                .font(.headline)
                            Text("Gemma 4 E4B, built by Google for phones, on Apple's MLX")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "message")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 8)
                    }
                    
                    Label {
                        VStack(alignment: .leading) {
                            Text("private")
                                .font(.headline)
                            Text("nothing leaves your device, and it works offline")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.shield")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 8)
                    }
                    
                    Label {
                        VStack(alignment: .leading) {
                            Text("open source")
                                .font(.headline)
                            Text("view and contribute to the source code")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                
                Spacer()
                
                NavigationLink(destination: OnboardingDownloadingModelProgressView(showOnboarding: $showOnboarding)) {
                    Text("get started")
                        #if os(iOS) || os(visionOS)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        #endif
                        #if os(iOS)
                        .foregroundStyle(.background)
                        #endif
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.horizontal)
                .accessibilityIdentifier("getStarted")
            }
            .padding()
            .navigationTitle("welcome")
            .toolbar(.hidden)
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
    }
}

#Preview {
    OnboardingView(showOnboarding: .constant(true))
        .environment(ModelDownloader.shared)
}
