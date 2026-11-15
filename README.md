# Codex Usage

A native macOS menu bar app for keeping an eye on Codex usage. The upper arc shows the five-hour allowance remaining; the lower arc shows the weekly allowance. Click the icon to see percentages and reset times.

## Getting started

You need macOS, Apple's Command Line Tools, and the [Codex CLI](https://developers.openai.com/codex/cli), signed in to your account. In Terminal, open this folder and run:

```sh
./build.sh
open 'Codex Usage.app'
```

The app stays in your menu bar. Click its icon to refresh or quit. It refreshes at startup, when opened, and every five minutes. Launch at login is off by default.

The app searches common CLI installation locations and the PATH inherited when it launches. GUI apps do not always inherit your shell's PATH. If Codex cannot be found, put a `codex` executable in `~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin`.

## How it works

The app asks the installed Codex app server for your account's rate limits using your existing Codex sign-in. It does not store your credentials. If a refresh fails, it shows the last successful reading and update time; unavailable windows are marked accordingly. The Codex app-server interface is experimental and may change.

When either limit is exhausted, the popover adds an out-of-usage message and the effective reset time when available. Its usage-settings shortcut opens ChatGPT in your browser. The icon continues to show the remaining amounts visually; workspace credits are not included in the rate-limit data this app reads.

This independent project is not an official OpenAI application. The build is signed locally; distributing prebuilt binaries may require additional Apple signing and notarization.

## License

MIT. See [LICENSE](LICENSE).
