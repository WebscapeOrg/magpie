# Magpie Mail native icon provenance

`omamail.icns` and `../windows/omamail.ico` are generated application resources for the standalone native bundles. Both come directly from Apple's ✉️ artwork in `../../../ui/assets/magpie-mail.png`, resized without redrawing or adding a container. The Linux and Windows window icon uses the same PNG directly. The omamail filenames remain stable for desktop and notification compatibility.

- Apple envelope PNG SHA-256: `12fac6fadc0bfd7791a6975b79915349095152c5e9b57e81d28972bca9c5a7aa`
- Generated ICNS size: `306442` bytes
- Generated ICNS SHA-256: `c121abd180f0d02f224da9073444a4de7f4574cef33877a5ab761703798f4811`
- Generated ICO size: `370070` bytes
- Generated ICO SHA-256: `f5bbbe791467ccd7c3834b6ad8f3b683b5364e2a72b7dc61f41ea3d6a8240440`
- ImageMagick: `7.1.2-34 Q16-HDRI x86_64`

Run `../icons/generate-native-icons.sh` to reproduce both files. It renders the source at 16, 32, 64, 128, 256, 512 and 1024 pixels, writes those PNG representations into the ICNS container, and renders ICO at 16, 32, 48, 64, 128 and 256 pixels. The container writer uses only Python's standard library, so generation works on Linux and macOS without `iconutil`. ICNS slots map `ic11` to 32px, `ic12` to 64px, `ic13` to 256px and `ic14` to 512px for the Retina representations, with `ic04`/`ic05`/`ic07`/`ic08`/`ic09`/`ic10` covering the base sizes through 1024px.
