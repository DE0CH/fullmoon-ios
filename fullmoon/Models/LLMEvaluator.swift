//
//  LLMEvaluator.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import MLX
import MLXLLM
import MLXLMCommon
import os
import SwiftUI

private let log = Logger(subsystem: "dev.de0ch.fullmoon", category: "llm")

@Observable
@MainActor
class LLMEvaluator {
    var running = false
    var cancelled = false
    var output = ""
    var modelInfo = ""
    var stat = ""
    var thinkingTime: TimeInterval?
    var collapsed: Bool = false
    var isThinking: Bool = false
    /// true while the weights are being read into memory (a few seconds after launch)
    var loading = false

    var elapsedTime: TimeInterval? {
        if let startTime {
            return Date().timeIntervalSince(startTime)
        }

        return nil
    }

    private var startTime: Date?

    /// parameters controlling the output (Gemma's recommended sampling)
    let generateParameters = GenerateParameters(temperature: 1.0, topP: 0.95, topK: 64)
    let maxTokens = 4096

    enum LoadState {
        case idle
        case loaded(ModelContainer)
    }

    var loadState = LoadState.idle

    /// load and return the model from the downloaded files -- can be called multiple times, subsequent calls will
    /// just return the loaded model
    func load() async throws -> ModelContainer {
        switch loadState {
        case .idle:
            loading = true
            defer { loading = false }
            // limit the buffer cache: the weights already take most of what iOS gives the app
            Memory.cacheLimit = 20 * 1024 * 1024

            let started = Date()
            let modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: ModelDownloader.modelDirectory, using: TransformersTokenizerLoader())
            modelInfo = "Loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s.  Weights: \(Memory.activeMemory / 1024 / 1024)M"
            log.notice("\(self.modelInfo)")
            loadState = .loaded(modelContainer)
            return modelContainer

        case let .loaded(modelContainer):
            return modelContainer
        }
    }

    func stop() {
        isThinking = false
        cancelled = true
    }

    func generate(thread: Thread, systemPrompt: String) async -> String {
        guard !running else { return "" }

        running = true
        cancelled = false
        output = ""
        startTime = Date()

        do {
            #if targetEnvironment(simulator)
            // MLX needs a real GPU; the simulator (the CI phone replica) streams a stand-in answer instead
            try await standIn(thread: thread)
            #else
            let modelContainer = try await load()
            let input = try await modelContainer.prepare(input: UserInput(chat: chat(thread: thread, systemPrompt: systemPrompt)))
            var tokenCount = 0
            for await generation in try await modelContainer.generate(input: input, parameters: generateParameters) {
                switch generation {
                case .chunk(let text):
                    output += text
                    tokenCount += 1
                case .info(let info):
                    stat = " Tokens/second: \(String(format: "%.3f", info.tokensPerSecond))"
                    log.notice("\(info.summary())")
                default:
                    break
                }
                // leaving the loop ends the stream, which stops generation
                if cancelled || tokenCount >= maxTokens {
                    break
                }
            }
            #endif
        } catch {
            output = "Failed: \(error)"
            log.error("generation failed: \(error)")
        }

        running = false
        return output
    }

    private func chat(thread: Thread, systemPrompt: String) -> [Chat.Message] {
        var messages: [Chat.Message] = []
        if !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
        }
        for message in thread.sortedMessages {
            switch message.role {
            case .user: messages.append(.user(message.content))
            case .assistant: messages.append(.assistant(message.content))
            case .system: messages.append(.system(message.content))
            }
        }
        return messages
    }

    #if targetEnvironment(simulator)
    private func standIn(thread: Thread) async throws {
        let question = thread.sortedMessages.last?.content ?? ""
        let words = "This is the simulator stand-in for Gemma 4 E2B. You asked: \(question)".split(separator: " ")
        for word in words {
            if cancelled { break }
            output += (output.isEmpty ? "" : " ") + word
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    #endif
}
