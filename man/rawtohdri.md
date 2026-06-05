# rawtohdri(1) - manual page

## NAME

**rawtohdri** — high-performance parallel camera raw stacker to OpenEXR

## SYNOPSIS

`rawtohdri [<input_dir>] [options]`

## DESCRIPTION

**rawtohdri** takes a bracketed set of camera RAW files, converts them directly to linear light images, and stacks them into high dynamic range (HDR) images saved in OpenEXR format (HALF or FLOAT) with ZIP/ZIPS compression.

The application is designed from the ground up for extreme performance and memory efficiency. By utilizing Common Lisp (via SBCL) coupled with native AVX2 SIMD instructions, it achieves speed levels comparable to or exceeding hand-tuned C/C++ implementations, processing full-resolution RAW exposure brackets into a finished HDR image in under 1.5 seconds.

Additionally, the tool copies important EXIF metadata—such as ISO, shutter speed, aperture, focal length, and capture date—from the designated "center" RAW file and embeds it directly into the output OpenEXR header.

## INTERACTIVE TUI MODE

If started without arguments (or with the `--tui` option), the application runs in an interactive terminal user interface. The TUI consists of three panels:

### Settings Panel

Allows configuring stacking parameters interactively:
* Pressing `n` toggles Nest Mode.
* Pressing `f` toggles Float Mode (HALF vs. FLOAT).
* Pressing `z` toggles Compression Mode (ZIP vs. ZIPS).
* Pressing `c` increments the Chunk Size, while `C` (Shift-C) decrements it.
* Pressing `e` increments the EV Spacing, while `E` (Shift-E) decrements it.
* Pressing `t` increments the Max Decode Threads, while `T` (Shift-T) decrements it.

### File Browser Panel

Allows navigating directories to locate bracketed RAW exposure folders:
* Navigate selections using the **Up/Down** arrow keys or the mouse.
* Press **Enter** or double-click a folder to enter it.
* Press **Backspace** to return to the parent directory.

### Queue Panel

Manages directory stacking runs:
* Press **Space** to queue the highlighted folder.
* Press `a` (or click **Add Selected Dir** / **Add Current Dir** on the actions bar) to queue directories dynamically.
* Press `x` (or click **Clear Queue** on the actions bar) to reset the queue.
* Press `s` (or click **Start Stacking** on the actions bar) to begin multi-threaded batch stacking. A real-time overall progress bar, per-directory progress bar, and speed logs will be displayed.

## OPTIONS

### Main Options

* `-x`, `--chunk <int>`  
  Specifies the number of bracketed exposures per stacked HDR image. The input files are sorted alphabetically and grouped into chunks of this size. If the last chunk has fewer files than specified, it is skipped. *(Default: 3)*
* `-e`, `--ev <float>`  
  The exposure value (EV) spacing step between consecutive shots in the bracket (e.g., 2.0 or 3.0). *(Default: 3.0)*
* `-c`, `--center <int>`  
  The 1-based index of the "center" exposure within the bracket. The metadata (shutter, aperture, ISO, etc.) from this image is copied to the final OpenEXR output. *(Default: 2)*
* `-n`, `--nest`  
  If specified, output files are written to a subdirectory named `exr/` created directly under the input directory.
* `-o`, `--output-basename <str>`  
  The file prefix for generated OpenEXR output images (e.g., "capture_"). *(Default: "hdrout_")*
* `-d`, `--output-dir <path>`  
  Specifies an alternate directory where the generated OpenEXR images will be written. If it doesn't exist, it is created. *(Default: same as input directory)*
* `-l`, `--lo <float>`  
  Luma threshold representing the lower boundary of the exposure blending range. Pixels below this threshold in a brighter exposure are blended. *(Default: 0.7)*
* `-H`, `--hi <float>`  
  Luma threshold representing the upper boundary of the exposure blending range. Pixels above this threshold in a darker exposure are blended. *(Default: 0.8)*
