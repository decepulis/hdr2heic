# hdr2heic

Turn HDR photo exports (like Lightroom's 32-bit TIFFs) into **HDR HEIC files that keep their HDR in Apple Photos and iCloud Photos**.

Each output is a standard HEIC: an SDR base image plus an [ISO 21496-1](https://www.iso.org/standard/86775.html) gain map. HDR screens show the full highlights. Everything else shows a properly tone-mapped SDR image, not a clipped one.

It's one Swift file that uses only Apple's frameworks (Core Image and ImageIO), with no dependencies.

## Why this exists

The workflow this was built for: HDR edits in Lightroom (the cloud-based Lightroom, not Classic), with the library kept in iCloud Photos. Getting an HDR photo from Lightroom into iCloud in good shape is harder than it should be:

- **Lightroom can't export HEIC.** HEIC is the format Apple's own cameras use for HDR photos, and the one Photos handles best.
- **Lightroom's HDR AVIF and JPEG XL exports are unreliable in Apple Photos.** They can look fine on the Mac they were imported on, but once they sync through iCloud you can get clipped highlights on non-HDR screens, banding, or color shifts. Apple Photos handles gain-map HEIC and JPEG reliably. Other formats are hit and miss.
- **Converting the AVIF to HEIC compresses the photo twice.** The goal is one lossy step, straight from a lossless master.

So: export a lossless 32-bit TIFF from Lightroom, and let this tool do the single lossy encode the same way Apple does it.

## Requirements

- macOS on Apple silicon, with the Xcode command line tools (`xcode-select --install`) for `swiftc`.
- A recent macOS. The tool uses Core Image's HDR APIs (`CIToneMapHeadroom`, `expandToHDR`, HEIF writing with an `hdrImage`), which first shipped in macOS 15. It has only been tested on macOS 27.

## Install

```sh
git clone https://github.com/decepulis/hdr2heic.git
cd hdr2heic
make install        # builds and copies to ~/.local/bin/hdr2heic
```

Make sure `~/.local/bin` is on your `PATH`, or use `make install PREFIX=/usr/local`.

## Usage

```sh
hdr2heic <file-or-folder>... [--quality 0.6] [--gainmap-scale 0.5] [--jobs 6] [--force]
```

```sh
hdr2heic ~/Pictures/export/            # converts every .tif/.tiff in the folder
hdr2heic DSCF8634.tif                  # or individual files (any format ImageIO reads)
hdr2heic export/ --quality 0.75        # higher quality, bigger files
```

- Writes `name.heic` next to each input.
- Skips inputs that already have a `.heic` next to them, so you can run it again on the same folder after adding more exports. `--force` re-converts everything.
- Converts 6 photos at a time by default (`--jobs`). Each conversion runs in its own process, because Core Image's gain-map step only runs one at a time per process.
- Inputs with nothing brighter than SDR white (say, a photo edited with HDR mode off) become a plain SDR HEIC with no gain map.
- Inputs that already have a gain map (an ISO or Apple gain map in an AVIF, HEIC, or JPEG) are read through it, so they convert as HDR too.
- Keeps capture date, camera, lens, and other EXIF/XMP metadata.

| Option | Default | What it does |
|---|---|---|
| `--quality` | `0.6` | HEVC quality on Apple's 0–1 scale (`kCGImageDestinationLossyCompressionQuality`). This isn't comparable to Lightroom's "quality %". |
| `--gainmap-scale` | `0.5` | Gain map resolution relative to the photo. 0.5 is what iPhones use. |
| `--jobs` | `6` | How many photos to convert in parallel. |
| `--force` | off | Overwrite existing `.heic` files. |

## Lightroom export settings

| Setting | Use | Why |
|---|---|---|
| Image Type | **TIF** | |
| Bit Depth | **32 bits** | Floating point: highlights above SDR white are stored as plain numbers, with no PQ curve and no rounding to 10-bit steps. This is the cleanest possible input. (HDR Output is greyed out because 32-bit TIFFs are always HDR.) |
| Compression | **ZIP** | Lossless. Uncompressed files are about 300 MB each at 26 MP. These are intermediates, so delete them afterward if you like. |
| Color Space | **HDR Rec. 2020** | The widest gamut, so the intermediate loses nothing. The tool converts to Display P3 for the HEIC. |
| Dimensions | your final size | The tool doesn't resize. |
| Output Sharpening | your usual | It gets baked into the final HEIC. |
| Metadata | **All Metadata** | It's copied into the HEIC. |

## How it works

For each photo:

1. **Decode** the TIFF as linear, extended-range HDR (`expandToHDR`).
2. **Tone-map an SDR base** with `CIToneMapHeadroom` (target headroom 1.0). This is what non-HDR screens see.
3. **Compute the gain map** by having Core Image write a temporary HEIC from a downscaled copy of the HDR and SDR images (`writeHEIFRepresentation` with `.hdrImage`), then pull the ISO gain map out of that file. Computing it at the final small size is much faster than computing it full size and shrinking it. If Core Image doesn't produce a gain map, the photo has no HDR content and gets saved as SDR.
4. **Encode the SDR base exactly once**, at your chosen quality, in Display P3, with the original metadata, and attach the gain map with `CGImageDestinationAddAuxiliaryDataInfo`.

Core Image's built-in one-step HEIF writer could do steps 2–4 by itself, but it can't downscale the gain map or carry over the source metadata, so the tool splits the work up.

## How the defaults were chosen

Each output was compared against the source TIFF on a 26 MP Fujifilm frame. The error is RMS in stops (log2 of luminance), so lower means closer to the TIFF:

| File | Size | Error vs TIFF |
|---|---|---|
| HEIC, quality 0.9, full-res gain map | 9.6 MB | 0.080 stops |
| HEIC, quality 0.75, half-res gain map | 4.6 MB | 0.117 |
| HEIC, quality 0.75, quarter-res gain map | 4.1 MB | 0.118 |
| **HEIC, quality 0.6, half-res gain map (default)** | **3.6 MB** | 0.137 |
| HEIC, quality 0.6, quarter-res gain map | 3.0 MB | 0.138 |
| Lightroom JPEG XL | 6.0 MB | 0.103 |
| Lightroom AVIF | 1.7 MB | 0.143 |

Takeaways:

- **Quality is the setting that matters.** At 0.6 the HEIC is about as accurate as Lightroom's AVIF, at roughly twice the size. You can't fully close that gap: a gain-map HEIC stores two images, and HEVC compresses less efficiently than AV1. The second image is what buys you a good SDR fallback.
- **Gain map resolution is nearly free.** Quarter resolution saves about 0.5 MB and barely moves the error. It does soften the brightest single-pixel glints (from about 3.9× to about 3.1× SDR white). Half resolution matches the iPhone, so that's the default.
- **No visible difference** between 0.6 and 0.9 at 100% zoom, or between 0.6 and 0.75 in Photos. For comparison, 0.6 works out to about 1.1 bits per pixel, which is still more than an iPhone HEIC (about 0.75 bpp).

Spot checks: the brightest highlights in the HDR view come back within about 3–5% of the source (for example 2.92× SDR white in the TIFF and 2.98× in the HEIC), average brightness matches, the SDR view doesn't clip, and the metadata survives. After syncing through iCloud Photos, the files still display as HDR.

## Caveats

- Only tested with Fujifilm X-T50 files out of Lightroom (cloud-based) on macOS 27. Other inputs should work if ImageIO can read them, but haven't been tested.
- Folder mode only picks up `.tif` / `.tiff`. Pass other formats as individual files.
- The output uses the ISO gain map, not Apple's older proprietary `HDRGainMap` and MakerApple tags. Current Apple Photos and iCloud handle the ISO format. If some app only understands Apple's older format, [vastunghia/HDR2gainmap](https://github.com/vastunghia/HDR2gainmap) writes that one.

## License

MIT
