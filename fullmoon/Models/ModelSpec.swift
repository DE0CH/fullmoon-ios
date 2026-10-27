//
//  ModelSpec.swift
//  fullmoon
//

import Foundation

/// One file of the model repo on Hugging Face, fetched at a pinned revision.
struct ModelFile: Hashable, Sendable {
    let name: String
    let size: Int64
    /// SHA-256 of the file (Hugging Face's LFS oid); nil for small git files.
    let sha256: String?
}

/// The one model the app ships with: Gemma 4 E4B, 4-bit MLX. The app downloads it after install.
struct ModelSpec: Sendable {
    let displayName: String
    let repo: String
    let revision: String
    let files: [ModelFile]
    /// The download is split into byte ranges of this size; each range is its own background task, so pausing or a
    /// lost connection costs at most the ranges in flight.
    let chunkSize: Int64

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.name)")!
    }

    static let gemma = ModelSpec(
        displayName: "Gemma 4 E4B",
        repo: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
        files: [
            ModelFile(name: "config.json", size: 6628, sha256: nil),
            ModelFile(name: "generation_config.json", size: 208, sha256: nil),
            ModelFile(name: "chat_template.jinja", size: 17336, sha256: nil),
            ModelFile(name: "tokenizer_config.json", size: 2740, sha256: nil),
            ModelFile(name: "tokenizer.json", size: 32_169_626,
                      sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            ModelFile(name: "model.safetensors", size: 5_146_800_534,
                      sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
        ],
        chunkSize: 32 << 20
    )

    /// The UI tests download real files through the same chunked path, small enough for CI (MLX doesn't run in the
    /// simulator, so a stand-in answers there).
    static let uiTest = ModelSpec(
        displayName: "Gemma 4 E4B",
        repo: gemma.repo,
        revision: gemma.revision,
        files: gemma.files.filter { $0.name != "model.safetensors" },
        chunkSize: 256 << 10
    )

    static let isUITest = ProcessInfo.processInfo.arguments.contains("-uitest")
    static let current: ModelSpec = isUITest ? .uiTest : .gemma
}
