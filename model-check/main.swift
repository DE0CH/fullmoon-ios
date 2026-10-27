//
//  main.swift
//  model-check
//
//  Runs the app's model on a Mac (CI's macOS runner): loads the downloaded files with the app's tokenizer bridge
//  and the same MLX calls as LLMEvaluator, answers two chat turns and prints speed and memory. The simulator UI test
//  uses a stand-in for the model, so this is where CI hears Gemma.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
Memory.cacheLimit = 20 * 1024 * 1024

let started = Date()
let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
print("LOADED in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, weights \(Memory.activeMemory / 1024 / 1024) MB")

func answer(_ chat: [Chat.Message]) async throws -> String {
    let input = try await container.prepare(input: UserInput(chat: chat))
    var text = ""
    for await generation in try await container.generate(
        input: input, parameters: GenerateParameters(maxTokens: 200, temperature: 0))
    {
        switch generation {
        case .chunk(let chunk): text += chunk
        case .info(let info): print("INFO \(info.summary())")
        default: break
        }
    }
    return text
}

var chat: [Chat.Message] = [.system("you are a helpful assistant"), .user("My name is Deyao. What is the capital of France? Answer in one word.")]
let first = try await answer(chat)
print("ANSWER 1: \(first)")
chat += [.assistant(first), .user("What is my name?")]
let second = try await answer(chat)
print("ANSWER 2: \(second)")
print("PEAK \(Memory.peakMemory / 1024 / 1024) MB")

guard first.contains("Paris"), second.contains("Deyao") else {
    print("MODEL CHECK FAILED")
    exit(1)
}
print("MODEL CHECK OK")
