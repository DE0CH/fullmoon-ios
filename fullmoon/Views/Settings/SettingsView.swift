//
//  SettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(\.dismiss) var dismiss
    @Environment(LLMEvaluator.self) var llm
    @Environment(ModelDownloader.self) var downloader
    @Binding var currentThread: Thread?
    @State var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label("appearance", systemImage: "paintpalette")
                    }

                    NavigationLink(destination: ChatsSettingsView(currentThread: $currentThread)) {
                        Label("chats", systemImage: "message")
                    }

                }

                Section {
                    Label {
                        Text(downloader.spec.displayName)
                    } icon: {
                        Image(systemName: "cpu")
                    }
                    .badge(ModelDownloader.format(downloader.totalBytes))

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("delete model", systemImage: "trash")
                    }
                    .disabled(llm.running)
                    .confirmationDialog("delete \(downloader.spec.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("delete and download again", role: .destructive) {
                            llm.loadState = .idle
                            downloader.deleteModel()
                            dismiss()
                        }
                    } message: {
                        Text("frees \(ModelDownloader.format(downloader.totalBytes)). chats are kept.")
                    }
                } header: {
                    Text("model")
                }

                Section {
                    NavigationLink(destination: CreditsView()) {
                        Text("credits")
                    }
                }

                Section {} footer: {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Image(systemName: appManager.getMoonPhaseIcon())
                                .foregroundStyle(.quaternary)
                            Text("v\(Bundle.main.releaseVersionNumber ?? "0").\(Bundle.main.buildVersionNumber ?? "0")")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                            Image(.madeByMainframe)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundStyle(.tertiary)
                            #if os(macOS)
                                .frame(height: 16)
                                .padding(.top, 11)
                            #else
                                .frame(height: 18)
                                .padding(.top, 16)
                            #endif
                        }
                        Spacer()
                    }
                    .padding(.vertical)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS) || os(visionOS)
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                        }
                    }
                    #elseif os(macOS)
                    ToolbarItem(placement: .destructiveAction) {
                        Button(action: { dismiss() }) {
                            Text("close")
                        }
                    }
                    #endif
                }
        }
        #if !os(visionOS)
        .tint(appManager.appTintColor.getColor())
        #endif
        .environment(\.dynamicTypeSize, appManager.appFontSize.getFontSize())
    }
}

extension Bundle {
    var releaseVersionNumber: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var buildVersionNumber: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}

#Preview {
    SettingsView(currentThread: .constant(nil))
        .environmentObject(AppManager())
        .environment(LLMEvaluator())
        .environment(ModelDownloader.shared)
}