* `-v`, `--verbose`  
  Enables verbose output, printing details about demosaicing speed, stacking time, and EXR compression timing.
* `--rotate <int>`  
  Specifies rotation angle in degrees: 0, 90, 180, or 270. *(Default: 0, native sensor orientation)*
* `--float`  
  Enables saving the OpenEXR files with 32-bit single-precision FLOAT data instead of the default 16-bit HALF precision.
* `--zips`  
  Instructs the OpenEXR writer to use ZIPS (single-scanline block) compression instead of the default ZIP (16-scanline block) compression.
* `-t`, `--max-decode-threads <int>`  
  Specifies the maximum number of parallel threads used to decode and demosaic RAW images. Set to `0` for unlimited (parallelizes decoding across all cores). Set to `1` to run sequentially, which drastically reduces memory consumption under RAM pressure. *(Default: 0)*
* `--tui`  
  Launches the interactive Terminal User Interface (TUI). This is also the default behavior if no command line arguments are provided.
* `-h`, `--help`  
  Displays the help text and exits.

## UNIQUE FEATURES & OPTIMIZATIONS

### 16-bit Integer RAW Ingest

Unlike traditional HDR stackers that upcast RAW data to 32-bit floating-point buffers immediately on ingest, **rawtohdri** keeps the demosaiced data as compact 16-bit unsigned integers (`(unsigned-byte 16)`). This reduces the memory footprint of loaded source images by exactly 50%.

### Zero-Copy Float Accumulator

To prevent heap-allocation thrashing, the stacking pipeline uses exactly one float buffer for the final output composition. The 16-bit integer pixel components are converted to floats on-the-fly inside the stacking loop.

### AVX2 SIMD Vectorization

The critical stacking loop is hand-vectorized using AVX2 SIMD instructions (via the Common Lisp `sb-simd` package). This allows the processor to load, normalize, clamp, and blend 8 pixel components in parallel per instruction cycle. AVX2 stacking achieves a 2x speedup (down to ~0.06 seconds per full-resolution chunk) compared to standard scalar or compiler-auto-vectorized loops.

### Dynamic CPU Dispatch

To maintain maximum compatibility without sacrificing performance, the program checks CPU capabilities at startup using `CPUID` instruction queries. If AVX2 is supported, it executes the vectorized path; on older CPUs, it automatically falls back to a clean scalar loop instead of crashing.

### Multi-Threaded Custom OpenEXR Writer

To bypass the overhead of heavy C++ OpenEXR libraries, **rawtohdri** features a custom, lightweight, multi-threaded OpenEXR writer written in pure Common Lisp. It parallelizes Zlib compression across up to 8 threads using ZIP block compression (16-scanline blocks).

### Interactive Terminal User Interface (TUI)

For convenient batch stacking and file management, **rawtohdri** includes a rich terminal-based user interface using **cl-tuition**. It features full mouse and keyboard navigation, an interactive file browser, live checkbox toggles for stacking options, a batch processing queue, and real-time per-directory/overall progress meters.


## EXAMPLES

Process all RAW files in `/path/to/shots/` in groups of 3 (using default options) and save EXRs in the same directory:

```bash
rawtohdri /path/to/shots/
```

Process groups of 5 exposures with 2.0 EV spacing, write outputs to a nested `exr/` directory, use 32-bit FLOAT precision, and print detailed execution times:

```bash
rawtohdri /path/to/shots/ -x 5 -e 2.0 -n --float -v
```

Limit RAW decoding to 2 threads to conserve RAM on a resource-constrained system, and save outputs to `/output/hdris/`:

```bash
rawtohdri /path/to/shots/ -t 2 -d /output/hdris/
```

## EXIT STATUS

* **0** — Success. All bracketed sets were grouped and processed successfully.
* **1** — Failure. Caused by invalid command line arguments, missing/invalid input directories, size mismatch within bracketed sets, or internal LibRaw decoding errors.

## AUTHORS

Written and maintained by Aaron Estrada.

## COPYRIGHT

This project is licensed under the MIT License.
