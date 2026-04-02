# MacOSImage2WebPFFmpegBuildScript

This repository publishes the corresponding source materials for the FFmpeg-based runtime bundled with the macOS application `ImageToWebP`.

## Scope

This repository covers the bundled FFmpeg runtime only.

It does not contain the full source code of the `ImageToWebP` application itself.

## Release Correspondence

Application: `ImageToWebP`  
Application version: `1.0.0`  
Build: `1`  
FFmpeg version: `8.1`  
Last updated: `2026-04-03`

For the release above, the bundled FFmpeg runtime is expected to correspond to the source inputs and build scripts in this repository.

## Contents

This repository should contain the materials used to build the bundled FFmpeg runtime for the release above, including:

- `ffmpeg-8.1/`
- `Scripts/build_appstore_ffmpeg.sh`
- `Scripts/embed_ffmpeg.sh`

Release-specific build outputs should also be archived for the same release, including:

- `ffmpeg-buildconf.txt`
- `ffmpeg-build-script.sh`

## Release Packaging Rule

Release packaging for `ImageToWebP` is limited to project-managed FFmpeg binaries only:

- `FFMPEG_SOURCE` when explicitly set for the build
- `ffmpeg-appstore/ffmpeg`
- `ffmpeg-8.1/ffmpeg`

Host-installed FFmpeg binaries from locations such as `/opt/homebrew` or `/usr/local` are not intended to be used for release packaging.

## Build Prerequisites

The build script expects the following dependencies to be available via `pkg-config` on the build machine, with versions matching the shipped release materials:

- `libwebp`
- `libsharpyuv`
- `dav1d`
- `SvtAv1Enc`

If a release is rebuilt, the dependency versions and generated runtime should match the released build configuration recorded in `ffmpeg-buildconf.txt`.

## Build

1. Obtain the FFmpeg 8.1 source code from [https://ffmpeg.org](https://ffmpeg.org)
2. Extract it as `ffmpeg-8.1/`
3. Run:

```sh
./Scripts/build_appstore_ffmpeg.sh
```
