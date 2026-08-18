# Cleanuparr

## Why the blacklist is vendored and edited

`blacklist-configmap.yaml` holds a modified copy of
<https://cleanuparr.pages.dev/static/blacklist>, which Cleanuparr's Blacklist Sync pushes into
qBittorrent's "Excluded file names" setting.

Upstream is written for a video-only library. It excludes `*.flac`, `*.mp3`, `*.m4a`, `*.wav`,
`*.wma`, every scene sidecar (`*.cue`, `*.m3u`, `*.sfv`, `*.nfo`, `*.log`, `*.txt`) and all cover
art (`*.jpg`, `*.jpeg`, `*.png`, `*.pdf`, `*.gif`, `*.bmp`, `*.tif`, `*.tiff`). A music torrent
contains nothing else, so qBittorrent marks every file "Do Not Download", reports the torrent
complete after transferring zero bytes, and Lidarr retries importing a directory that was never
written — one error every 90 seconds, indefinitely. Video is unaffected, since `.mkv`, `.mp4` and
`.avi` are not on the list, which is why only Lidarr broke.

The removed entries are all inert container formats rather than malware vectors, so dropping them
costs none of the protection the list exists to provide.

## Re-syncing with upstream

Manual: re-fetch the URL, re-apply the same removals, and diff. Cleanuparr hashes the content and
only pushes on change.
