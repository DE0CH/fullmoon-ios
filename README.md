# Lantern (a fullmoon fork)

Lantern is a fork of [fullmoon](https://github.com/mainframecomputer/fullmoon-ios) that does one thing: private, offline chat with
**Gemma 4 E4B** ([mlx-community/gemma-4-e4b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit), 5.1 GB)
on an iPhone, run on the phone's GPU through [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm).

- **The model downloads after install** (it is over Apple's 4 GB app limit): a background `URLSession` fetches it in
  32 MB ranges written straight into place, so the download can be paused, keeps going with the app closed or the
  phone locked, survives the app being killed, and is checked against Hugging Face's SHA-256 at the end. A
  notification says when it's ready.
- **Chats stay on the phone** (SwiftData). Settings → delete model frees the space.
- iOS doesn't let a background app use the GPU, so an answer in progress stops when the app leaves the screen.

## build

`project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec: `xcodegen generate`, then open
`fullmoon.xcodeproj`. CI (`.github/workflows/ios.yml`) runs every flow on an iPhone 17 simulator and ships each push to
`main` to TestFlight; `model-check.yml` runs the real model on a Mac runner.

## credits
fullmoon is by [Mainframe](https://mainfra.me) (MIT). It is made possible by [MLX Swift](https://github.com/ml-explore/mlx-swift) from Apple.
