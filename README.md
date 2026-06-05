# rawtohdri

## After an over 15 year hiatus, rawtohdri has been revived, now as a multi-threded and compiled progam built in SBCL Common Lisp! 🚀

### Description

rawtohdri takes a bracketed set of camera raw files, converts them directly to linear light images and stacks them into an HDR image saved in OpenEXR HALF format. It has minimal external dependencies requiring only LibRaw, which most distros include in their package systems. (All Lisp dependencies are available as Quicklisp libraries, so that part is easy). rawtohdri's main clain to fame are it's speed and it's efficiency. It features thread-parallel conversion of raw files and the ability to convert HDRIs one scanline at a time, the latter making it very memory efficient in spite of working at full floating point precision during stacking. It also copies the important bits of EXIF metadata like exposure and ISO from the raw to the output EXR. It includes a simple multi-threaded pure Lisp implementation of the EXR format. Why? Bacause I only need part of the standard and the full library is huge, so I wrote my own. It only suports ZIP/ZIPS codec, RGBA, HALF and FLOAT only and does support the data window and display window. But in this particular case the data window is never used. The EXR saver does what it needs to do and it's BLAZING FAST with essentially no bloat.

rawtohdri can process any RAW format supported by LibRaw and it will write to any output format you want... as long as it's OpenEXR. 🤣

This version of rawtohdri is realeased under the **MIT** license. The old python version is realeased under the **GPL** license and is still included in the repo for historical purposes. (it includes a pure Python class for reading 16 bit PPM files, which might be interesting for academic purposes.)

### Compatibility

rawtohdri should run great on any platform where SBCL and LibRaw can be installed. However, it's only been tested on **Linux** with SBCL 2.6.4-1 and LibRaw 0.25.0

### Dependencies

rawtohdri depends on the following external libraries:

* **SBCL Common Lisp:** [https://www.sbcl.org](https://www.sbcl.org) (Probably available via in your distros package manager)
* **Qlot:** [https://github.com/fukamachi/qlot](https://github.com/fukamachi/qlot) (available as a quicklisp)
* **GNU make:** Almost certainly available via your distros package manager.
* **libraw.so.25.0.0:** [https://www.libraw.org](https://www.libraw.org) (Probably available via in your distros manager)

### Build & Install

The easiest way to build rawtohdri is to use Qlot to manage quicklisp to get dependencies:

```bash
qlot install
```

This will install the required Lisp dependencies in the project `.qlot/` directory.  

You can then build the binary with `make`:

```bash
make all
```

It's that easy.

### Getting Started

Here is the help text from rawtohdri: [Help](https://github.com/IBL-tools/raw-to-hdri/wiki/cliHelp)

### Details

Common Lisp you say? Isn't that a dead language? Well no, it's not. You really aught to give it a try. All the convieniences of Python/Ruby/Perl but all the speed and memory safety of Go. C++ level speed is absolutely achievable if you do your part. It can even do SIMD. It really is an amazing language (the SBCL implementation in particular) The package system is extremely mature and easy to use. (similar to Go and Cargo in Rust). On top of that, you have a world class, completely unparalleled REPL. (Don't even get me started on the macros...🤯) I wish I had discovered this language years sooner. This port of rawtohdri to a compiled language would have been done years ago if I had.

Here is a description of the algorithm used by rawtohdri: [Algorithm](https://github.com/IBL-tools/raw-to-hdri/wiki/rawtohdri-stacking-algorithm)

The heavy lifting (the actual HDRI stacking) in rawtohdri continues to be done in the host language which is no longer a bottleneck as it was in the old Python + Numpy implementation. As a result, the stacking is now so fast as to be memory bound rather than CPU bound. The algorithms in use for compositing are so simple (trivial really), they were IO bound, even in the old Python version. It's probably still the case but... less so. The custom OpenEXR writer in rawtohdri is multi-threaded and extremely fast. The RAW file reading and demosaicing is done by LibRaw but rawtohdri can read them buffer parallelly, one thread per RAW file, which is a big win the more RAW images you have to process for a single HDRI. Depending on your hardware and how many RAW files you have in each bracketed set, you can expect render times from 1 second to 5-6 seconds to process full resolution HDRI. It's a MASSIVE speed improvement over the Python version. But do keep in mind, to achieve this speed, the new version of rawtohdri loads every image it's going to process into memory. To keep the RAM footprint as low as possible, we load them into memory as 16-bit integer RGB data (cutting the memory footprint of all loaded source images in half compared to float buffers) and convert them to float on the fly during stacking. During the stacking step, we allocate exactly one float buffer for the final composition to accumulate the exposure layers, meaning we don't duplicate any floating point buffers. The OpenEXR writer uses up to 8 threads for compression (more is typically not faster unless you have MONSTER caches on your CPU, which you won't at home) and uses ZIP (16-scanline blocks) as the default compression method, which is highly efficient. But do keep in mind, even with these aggressive memory optimizations, RAM usage will be proportional to the resolution and number of images being stacked. Peak RAM may be quite high due to the parallel RAW decoding process, even if the stacking itself is memory efficient. However, you ***can*** control it with the -t/--max-decode-threads argument in the CLI and force less parallelism if you are tight on RAM. To squeeze out even more ridiculous performance, the stacking loop is hand-optimized using AVX2 SIMD instructions (via `sb-simd`) to process 8 components per instruction cycle, cutting stacking time in half (from ~0.11s down to ~0.06s) compared to standard scalar or auto-vectorized loops! The code automatically detects CPU support and will fall back to a pure scalar implementation if you run it on older hardware, but do note that if your host compiler machine does not support AVX2 at all, you'll need to compile a non-AVX2 version to match your CPU capabilities.
