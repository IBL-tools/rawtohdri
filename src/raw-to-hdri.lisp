;;;; raw-to-hdri.lisp - CLI tool for stacking bracketed raw files to HDR OpenEXR
;;;; Part of the rawtohdri package.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ql:quickload '(:cffi :bordeaux-threads :uiop :sb-simd) :silent t))

(defpackage :raw-to-hdri
  (:use :cl)
  (:export #:main
           #:stack-images
           #:ev-to-exposure-factor
           #:luma-clip))

(in-package :raw-to-hdri)

(defparameter *version*
  #.(asdf:component-version (asdf:find-system :rawtohdri)))

;;;; -------------------------------------------------------------------------
;;;; Structs & CLI Argument Parser
;;;; -------------------------------------------------------------------------

(defstruct cli-args
  (input-dir nil)
  (chunk 3)
  (ev 3.0f0)
  (center 2)
  (nest nil)
  (output-basename "hdrout_")
  (output-dir nil)
  (lo 0.7f0)
  (hi 0.8f0)
  (verbose nil)
  (rotate 0)
  (float-mode nil)
  (zip-mode :zip)
  (max-decode-threads 0)
  (tui-mode nil))

(defun print-help ()
  (format t "rawtohdri version ~A
Usage: rawtohdri <input_dir> [options]

Options:
  -x, --chunk <int>           Number of bracketed shots per HDR image (default: 3)
  -e, --ev <float>            EV spacing between shots (default: 3.0)
  -c, --center <int>          Index (1-based) of the center exposure for metadata (default: 2)
  -n, --nest                  Create a sub-directory 'exr/' under input_dir for output
  -o, --output-basename <str> Prefix for output EXR files (default: \"hdrout_\")
  -d, --output-dir <path>     Directory to write output files (default: input_dir)
  -l, --lo <float>            Luma threshold for lower blend boundary (default: 0.7)
  -H, --hi <float>            Luma threshold for upper blend boundary (default: 0.8)
  -v, --verbose               Enable verbose logging
  --rotate <int>              Rotate image: 0, 90, 180, 270 (default: 0, native sensor)
  --float                     Save EXR in FLOAT (32-bit) precision instead of HALF (16-bit)
  --zips                      Save EXR with ZIPS (single-scanline block) instead of ZIP (16-scanline block)
  -t, --max-decode-threads <int> Max parallel threads for decoding RAWs (default: 0, unlimited)
  --tui                       Launch the terminal user interface
  -V, --version               Show version information
  -h, --help                  Show this help text
" *version*))

(defun parse-cli-args (argv)
  (let ((args (make-cli-args)))
    (when (null argv)
      (setf (cli-args-tui-mode args) t))
    (labels ((parse-next (list)
               (when list
                 (let ((opt (first list)))
                   (cond
                     ((or (string= opt "-x") (string= opt "--chunk"))
                      (setf (cli-args-chunk args) (parse-integer (second list)))
                      (parse-next (cddr list)))
                     ((or (string= opt "-t") (string= opt "--max-decode-threads"))
                      (setf (cli-args-max-decode-threads args) (parse-integer (second list)))
                      (parse-next (cddr list)))
                     ((or (string= opt "-e") (string= opt "--ev"))
                      (setf (cli-args-ev args) (coerce (read-from-string (second list)) 'single-float))
                      (parse-next (cddr list)))
                     ((or (string= opt "-c") (string= opt "--center"))
                      (setf (cli-args-center args) (parse-integer (second list)))
                      (parse-next (cddr list)))
                     ((or (string= opt "-n") (string= opt "--nest"))
                      (setf (cli-args-nest args) t)
                      (parse-next (cdr list)))
                     ((or (string= opt "-o") (string= opt "--output-basename"))
                      (setf (cli-args-output-basename args) (second list))
                      (parse-next (cddr list)))
                     ((or (string= opt "-d") (string= opt "--output-dir"))
                      (setf (cli-args-output-dir args) (second list))
                      (parse-next (cddr list)))
                     ((or (string= opt "-l") (string= opt "--lo"))
                      (setf (cli-args-lo args) (coerce (read-from-string (second list)) 'single-float))
                      (parse-next (cddr list)))
                     ((or (string= opt "-H") (string= opt "--hi"))
                      (setf (cli-args-hi args) (coerce (read-from-string (second list)) 'single-float))
                      (parse-next (cddr list)))
                     ((or (string= opt "-v") (string= opt "--verbose"))
                      (setf (cli-args-verbose args) t)
                      (parse-next (cdr list)))
                     ((string= opt "--rotate")
                      (setf (cli-args-rotate args) (parse-integer (second list)))
                      (parse-next (cddr list)))
                     ((string= opt "--float")
                      (setf (cli-args-float-mode args) t)
                      (parse-next (cdr list)))
                     ((string= opt "--zips")
                      (setf (cli-args-zip-mode args) :zips)
                      (parse-next (cdr list)))
                     ((string= opt "--tui")
                      (setf (cli-args-tui-mode args) t)
                      (parse-next (cdr list)))
                     ((or (string= opt "-V") (string= opt "--version"))
                      (format t "rawtohdri version ~A~%" *version*)
                      (sb-ext:exit :code 0))
                     ((or (string= opt "-h") (string= opt "--help"))
                      (print-help)
                      (sb-ext:exit :code 0))
                     ((char= (char opt 0) #\-)
                      (format t "Unknown option: ~A~%" opt)
                      (print-help)
                      (sb-ext:exit :code 1))
                     (t
                      (if (cli-args-input-dir args)
                          (progn
                            (format t "Multiple input directories specified: ~A and ~A~%" (cli-args-input-dir args) opt)
                            (sb-ext:exit :code 1))
                          (setf (cli-args-input-dir args) opt))
                      (parse-next (cdr list))))))))
      (parse-next argv)
      (unless (cli-args-tui-mode args)
        (unless (cli-args-input-dir args)
          (format t "Error: input directory is required.~%")
          (print-help)
          (sb-ext:exit :code 1))
        
        (unless (uiop:directory-exists-p (cli-args-input-dir args))
          (format t "Error: input directory ~S does not exist.~%" (cli-args-input-dir args))
          (sb-ext:exit :code 1))
        
        (setf (cli-args-input-dir args)
              (namestring (uiop:directory-exists-p (cli-args-input-dir args))))
        
        (if (cli-args-nest args)
            (let ((nested-path (merge-pathnames "exr/" (cli-args-input-dir args))))
              (ensure-directories-exist nested-path)
              (setf (cli-args-output-dir args) (namestring nested-path)))
            (if (cli-args-output-dir args)
                (let ((out-path (uiop:directory-exists-p (cli-args-output-dir args))))
                  (if out-path
                      (setf (cli-args-output-dir args) (namestring out-path))
                      (progn
                        (ensure-directories-exist (cli-args-output-dir args))
                        (setf (cli-args-output-dir args) (namestring (uiop:directory-exists-p (cli-args-output-dir args)))))))
                (setf (cli-args-output-dir args) (cli-args-input-dir args)))))
      args)))

;;;; -------------------------------------------------------------------------
;;;; Metadata Format Utilities
;;;; -------------------------------------------------------------------------

(defun format-unix-timestamp (ts)
  "Formats a Unix timestamp into EXIF-like date format (Day Month Date HH:MM:SS Year)."
  (multiple-value-bind (sec min hour date month year day-of-week)
      (decode-universal-time (+ ts 2208988800) 0)
    (let ((days #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))
          (months #(nil "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")))
      (format nil "~A ~A ~D ~2,'0D:~2,'0D:~2,'0D ~D"
              (aref days day-of-week)
              (aref months month)
              date
              hour
              min
              sec
              year))))

(defun format-shutter (shutter)
  "Formats shutter speed float values to fraction format if < 1.0 (e.g. 1/2500 sec)."
  (cond
    ((<= shutter 0.0f0) "0")
    ((< shutter 1.0f0)
     (let ((inv (round (/ 1.0f0 shutter))))
       (format nil "1/~D sec" inv)))
    (t
     (format nil "~F sec" shutter))))

;;;; -------------------------------------------------------------------------
;;;; Decoded Image Representation
;;;; -------------------------------------------------------------------------

(defstruct decoded-image
  (width 0)
  (height 0)
  (data nil) ; (simple-array (unsigned-byte 16) (*))
  (camera "")
  (date "")
  (iso "")
  (shutter "")
  (aperture "")
  (focal ""))

(defun decode-raw-file (filepath rotate)
  "Decodes a single camera RAW file to an in-memory normalized float array."
  (libraw:with-libraw (ptr)
    (libraw:libraw-open-file ptr (namestring filepath))
    
    ;; Configure LibRaw processing parameters
    (libraw:set-params-user-flip ptr (case rotate
                                       (0 0)
                                       (90 6)
                                       (180 3)
                                       (270 5)
                                       (t 0)))
    (libraw:set-params-output-bps ptr 16)      ; 16-bit linear
    (libraw:set-params-use-camera-wb ptr 1)    ; camera WB
    (libraw:set-params-no-auto-bright ptr 1)   ; no auto bright
    (libraw:set-params-half-size ptr 0)        ; full size
    (libraw:set-params-gamm ptr '(1.0d0 1.0d0 1.0d0 1.0d0 1.0d0 1.0d0)) ; linear
    
    (libraw:libraw-unpack ptr)
    (libraw:libraw-dcraw-process ptr)
    
    (libraw:with-processed-image (img-ptr ptr)
      (let* ((width (cffi:mem-ref img-ptr :ushort 6))
             (height (cffi:mem-ref img-ptr :ushort 4))
             (colors (cffi:mem-ref img-ptr :ushort 8))
             (bits (cffi:mem-ref img-ptr :ushort 10))
             (pixel-count (* width height colors))
             (lisp-data (make-array pixel-count :element-type '(unsigned-byte 16)))
             (c-data-ptr (cffi:inc-pointer img-ptr 16)))
        (declare (type fixnum width height colors bits pixel-count)
                 (type (simple-array (unsigned-byte 16) (*)) lisp-data))
        (unless (= bits 16)
          (error "Expected 16-bit processed image, got ~D bits" bits))
        (unless (= colors 3)
          (error "Expected 3-color processed image, got ~D colors" colors))
        
        ;; Copy uint16 data directly to Lisp 16-bit integer array
        (dotimes (i pixel-count)
          (setf (aref lisp-data i) (cffi:mem-aref c-data-ptr :uint16 i)))
        
        ;; Extract metadata
        (let* ((make (libraw:get-idata-make ptr))
               (model (libraw:get-idata-model ptr))
               (camera (format nil "~A ~A" make model))
               (iso-val (libraw:get-other-iso-speed ptr))
               (shutter-val (libraw:get-other-shutter ptr))
               (aperture-val (libraw:get-other-aperture ptr))
               (focal-val (libraw:get-other-focal-len ptr))
               (timestamp (libraw:get-other-timestamp ptr))
               (date-str (format-unix-timestamp timestamp))
               (iso-str (format nil "~D" (round iso-val)))
               (shutter-str (format-shutter shutter-val))
               (aperture-str (format nil "f/~,1F" aperture-val))
               (focal-str (format nil "~,1F mm" focal-val)))
          (make-decoded-image :width width
                              :height height
                              :data lisp-data
                              :camera camera
                              :date date-str
                              :iso iso-str
                              :shutter shutter-str
                              :aperture aperture-str
                              :focal focal-str))))))

;;;; -------------------------------------------------------------------------
;;;; Image Stacking Stacking Mathematics
;;;; -------------------------------------------------------------------------

(declaim (inline luma-clip))
(defun luma-clip (p lo hi)
  "Generates matte value for component value p based on lo and hi thresholds."
  (declare (type single-float p lo hi)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (cond
    ((>= p hi) 0.0f0)
    ((< p lo) 1.0f0)
    (t (/ (- hi p) (- hi lo)))))

(declaim (inline ev-to-exposure-factor))
(defun ev-to-exposure-factor (ev)
  "Converts EV stops to a linear exposure factor."
  (declare (type single-float ev))
  (if (<= ev 0.0f0)
      (expt 2.0f0 (abs ev))
      (/ 1.0f0 (expt 2.0f0 ev))))

(defun stack-images-avx2 (layers ev-step lo hi center)
  "Vectorized stacking implementation using AVX2 SIMD."
  (declare (type list layers)
           (type single-float ev-step lo hi)
           (type fixnum center)
           (optimize (speed 3) (safety 0) (debug 0)))
  (let* ((first-layer (first layers))
         (fgs (rest layers))
         (size (length first-layer))
         (bg (make-array size :element-type 'single-float))
         (simd-limit (* (floor size 8) 8)))
    (declare (type (simple-array (unsigned-byte 16) (*)) first-layer)
             (type (simple-array single-float (*)) bg)
             (type fixnum size simd-limit))
    
    (let* ((norm-factor (sb-simd-avx2:f32.8-broadcast #.(/ 1.0f0 65535.0f0)))
           (mask-vec (sb-simd-avx2:s32.8-broadcast #xFFFF)))
      ;; 1. Initialize bg using AVX2 SIMD
      (loop for i from 0 by 8 below simd-limit do
        (let* ((u16-vec (sb-simd-avx2:u16.8-aref first-layer i))
               (s32-vec (sb-simd-avx2:s32.8-and (sb-simd-avx2:s32.8-from-u16.8 u16-vec) mask-vec))
               (f32-vec (sb-simd-avx2:f32.8-from-s32.8 s32-vec))
               (norm-vec (sb-simd-avx2:f32.8* f32-vec norm-factor)))
          (setf (sb-simd-avx2:f32.8-aref bg i) norm-vec)))
      ;; Scalar fallback for init
      (loop for i from simd-limit below size do
        (setf (aref bg i) (* (coerce (aref first-layer i) 'single-float) #.(/ 1.0f0 65535.0f0)))))

    ;; 2. Blend subsequent layers using AVX2 SIMD
    (let ((ev ev-step)
          (norm-factor (sb-simd-avx2:f32.8-broadcast #.(/ 1.0f0 65535.0f0)))
          (mask-vec (sb-simd-avx2:s32.8-broadcast #xFFFF))
          (hi-vec (sb-simd-avx2:f32.8-broadcast hi))
          (inv-range-vec (sb-simd-avx2:f32.8-broadcast (/ 1.0f0 (- hi lo))))
          (zero-vec (sb-simd-avx2:f32.8-broadcast 0.0f0))
          (one-vec (sb-simd-avx2:f32.8-broadcast 1.0f0)))
      (dolist (fg fgs)
        (let* ((exposure-factor (ev-to-exposure-factor ev))
               (ev-factor-vec (sb-simd-avx2:f32.8-broadcast exposure-factor))
               (fg-arr fg))
          (declare (type single-float exposure-factor)
                   (type (simple-array (unsigned-byte 16) (*)) fg-arr))
          ;; SIMD blend loop
          (loop for i from 0 by 8 below simd-limit do
            (let* ((u16-fg (sb-simd-avx2:u16.8-aref fg-arr i))
                   (s32-fg (sb-simd-avx2:s32.8-and (sb-simd-avx2:s32.8-from-u16.8 u16-fg) mask-vec))
                   (c-fg (sb-simd-avx2:f32.8* (sb-simd-avx2:f32.8-from-s32.8 s32-fg) norm-factor))
                   (c-bg (sb-simd-avx2:f32.8-aref bg i))
                   ;; Matte computation
                   (val (sb-simd-avx2:f32.8* (sb-simd-avx2:f32.8- hi-vec c-fg) inv-range-vec))
                   (matte (sb-simd-avx2:f32.8-max zero-vec (sb-simd-avx2:f32.8-min one-vec val)))
                   ;; Blend
                   (one-minus-matte (sb-simd-avx2:f32.8- one-vec matte))
                   (bg-part (sb-simd-avx2:f32.8* c-bg one-minus-matte))
                   (fg-part (sb-simd-avx2:f32.8* c-fg (sb-simd-avx2:f32.8* ev-factor-vec matte)))
                   (res (sb-simd-avx2:f32.8+ bg-part fg-part)))
              (setf (sb-simd-avx2:f32.8-aref bg i) res)))
          ;; Scalar fallback for blend
          (let ((norm #.(/ 1.0f0 65535.0f0))
                (inv-range (/ 1.0f0 (- hi lo))))
            (declare (type single-float norm inv-range))
            (loop for i from simd-limit below size do
              (let* ((c-fg (* (coerce (aref fg-arr i) 'single-float) norm))
                     (c-bg (aref bg i))
                     (matte (max 0.0f0 (min 1.0f0 (* (- hi c-fg) inv-range)))))
                (declare (type single-float c-fg c-bg matte))
                (setf (aref bg i)
                      (+ (* c-bg (- 1.0f0 matte))
                         (* c-fg exposure-factor matte)))))))
        (incf ev ev-step)))

    ;; 3. Adjust global scale based on center exposure
    (let ((center-factor (expt 2.0f0 (* ev-step (coerce (1- center) 'single-float)))))
      (declare (type single-float center-factor))
      (dotimes (i size)
        (setf (aref bg i) (* (aref bg i) center-factor))))
    bg))

(defun stack-images-scalar (layers ev-step lo hi center)
  "Pure scalar stacking implementation for hardware lacking AVX2."
  (declare (type list layers)
           (type single-float ev-step lo hi)
           (type fixnum center)
           (optimize (speed 3) (safety 0) (debug 0)))
  (let* ((first-layer (first layers))
         (fgs (rest layers))
         (size (length first-layer))
         (bg (make-array size :element-type 'single-float)))
    (declare (type (simple-array (unsigned-byte 16) (*)) first-layer)
             (type (simple-array single-float (*)) bg)
             (type fixnum size))
    ;; 1. Initialize bg with normalized floats from the first layer
    (let ((norm #.(/ 1.0f0 65535.0f0)))
      (declare (type single-float norm))
      (dotimes (i size)
        (setf (aref bg i) (* (coerce (aref first-layer i) 'single-float) norm))))
    ;; 2. Blend subsequent foreground layers
    (let ((ev ev-step)
          (norm #.(/ 1.0f0 65535.0f0))
          (inv-range (/ 1.0f0 (- hi lo))))
      (declare (type single-float ev norm inv-range))
      (dolist (fg fgs)
        (let ((exposure-factor (ev-to-exposure-factor ev))
              (fg-arr fg))
          (declare (type single-float exposure-factor)
                   (type (simple-array (unsigned-byte 16) (*)) fg-arr))
          (dotimes (i size)
            (let* ((c-fg (* (coerce (aref fg-arr i) 'single-float) norm))
                   (c-bg (aref bg i))
                   (matte (max 0.0f0 (min 1.0f0 (* (- hi c-fg) inv-range)))))
              (declare (type single-float c-fg c-bg matte))
              (setf (aref bg i)
                    (+ (* c-bg (- 1.0f0 matte))
                       (* c-fg exposure-factor matte))))))
        (incf ev ev-step)))
    ;; 3. Adjust global scale based on center exposure
    (let ((center-factor (expt 2.0f0 (* ev-step (coerce (1- center) 'single-float)))))
      (declare (type single-float center-factor))
      (dotimes (i size)
        (setf (aref bg i) (* (aref bg i) center-factor))))
    bg))

(defun stack-images (layers ev-step lo hi center)
  "Stacks multiple exposure 16-bit integer layers component-wise using dynamic CPU dispatch (AVX2 vs. Scalar)."
  (if (sb-simd-internals:avx2-supported-p)
      (stack-images-avx2 layers ev-step lo hi center)
      (stack-images-scalar layers ev-step lo hi center)))

;;;; -------------------------------------------------------------------------
;;;; Directory & File Utilities
;;;; -------------------------------------------------------------------------

(defun get-sorted-files (dir)
  "Gets alphabetical list of target files in dir, excluding hidden files and output EXRs."
  (let ((files (uiop:directory-files dir)))
    (setf files
          (remove-if (lambda (p)
                       (let ((nam (file-namestring p)))
                         (or (char= (char nam 0) #\.)
                             (uiop:string-suffix-p (string-downcase nam) ".exr"))))
                     files))
    (sort files #'string< :key #'namestring)))

(defun group-by-chunks (list chunk-size)
  "Splits a list into chunks of size CHUNK-SIZE."
  (let ((result nil)
        (current nil)
        (count 0))
    (dolist (item list)
      (push item current)
      (incf count)
      (when (= count chunk-size)
        (push (nreverse current) result)
        (setf current nil)
        (setf count 0)))
    (when current
      (push (nreverse current) result))
    (nreverse result)))

;;;; -------------------------------------------------------------------------
;;;; Threaded Chunk Execution Pipeline
;;;; -------------------------------------------------------------------------

(defun decode-chunk (chunk rotate max-threads)
  "Decodes raw files in a chunk, limiting parallel threads to max-threads.
If max-threads <= 0, decodes all files in parallel.
If max-threads = 1, decodes sequentially.
Otherwise, uses worker threads to process files concurrently."
  (cond
    ((= max-threads 1)
     (mapcar (lambda (file) (decode-raw-file file rotate)) chunk))
    ((or (<= max-threads 0) (>= max-threads (length chunk)))
     (let ((threads (mapcar (lambda (file)
                              (bt:make-thread
                               (lambda ()
                                 (decode-raw-file file rotate))
                               :name (format nil "decode-~A" (file-namestring file))))
                            chunk)))
       (mapcar #'bt:join-thread threads)))
    (t
     (let* ((queue chunk)
            (lock (bt:make-lock "decode-queue-lock"))
            (results (make-array (length chunk)))
            (threads '()))
       (labels ((get-next-task ()
                  (bt:with-lock-held (lock)
                    (when queue
                      (let ((file (pop queue))
                            (idx (- (length chunk) (length queue) 1)))
                        (cons file idx)))))
                (worker-loop ()
                  (loop
                    (let ((task (get-next-task)))
                      (if task
                          (let* ((file (car task))
                                 (idx (cdr task))
                                 (decoded (decode-raw-file file rotate)))
                            (setf (aref results idx) decoded))
                          (return))))))
         (dotimes (i max-threads)
           (push (bt:make-thread #'worker-loop :name (format nil "decode-worker-~D" i))
                 threads))
         (dolist (th threads)
           (bt:join-thread th))
         (coerce results 'list))))))

(defun process-chunk (chunk chunk-idx total-chunks args)
  "Processes a single chunk: decodes raw images in parallel, stacks them, and saves to EXR."
  (let ((verbose (cli-args-verbose args))
        (t-start (get-internal-real-time)))
    (when verbose
      (format t "[~D/~D] Starting chunk processing for files:~%~{  - ~A~%~}"
              chunk-idx total-chunks (mapcar #'file-namestring chunk)))
    
    (let* ((t-dec-start (get-internal-real-time))
           (decoded-images (decode-chunk chunk (cli-args-rotate args) (cli-args-max-decode-threads args)))
           (t-dec-end (get-internal-real-time))
           (first-img (first decoded-images))
           (width (decoded-image-width first-img))
           (height (decoded-image-height first-img)))
      ;; Ensure size consistency
      (dolist (img (rest decoded-images))
        (unless (and (= (decoded-image-width img) width)
                     (= (decoded-image-height img) height))
          (error "Image size mismatch within chunk: ~Ax~A vs ~Ax~A"
                 width height (decoded-image-width img) (decoded-image-height img))))
      
      (when verbose
        (format t "  Demosaiced chunk successfully. Stacking...~%"))
      
      ;; Perform stacking
      (let* ((t-stack-start (get-internal-real-time))
             (layers (mapcar #'decoded-image-data decoded-images))
             (stacked-data (stack-images layers
                                         (cli-args-ev args)
                                         (cli-args-lo args)
                                         (cli-args-hi args)
                                         (cli-args-center args)))
             (t-stack-end (get-internal-real-time))
             ;; Fetch metadata from the specified center image
             (meta-img (elt decoded-images (1- (cli-args-center args))))
             (metadata (list (cons "camera" (decoded-image-camera meta-img))
                             (cons "date" (decoded-image-date meta-img))
                             (cons "iso" (decoded-image-iso meta-img))
                             (cons "shutter" (decoded-image-shutter meta-img))
                             (cons "aperture" (decoded-image-aperture meta-img))
                             (cons "focal" (decoded-image-focal meta-img))))
             ;; Generate output filename
             (out-filename (format nil "~A~4,'0D" (cli-args-output-basename args) chunk-idx))
             (out-pathname (merge-pathnames (make-pathname :name out-filename :type "exr")
                                             (cli-args-output-dir args))))
        
        (when verbose
          (format t "  Writing EXR output: ~A~%" (namestring out-pathname)))
        
        (let ((t-save-start (get-internal-real-time)))
          (with-open-file (out-stream out-pathname
                                      :direction :output
                                      :element-type '(unsigned-byte 8)
                                      :if-exists :supersede)
            (exr:encode-rgb-to-exr out-stream width height stacked-data
                                               :pixel-type (if (cli-args-float-mode args) :float :half)
                                               :compression (cli-args-zip-mode args)
                                               :comments "Made with rawtohdri 1.0 (Lisp) by Aaron Estrada"
                                               :metadata metadata))
          (let* ((t-save-end (get-internal-real-time))
                 (dec-sec (/ (coerce (- t-dec-end t-dec-start) 'single-float) internal-time-units-per-second))
                 (stack-sec (/ (coerce (- t-stack-end t-stack-start) 'single-float) internal-time-units-per-second))
                 (save-sec (/ (coerce (- t-save-end t-save-start) 'single-float) internal-time-units-per-second))
                 (total-sec (/ (coerce (- t-save-end t-start) 'single-float) internal-time-units-per-second)))
            (format t "Created HDR Image: ~A~%" (file-namestring out-pathname))
            (when verbose
              (format t "  Speed Report (Chunk ~D/~D):~%" chunk-idx total-chunks)
              (format t "    Decoding/Demosaic : ~,3F seconds~%" dec-sec)
              (format t "    Stacking          : ~,3F seconds~%" stack-sec)
              (format t "    EXR Encoding/Save : ~,3F seconds~%" save-sec)
              (format t "    Total Chunk Time  : ~,3F seconds~%" total-sec))))))))

;;;; -------------------------------------------------------------------------
;;;; Main Entry Point
;;;; -------------------------------------------------------------------------

(defun main ()
  "Main executable entry point."
  (let* ((t-start (get-internal-real-time))
         (argv (cdr sb-ext:*posix-argv*))
         (args (handler-case (parse-cli-args argv)
                 (error (c)
                   (format t "Error parsing options: ~A~%" c)
                   (sb-ext:exit :code 1)))))
    (if (cli-args-tui-mode args)
        (progn
          (run-tui args)
          (sb-ext:exit :code 0))
        (let ((files (get-sorted-files (cli-args-input-dir args))))
          (unless files
            (format t "No raw files found in directory: ~A~%" (cli-args-input-dir args))
            (sb-ext:exit :code 0))
          (let* ((chunks (group-by-chunks files (cli-args-chunk args)))
                 (total-chunks (length chunks)))
            (when (cli-args-verbose args)
              (format t "Found ~D total files. Grouped into ~D chunks of size ~D.~%"
                      (length files) total-chunks (cli-args-chunk args)))
            (loop for chunk in chunks
                  for idx from 1
                  do (handler-case
                         (if (< (length chunk) (cli-args-chunk args))
                             (format t "Warning: skipping incomplete chunk ~D/~D of size ~D (expected ~D)~%"
                                     idx total-chunks (length chunk) (cli-args-chunk args))
                             (process-chunk chunk idx total-chunks args))
                       (error (c)
                         (format t "Fatal error processing chunk ~D: ~A~%" idx c)
                         (sb-ext:exit :code 1))))
            (when (cli-args-verbose args)
              (let ((total-sec (/ (coerce (- (get-internal-real-time) t-start) 'single-float)
                                  internal-time-units-per-second)))
                (format t "All chunks processed. Total execution time: ~,3F seconds~%" total-sec))))
          (sb-ext:exit :code 0)))))
