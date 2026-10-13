This isolated test project runs native installation and offline configuration checks for official OpenAI Codex CLI 0.162.1 on GitHub-hosted Linux, Windows, and macOS runners, plus a Windows-hosted WSL2 distro.

The workflows on branch `codex-pilot-native-check-20261013` install the pinned CLI into isolated directories, test the official standalone installers and npm installations, and publish test reports as workflow artifacts. The sample configuration, named overlay, persisted settings, malformed TOML, unknown fields, and recovery are checked without model requests or account sign-in.

The installers were downloaded from `https://chatgpt.com/codex/install.sh` and `https://chatgpt.com/codex/install.ps1` on October 13, 2026. Native CI artifacts are the authoritative results; a job that cannot start its actual operating system is not a passing installation test.
