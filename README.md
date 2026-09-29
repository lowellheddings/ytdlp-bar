# YTDLP Bar

A macOS menu bar queue for [yt-dlp](https://github.com/yt-dlp/yt-dlp). Paste a link, pick video or audio, and it downloads one at a time.

The idea comes from Alex Zeitler's [omarchy-yt-dlp-plugin](https://github.com/AlexZeitler/omarchy-yt-dlp-plugin).

Open `dist/YTDLP Bar.app`; to start it at login, add that app in System Settings → General → Login Items & Extensions.

`scripts/build-app.sh` rebuilds the app. It looks for yt-dlp and ffmpeg in `/opt/homebrew/bin`, then on `PATH`, and can install both with Homebrew.
