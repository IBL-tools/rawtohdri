#rawtohdri

##With the closing of Google Code, this is the new official home of rawtohdri. 

###Description:

rawtohdri is a Python based program which takes a bracketed set of camera raw files, converts them directly to linear light images and stacks them into an HDR image saved in OpenEXR HALF format. It has minimal dependencies, requiring only dcraw, NumPy? and the LibOpenEXR bindings for python. rawtohdri's main features are process-parallel conversion of raw files and the ability to convert HDRIs one scanline at a time, the latter making it very memory efficient in spite of working at full floating point precision during stacking. It also copies the important bits of EXIF metadata like exposure and ISO from the raw to the output EXR.

rawtohdri can process any raw format supported by dcraw.

While perfectly usable in its current form (It meets my personal needs just fine), the pre-1.0 version is really just a proof-of-concept/prototype. I did it as an exercise to learn Python. There's plenty of room for improvement in speed. The next phase of development will focus on speed improvements.

The program includes a Python class for reading 16 bit PPM files, which might be interesting for academic purposes.

###Getting Started:

Here is the help text from rawtohdri: [Help](https://github.com/IBL-tools/raw-to-hdri/wiki/cliHelp)

rawtohdri is a plain text Python script. Instillation is pretty straight forward on Linux and beyond Python 2.7 it has only three dependencies...

* [dcraw](http://www.cybercom.net/~dcoffin/dcraw/)
* [NumPy 1.6](http://numpy.scipy.org/)
* [OpenEXR bindings for Python](http://excamera.com/sphinx/articles-openexr.html)

You will need to install these dependencies on your own. (I will write a guide when I have the time)

###Help Wanted:

We are looking for testers and collaborators. Do you have a camera that shoots raw? I'm interested to hear how rawtohdri works for you. Perhaps you can provide some bracketed raw files myself and others can use for testing.

Any code review I can get is welcome. Patches and submissions are welcome also. If you are a Python module hacker interested in helping out, let's talk!

If you are interested in packaging rawtohdri for your favorite distro, please contact me.

###Details:

Here is a description of the algorithm used by rawtohdri: [Algorithm](https://github.com/IBL-tools/rawtohdri/wiki/rawtohdri-stacking-algorithm)

At present, much of the heavy lifting (the actual HDRI stacking) in rawtohdri is done in pure Python and Numpy. As a result, conversion is definitely CPU bound by the Python interpreter. The algorithms in use are so simple (trivial really), I would expect a program like this to be I/O bound rather than CPU bound. Moving forward I plan to focus on improving the speed of rawtohdri. I already see some low hanging fruit in terms of possible speed improvements. Better implemented multiprocessing alone would lead to perhaps a 4x speed improvement on 4 core systems. Basic static typing optimizations in Cython would probably also lead to speed improvements without a lot of hassle.
