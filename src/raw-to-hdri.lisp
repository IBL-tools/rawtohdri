;;;; raw-to-hdri.lisp - CLI tool for stacking bracketed raw files to HDR OpenEXR
;;;; Part of the rawtohdri package.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ql:quickload '(:cffi :bordeaux-threads :uiop) :silent t))

(defpackage :raw-to-hdri
  (:use :cl)
  (:export #:main
           #:stack-images
           #:ev-to-exposure-factor
           #:luma-clip))

(in-package :raw-to-hdri)

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
  (zip-mode :zips))

(defun print-help ()
  (format t "Usage: rawtohdri <input_dir> [options]

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
  --zip                       Save EXR with ZIP (16-scanline block) instead of ZIPS (single-scanline)
  -h, --help                  Show this help text
"))

(defun parse-cli-args (argv)
  (let ((args (make-cli-args)))
    (labels ((parse-next (list)
               (when list
                 (let ((opt (first list)))
                   (cond
                     ((or (string= opt "-x") (string= opt "--chunk"))
                      (setf (cli-args-chunk args) (parse-integer (second list)))
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
                     ((string= opt "--zip")
                      (setf (cli-args-zip-mode args) :zip)
                      (parse-next (cdr list)))
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
      (unless (cli-args-input-dir args)
        (format t "Error: input directory is required.~%")
        (print-help)
        (sb-ext:exit :code 1))
      
      ;; Verify input directory exists
      (unless (uiop:directory-exists-p (cli-args-input-dir args))
        (format t "Error: input directory ~S does not exist.~%" (cli-args-input-dir args))
        (sb-ext:exit :code 1))
      
      ;; Ensure input-dir string is absolute or correctly formatted
      (setf (cli-args-input-dir args)
            (namestring (uiop:directory-exists-p (cli-args-input-dir args))))
      
      ;; Handle nesting or default output directory
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
              (setf (cli-args-output-dir args) (cli-args-input-dir args))))
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
  (data nil) ; (simple-array single-float (*))
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
             (lisp-data (make-array pixel-count :element-type 'single-float))
             (c-data-ptr (cffi:inc-pointer img-ptr 16)))
        (declare (type fixnum width height colors bits pixel-count)
                 (type (simple-array single-float (*)) lisp-data))
        (unless (= bits 16)
          (error "Expected 16-bit processed image, got ~D bits" bits))
        (unless (= colors 3)
          (error "Expected 3-color processed image, got ~D colors" colors))
        
        ;; Copy uint16 data to Lisp float array and normalize to [0.0, 1.0]
        (dotimes (i pixel-count)
          (setf (aref lisp-data i)
                (/ (coerce (cffi:mem-aref c-data-ptr :uint16 i) 'single-float) 65535.0f0)))
        
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

(defun stack-images (layers ev-step lo hi center)
  "Stacks multiple exposure layers component-wise and returns the combined image."
  (declare (type list layers)
           (type single-float ev-step lo hi)
           (type fixnum center)
           (optimize (speed 3) (safety 0) (debug 0)))
  (let* ((bg (first layers))
         (fgs (rest layers))
         (size (length bg))
         (output (make-array size :element-type 'single-float)))
    (declare (type (simple-array single-float (*)) bg output)
             (type fixnum size))
    ;; Copy base layer (darkest) to output
    (dotimes (i size)
      (setf (aref output i) (aref bg i)))
    ;; Iteratively blend subsequent foreground layers (brighter)
    (let ((ev ev-step))
      (dolist (fg fgs)
        (let ((exposure-factor (ev-to-exposure-factor ev))
              (fg-arr fg))
          (declare (type single-float exposure-factor)
                   (type (simple-array single-float (*)) fg-arr))
          (dotimes (i size)
            (let* ((c-fg (aref fg-arr i))
                   (c-bg (aref output i))
                   (matte (luma-clip c-fg lo hi)))
              (declare (type single-float c-fg c-bg matte))
              (setf (aref output i)
                    (+ (* c-bg (- 1.0f0 matte))
                       (* c-fg exposure-factor matte))))))
        (incf ev ev-step)))
    ;; Adjust global scale based on center exposure
    (let ((center-factor (expt 2.0f0 (* ev-step (coerce (1- center) 'single-float)))))
      (declare (type single-float center-factor))
      (dotimes (i size)
        (setf (aref output i) (* (aref output i) center-factor))))
    output))

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

(defun decode-chunk-in-parallel (chunk rotate)
  "Spawns parallel threads to decode all raw files in a chunk concurrently."
  (let ((threads (mapcar (lambda (file)
                           (bt:make-thread
                            (lambda ()
                              (decode-raw-file file rotate))
                            :name (format nil "decode-~A" (file-namestring file))))
                         chunk)))
    (mapcar #'bt:join-thread threads)))

(defun process-chunk (chunk chunk-idx args)
  "Processes a single chunk: decodes raw images in parallel, stacks them, and saves to EXR."
  (let ((verbose (cli-args-verbose args)))
    (when verbose
      (format t "[~D/~D] Starting chunk processing for files:~%~{  - ~A~%~}"
              chunk-idx chunk-idx (mapcar #'file-namestring chunk)))
    
    (let* ((decoded-images (decode-chunk-in-parallel chunk (cli-args-rotate args)))
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
      (let* ((layers (mapcar #'decoded-image-data decoded-images))
             (stacked-data (stack-images layers
                                         (cli-args-ev args)
                                         (cli-args-lo args)
                                         (cli-args-hi args)
                                         (cli-args-center args)))
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
        
        (with-open-file (out-stream out-pathname
                                    :direction :output
                                    :element-type '(unsigned-byte 8)
                                    :if-exists :supersede)
          (nxsh-simple-exr:encode-rgb-to-exr out-stream width height stacked-data
                                             :pixel-type (if (cli-args-float-mode args) :float :half)
                                             :compression (cli-args-zip-mode args)
                                             :comments "Made with rawtohdri 1.0 (Lisp) by Aaron Estrada"
                                             :metadata metadata))
        
        (format t "Created HDR Image: ~A~%" (file-namestring out-pathname))))))

;;;; -------------------------------------------------------------------------
;;;; Main Entry Point
;;;; -------------------------------------------------------------------------

(defun main ()
  "Main executable entry point."
  (let* ((argv (cdr sb-ext:*posix-argv*))
         (args (handler-case (parse-cli-args argv)
                 (error (c)
                   (format t "Error parsing options: ~A~%" c)
                   (sb-ext:exit :code 1))))
         (files (get-sorted-files (cli-args-input-dir args))))
    
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
                       (process-chunk chunk idx args))
                 (error (c)
                   (format t "Fatal error processing chunk ~D: ~A~%" idx c)
                   (sb-ext:exit :code 1)))))
    
    (sb-ext:exit :code 0)))
