rawtohdri
=========

rawtohdri batch-processes bracketed camera RAW files into exr format HDR
images. It works with any raw file format dcraw supports. The only required
argument is INPUT_RAW_DIR, in which case the default behavior is to dump the
resulting HDRIs in the INPUT_RAW_DIR with the file name hdrout_%%04d.exr. The
output images may alternately be nested in a dir named exr inside the input
dir using the -n flag.  The size of the bracket steps may be set with the -e
flag ( Default = ev 3 ). rawtohdri assumes bracketed images are ordered
darkest exposure to brightest.

