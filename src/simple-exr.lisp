;;;; High-Performance Parallel OpenEXR (float/half) exporter in pure Common Lisp.
;;;; WWW.NXSH.DEV :::: bringing you the future of the past -- TODAY!!!

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ql:quickload :bordeaux-threads :silent t)
  (ql:quickload :salza2 :silent t))

(defpackage :exr
  (:use :cl)
  (:export #:encode-rgb-to-exr
           #:encode-single-channel-to-exr
           #:detect-cores))

(in-package :exr)

(defstruct comp-state
  (chunks '() :type list)
  (size 0 :type fixnum))

(defun detect-cores ()
  "Detects logical CPU cores by parsing /proc/cpuinfo.
Gracefully falls back to a default of 8 cores if the file is missing,
unreadable, or yields a zero count."
  (or (ignore-errors
       (with-open-file (stream "/proc/cpuinfo" :if-does-not-exist nil)
         (when stream
           (let ((count (loop for line = (read-line stream nil nil)
                              while line
                              count (uiop:string-prefix-p "processor" line))))
             (when (plusp count)
               count)))))
      8))

(declaim (optimize (speed 3) (safety 0) (debug 0) (space 0)))

;; Fast single-float to half-precision bits converter
(declaim (inline float-to-half-bits))
(defun float-to-half-bits (f)
  (declare (type single-float f)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (let* ((bits (sb-kernel:single-float-bits f))
         (sign (ash (ldb (byte 1 31) bits) 15))
         (exponent (ldb (byte 8 23) bits))
         (mantissa (ldb (byte 23 0) bits)))
    (declare (type (unsigned-byte 32) bits)
             (type fixnum sign exponent mantissa))
    (cond
      ;; Zero
      ((and (= exponent 0) (= mantissa 0))
       sign)
      ;; Infinity / NaN
      ((= exponent 255)
       (logior sign #x7c00 (if (= mantissa 0) 0 #x0200)))
      (t
       (let ((new-exp (- exponent 112)))
         (declare (type fixnum new-exp))
         (cond
           ;; Exponent overflow -> Infinity
           ((>= new-exp 31)
            (logior sign #x7c00))
           ;; Subnormal / Underflow
           ((<= new-exp 0)
            (if (< new-exp -10)
                sign ;; Complete underflow to zero
                (let* ((shifted-mantissa (ash (logior #x800000 mantissa) (- new-exp 1)))
                       (rounded (+ shifted-mantissa #x1000)))
                  (logior sign (ash rounded -13)))))
           (t
            ;; Normal half representation
            (logior sign (ash new-exp 10) (ash (+ mantissa #x1000) -13)))))))))

;; Compute auto-crop bounding box based on positive pixel/alpha values
(defun compute-autocrop-bounds (width height main-array alpha-array threshold padding is-rgb)
  (declare (type fixnum width height padding)
           (type single-float threshold)
           (type (simple-array single-float (*)) main-array)
           (type (or null (simple-array single-float (*))) alpha-array)
           (type boolean is-rgb)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (let ((xmin (1- width))
        (xmax 0)
        (ymin (1- height))
        (ymax 0)
        (found nil))
    (declare (type fixnum xmin xmax ymin ymax))
    (dotimes (y height)
      (dotimes (x width)
        (let* ((pixel-idx (+ (* y width) x))
               (is-subject (if alpha-array
                               (> (aref alpha-array pixel-idx) threshold)
                               (if is-rgb
                                   (let ((rgb-idx (* pixel-idx 3)))
                                     (or (> (aref main-array rgb-idx) threshold)
                                         (> (aref main-array (1+ rgb-idx)) threshold)
                                         (> (aref main-array (+ rgb-idx 2)) threshold)))
                                   (> (aref main-array pixel-idx) threshold)))))
          (when is-subject
            (setf found t)
            (when (< x xmin) (setf xmin x))
            (when (> x xmax) (setf xmax x))
            (when (< y ymin) (setf ymin y))
            (when (> y ymax) (setf ymax y))))))
    (if found
        ;; Apply padding with boundary clamping
        (values (max 0 (- xmin padding))
                (max 0 (- ymin padding))
                (min (1- width) (+ xmax padding))
                (min (1- height) (+ ymax padding)))
        ;; Fallback to entire image
        (values 0 0 (1- width) (1- height)))))

;; Process a single scanline block with data window cropping (scanline-by-scanline, channel-by-channel)
(defun process-block (compressor state original-width dw-xmin dw-xmax y-start block-rows rgb-array alpha-array pixel-type u i d)
  (declare (type salza2:deflate-compressor compressor)
           (type comp-state state)
           (type fixnum original-width dw-xmin dw-xmax y-start block-rows)
           (type (simple-array single-float (*)) rgb-array)
           (type (or null (simple-array single-float (*))) alpha-array)
           (type keyword pixel-type)
           (type (simple-array (unsigned-byte 8) (*)) u i d)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (let* ((has-alpha (if alpha-array t nil))
         (channels-count (if has-alpha 4 3))
         (dw-width (1+ (- dw-xmax dw-xmin)))
         (bytes-per-val (if (eq pixel-type :half) 2 4))
         (row-channel-bytes (* dw-width bytes-per-val))
         (row-bytes (* row-channel-bytes channels-count))
         (total-uncompressed-bytes (* row-bytes block-rows)))
    (declare (type fixnum dw-width channels-count bytes-per-val row-channel-bytes row-bytes total-uncompressed-bytes))
    
    ;; Populate the buffer: scanline-by-scanline, and channel-by-channel within each scanline
    (dotimes (r block-rows)
      (let* ((y (+ y-start r))
             (scanline-start (* r row-bytes)))
        (declare (type fixnum y scanline-start))
        (let ((c-idx 0))
          (declare (type fixnum c-idx))
          
          ;; Write Alpha if present (alphabetically "A" comes first)
          (when has-alpha
            (let ((channel-start (+ scanline-start (* c-idx row-channel-bytes))))
              (declare (type fixnum channel-start))
              (loop for x from dw-xmin to dw-xmax
                    for dx from 0 do
                (let* ((pixel-idx (+ (* y original-width) x))
                       (val (aref alpha-array pixel-idx))
                       (dst-pos (+ channel-start (* dx bytes-per-val))))
                  (declare (type fixnum pixel-idx dst-pos))
                  (if (eq pixel-type :half)
                      (let ((bits (float-to-half-bits val)))
                        (setf (aref u dst-pos) (ldb (byte 8 0) bits)
                              (aref u (1+ dst-pos)) (ldb (byte 8 8) bits)))
                      (let ((bits (sb-kernel:single-float-bits val)))
                        (setf (aref u dst-pos) (ldb (byte 8 0) bits)
                              (aref u (+ dst-pos 1)) (ldb (byte 8 8) bits)
                              (aref u (+ dst-pos 2)) (ldb (byte 8 16) bits)
                              (aref u (+ dst-pos 3)) (ldb (byte 8 24) bits))))))
              (incf c-idx)))
          
          ;; Write Blue, Green, Red (alphabetically B, G, R)
          (dolist (color-channel '(2 1 0))
            (let ((channel-start (+ scanline-start (* c-idx row-channel-bytes))))
              (declare (type fixnum channel-start))
              (loop for x from dw-xmin to dw-xmax
                    for dx from 0 do
                (let* ((pixel-idx (* (+ (* y original-width) x) 3))
                       (val (aref rgb-array (+ pixel-idx color-channel)))
                       (dst-pos (+ channel-start (* dx bytes-per-val))))
                  (declare (type fixnum pixel-idx dst-pos))
                  (if (eq pixel-type :half)
                      (let ((bits (float-to-half-bits val)))
                        (setf (aref u dst-pos) (ldb (byte 8 0) bits)
                              (aref u (1+ dst-pos)) (ldb (byte 8 8) bits)))
                      (let ((bits (sb-kernel:single-float-bits val)))
                        (setf (aref u dst-pos) (ldb (byte 8 0) bits)
                              (aref u (+ dst-pos 1)) (ldb (byte 8 8) bits)
                              (aref u (+ dst-pos 2)) (ldb (byte 8 16) bits)
                              (aref u (+ dst-pos 3)) (ldb (byte 8 24) bits))))))
              (incf c-idx))))))
    
    ;; Byte Interleaving (even offsets first, then odd offsets)
    (let ((t1 0)
          (t2 (ceiling total-uncompressed-bytes 2)))
      (declare (type fixnum t1 t2))
      (dotimes (idx total-uncompressed-bytes)
        (if (evenp idx)
            (progn
              (setf (aref i t1) (aref u idx))
              (incf t1))
            (progn
              (setf (aref i t2) (aref u idx))
              (incf t2)))))
    
    ;; Difference Predictor
    (setf (aref d 0) (aref i 0))
    (loop for idx from 1 below total-uncompressed-bytes do
      (let ((diff (logand (+ (- (aref i idx) (aref i (1- idx))) 128) #xff)))
        (setf (aref d idx) diff)))
    
    ;; Zlib Deflation
    (setf (comp-state-chunks state) '()
          (comp-state-size state) 0)
    (salza2:reset compressor)
    (salza2:compress-octet-vector d compressor :end total-uncompressed-bytes)
    (salza2:finish-compression compressor)
    (let* ((size (comp-state-size state))
           (compressed (make-array size :element-type '(unsigned-byte 8)))
           (start 0))
      (dolist (chunk (nreverse (comp-state-chunks state)))
        (replace compressed chunk :start1 start)
        (incf start (length chunk)))
      compressed)))

;;;; Process a single scanline block for a single channel with data window cropping
(defun process-single-channel-block (compressor state original-width dw-xmin dw-xmax y-start block-rows data-array pixel-type u i d)
  (declare (type salza2:deflate-compressor compressor)
           (type comp-state state)
           (type fixnum original-width dw-xmin dw-xmax y-start block-rows)
           (type (simple-array single-float (*)) data-array)
           (type keyword pixel-type)
           (type (simple-array (unsigned-byte 8) (*)) u i d)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (let* ((dw-width (1+ (- dw-xmax dw-xmin)))
         (bytes-per-val (if (eq pixel-type :half) 2 4))
         (row-channel-bytes (* dw-width bytes-per-val))
         (block-channel-bytes (* row-channel-bytes block-rows)))
    (declare (type fixnum dw-width bytes-per-val row-channel-bytes block-channel-bytes))
    
    (dotimes (r block-rows)
      (let* ((y (+ y-start r))
             (dst-row-start (* r row-channel-bytes)))
        (loop for x from dw-xmin to dw-xmax
              for dx from 0 do
          (let* ((pixel-idx (+ (* y original-width) x))
                 (val (aref data-array pixel-idx))
                 (dst-pos (+ dst-row-start (* dx bytes-per-val))))
            (if (eq pixel-type :half)
                (let ((bits (float-to-half-bits val)))
                  (setf (aref u dst-pos) (ldb (byte 8 0) bits)
                        (aref u (1+ dst-pos)) (ldb (byte 8 8) bits)))
                (let ((bits (sb-kernel:single-float-bits val)))
                  (setf (aref u dst-pos) (ldb (byte 8 0) bits)
                        (aref u (+ dst-pos 1)) (ldb (byte 8 8) bits)
                        (aref u (+ dst-pos 2)) (ldb (byte 8 16) bits)
                        (aref u (+ dst-pos 3)) (ldb (byte 8 24) bits))))))))
    
    ;; Byte Interleaving (even offsets first, then odd offsets)
    (let ((t1 0)
          (t2 (ceiling block-channel-bytes 2)))
      (declare (type fixnum t1 t2))
      (dotimes (idx block-channel-bytes)
        (if (evenp idx)
            (progn
              (setf (aref i t1) (aref u idx))
              (incf t1))
            (progn
              (setf (aref i t2) (aref u idx))
              (incf t2)))))
    
    ;; Predictor
    (setf (aref d 0) (aref i 0))
    (loop for idx from 1 below block-channel-bytes do
      (let ((diff (logand (+ (- (aref i idx) (aref i (1- idx))) 128) #xff)))
        (setf (aref d idx) diff)))
    
    ;; Deflate
    (setf (comp-state-chunks state) '()
          (comp-state-size state) 0)
    (salza2:reset compressor)
    (let ((clb (salza2:callback compressor)))
      (declare (ignore clb)))
    (salza2:compress-octet-vector d compressor :end block-channel-bytes)
    (salza2:finish-compression compressor)
    (let* ((size (comp-state-size state))
           (compressed (make-array size :element-type '(unsigned-byte 8)))
           (start 0))
      (dolist (chunk (nreverse (comp-state-chunks state)))
        (replace compressed chunk :start1 start)
        (incf start (length chunk)))
      compressed)))

;;;; Construct OpenEXR header attributes with explicit bounds
(defun make-exr-header (width height dw-xmin dw-ymin dw-xmax dw-ymax has-alpha pixel-type compression-type &optional comments metadata)
  (let ((out (make-array 1024 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (labels ((write-bytes (vector)
               (loop for byte across vector do (vector-push-extend byte out)))
             (write-null-str (str)
                (loop for char across str do (vector-push-extend (char-code char) out))
                (vector-push-extend 0 out))
             (write-u32 (val)
               (vector-push-extend (ldb (byte 8 0) val) out)
               (vector-push-extend (ldb (byte 8 8) val) out)
               (vector-push-extend (ldb (byte 8 16) val) out)
               (vector-push-extend (ldb (byte 8 24) val) out))
             (write-u8 (val)
               (vector-push-extend val out))
             (write-attr (name type val-bytes)
               (write-null-str name)
               (write-null-str type)
               (write-u32 (length val-bytes))
               (write-bytes val-bytes)))
      
      ;; Magic number
      (write-bytes #(118 47 49 1))
      ;; Version and flags
      (write-bytes #(2 0 0 0))
      
      ;; Channels attribute
      (let ((chlist (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
        (labels ((add-ch (ch-name)
                   (loop for char across ch-name do (vector-push-extend (char-code char) chlist))
                   (vector-push-extend 0 chlist)
                   ;; pixel type: 1 = HALF, 2 = FLOAT
                   (let ((pt (if (eq pixel-type :half) 1 2)))
                     (vector-push-extend (ldb (byte 8 0) pt) chlist)
                     (vector-push-extend (ldb (byte 8 8) pt) chlist)
                     (vector-push-extend (ldb (byte 8 16) pt) chlist)
                     (vector-push-extend (ldb (byte 8 24) pt) chlist))
                   ;; pLinear
                   (vector-push-extend 0 chlist)
                   ;; reserved
                   (vector-push-extend 0 chlist)
                   (vector-push-extend 0 chlist)
                   (vector-push-extend 0 chlist)
                   ;; xSampling, ySampling
                   (dotimes (i 4) (vector-push-extend (if (= i 0) 1 0) chlist))
                   (dotimes (i 4) (vector-push-extend (if (= i 0) 1 0) chlist))))
          (when has-alpha (add-ch "A"))
          (add-ch "B")
          (add-ch "G")
          (add-ch "R")
          (vector-push-extend 0 chlist))
        (write-attr "channels" "chlist" chlist))
      
      ;; Compression attribute
      (write-attr "compression" "compression"
                  (vector (if (eq compression-type :zips) 2 3)))
      
      ;; DataWindow attribute (xmin, ymin, xmax, ymax)
      (let ((win (make-array 16 :element-type '(unsigned-byte 8))))
        (labels ((pack-win (idx val)
                   (setf (aref win (* idx 4)) (ldb (byte 8 0) val)
                         (aref win (+ (* idx 4) 1)) (ldb (byte 8 8) val)
                         (aref win (+ (* idx 4) 2)) (ldb (byte 8 16) val)
                         (aref win (+ (* idx 4) 3)) (ldb (byte 8 24) val))))
          (pack-win 0 dw-xmin)
          (pack-win 1 dw-ymin)
          (pack-win 2 dw-xmax)
          (pack-win 3 dw-ymax))
        (write-attr "dataWindow" "box2i" win))
      
      ;; DisplayWindow attribute (0, 0, width-1, height-1)
      (let ((win (make-array 16 :element-type '(unsigned-byte 8))))
        (labels ((pack-win (idx val)
                   (setf (aref win (* idx 4)) (ldb (byte 8 0) val)
                         (aref win (+ (* idx 4) 1)) (ldb (byte 8 8) val)
                         (aref win (+ (* idx 4) 2)) (ldb (byte 8 16) val)
                         (aref win (+ (* idx 4) 3)) (ldb (byte 8 24) val))))
          (pack-win 0 0)
          (pack-win 1 0)
          (pack-win 2 (1- width))
          (pack-win 3 (1- height)))
        (write-attr "displayWindow" "box2i" win))
      
      ;; LineOrder attribute
      (write-attr "lineOrder" "lineOrder" #(0))
      
      ;; PixelAspectRatio attribute
      (let ((bytes (make-array 4 :element-type '(unsigned-byte 8))))
        (let ((bits (sb-kernel:single-float-bits 1.0f0)))
          (setf (aref bytes 0) (ldb (byte 8 0) bits)
                (aref bytes 1) (ldb (byte 8 8) bits)
                (aref bytes 2) (ldb (byte 8 16) bits)
                (aref bytes 3) (ldb (byte 8 24) bits)))
        (write-attr "pixelAspectRatio" "float" bytes))
      
      ;; ScreenWindowCenter attribute
      (write-attr "screenWindowCenter" "v2f" #(0 0 0 0 0 0 0 0))
      
      ;; ScreenWindowWidth attribute
      (let ((bytes (make-array 4 :element-type '(unsigned-byte 8))))
        (let ((bits (sb-kernel:single-float-bits 1.0f0)))
          (setf (aref bytes 0) (ldb (byte 8 0) bits)
                (aref bytes 1) (ldb (byte 8 8) bits)
                (aref bytes 2) (ldb (byte 8 16) bits)
                (aref bytes 3) (ldb (byte 8 24) bits)))
        (write-attr "screenWindowWidth" "float" bytes))
      
      ;; Custom string comments attribute (fully spec-compliant)
      (when comments
        (let ((val-bytes (make-array (length comments) :element-type '(unsigned-byte 8))))
          (dotimes (i (length comments))
            (setf (aref val-bytes i) (char-code (char comments i))))
          (write-attr "comments" "string" val-bytes)))
      
      ;; Custom metadata attributes
      (loop for (name . val) in metadata do
        (let ((val-bytes (make-array (length val) :element-type '(unsigned-byte 8))))
          (dotimes (i (length val))
            (setf (aref val-bytes i) (char-code (char val i))))
          (write-attr name "string" val-bytes)))
      
      ;; Header Terminator
      (write-u8 0)
      
      out)))

;; Construct single channel OpenEXR header attributes with explicit bounds
(defun make-exr-single-channel-header (width height dw-xmin dw-ymin dw-xmax dw-ymax channel-name pixel-type compression-type &optional comments)
  (let ((out (make-array 1024 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (labels ((write-bytes (vector)
               (loop for byte across vector do (vector-push-extend byte out)))
             (write-null-str (str)
               (loop for char across str do (vector-push-extend (char-code char) out))
               (vector-push-extend 0 out))
             (write-u32 (val)
               (vector-push-extend (ldb (byte 8 0) val) out)
               (vector-push-extend (ldb (byte 8 8) val) out)
               (vector-push-extend (ldb (byte 8 16) val) out)
               (vector-push-extend (ldb (byte 8 24) val) out))
             (write-u8 (val)
               (vector-push-extend val out))
             (write-attr (name type val-bytes)
               (write-null-str name)
               (write-null-str type)
               (write-u32 (length val-bytes))
               (write-bytes val-bytes)))
      
      (write-bytes #(118 47 49 1))
      (write-bytes #(2 0 0 0))
      
      ;; Channels attribute with single channel
      (let ((chlist (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
        (loop for char across channel-name do (vector-push-extend (char-code char) chlist))
        (vector-push-extend 0 chlist)
        ;; pixel type: 1 = HALF, 2 = FLOAT
        (let ((pt (if (eq pixel-type :half) 1 2)))
          (vector-push-extend (ldb (byte 8 0) pt) chlist)
          (vector-push-extend (ldb (byte 8 8) pt) chlist)
          (vector-push-extend (ldb (byte 8 16) pt) chlist)
          (vector-push-extend (ldb (byte 8 24) pt) chlist))
        ;; pLinear
        (vector-push-extend 0 chlist)
        ;; reserved
        (vector-push-extend 0 chlist)
        (vector-push-extend 0 chlist)
        (vector-push-extend 0 chlist)
        ;; xSampling, ySampling
        (dotimes (i 4) (vector-push-extend (if (= i 0) 1 0) chlist))
        (dotimes (i 4) (vector-push-extend (if (= i 0) 1 0) chlist))
        (vector-push-extend 0 chlist)
        (write-attr "channels" "chlist" chlist))
      
      (write-attr "compression" "compression"
                  (vector (if (eq compression-type :zips) 2 3)))
      
      ;; DataWindow attribute
      (let ((win (make-array 16 :element-type '(unsigned-byte 8))))
        (labels ((pack-win (idx val)
                   (setf (aref win (* idx 4)) (ldb (byte 8 0) val)
                         (aref win (+ (* idx 4) 1)) (ldb (byte 8 8) val)
                         (aref win (+ (* idx 4) 2)) (ldb (byte 8 16) val)
                         (aref win (+ (* idx 4) 3)) (ldb (byte 8 24) val))))
          (pack-win 0 dw-xmin)
          (pack-win 1 dw-ymin)
          (pack-win 2 dw-xmax)
          (pack-win 3 dw-ymax))
        (write-attr "dataWindow" "box2i" win))
      
      ;; DisplayWindow attribute
      (let ((win (make-array 16 :element-type '(unsigned-byte 8))))
        (labels ((pack-win (idx val)
                   (setf (aref win (* idx 4)) (ldb (byte 8 0) val)
                         (aref win (+ (* idx 4) 1)) (ldb (byte 8 8) val)
                         (aref win (+ (* idx 4) 2)) (ldb (byte 8 16) val)
                         (aref win (+ (* idx 4) 3)) (ldb (byte 8 24) val))))
          (pack-win 0 0)
          (pack-win 1 0)
          (pack-win 2 (1- width))
          (pack-win 3 (1- height)))
        (write-attr "displayWindow" "box2i" win))
      
      (write-attr "lineOrder" "lineOrder" #(0))
      
      (let ((bytes (make-array 4 :element-type '(unsigned-byte 8))))
        (let ((bits (sb-kernel:single-float-bits 1.0f0)))
          (setf (aref bytes 0) (ldb (byte 8 0) bits)
                (aref bytes 1) (ldb (byte 8 8) bits)
                (aref bytes 2) (ldb (byte 8 16) bits)
                (aref bytes 3) (ldb (byte 8 24) bits)))
        (write-attr "pixelAspectRatio" "float" bytes))
      
      (write-attr "screenWindowCenter" "v2f" #(0 0 0 0 0 0 0 0))
      
      (let ((bytes (make-array 4 :element-type '(unsigned-byte 8))))
        (let ((bits (sb-kernel:single-float-bits 1.0f0)))
          (setf (aref bytes 0) (ldb (byte 8 0) bits)
                (aref bytes 1) (ldb (byte 8 8) bits)
                (aref bytes 2) (ldb (byte 8 16) bits)
                (aref bytes 3) (ldb (byte 8 24) bits)))
        (write-attr "screenWindowWidth" "float" bytes))
      
      ;; Custom string comments attribute (fully spec-compliant)
      (when comments
        (let ((val-bytes (make-array (length comments) :element-type '(unsigned-byte 8))))
          (dotimes (i (length comments))
            (setf (aref val-bytes i) (char-code (char comments i))))
          (write-attr "comments" "string" val-bytes)))
      
      (write-u8 0)
      out)))

;; Write 64-bit unsigned integer to stream (little-endian)
(defun write-u64-le (stream val)
  (declare (type (unsigned-byte 64) val)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (write-byte (ldb (byte 8 0) val) stream)
  (write-byte (ldb (byte 8 8) val) stream)
  (write-byte (ldb (byte 8 16) val) stream)
  (write-byte (ldb (byte 8 24) val) stream)
  (write-byte (ldb (byte 8 32) val) stream)
  (write-byte (ldb (byte 8 40) val) stream)
  (write-byte (ldb (byte 8 48) val) stream)
  (write-byte (ldb (byte 8 56) val) stream))

;; Write 32-bit unsigned integer to stream (little-endian)
(defun write-u32-le (stream val)
  (declare (type (unsigned-byte 32) val)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  (write-byte (ldb (byte 8 0) val) stream)
  (write-byte (ldb (byte 8 8) val) stream)
  (write-byte (ldb (byte 8 16) val) stream)
  (write-byte (ldb (byte 8 24) val) stream))

(defun encode-rgb-to-exr (stream width height rgb-array &key alpha-array (pixel-type :half) (compression :zip) (num-threads (min 8 (detect-cores))) autocrop data-window comments metadata)
  "Encodes a flat 1D array of single-floats representing an RGB (or RGBA) image into an OpenEXR stream.

Arguments:
  STREAM       : The output binary stream to write the EXR payload into.
  WIDTH        : Integer width of the image.
  HEIGHT       : Integer height of the image.
  RGB-ARRAY    : A 1D simple-array of single-float elements of size (* width height 3).

Keyword Arguments:
  ALPHA-ARRAY  : Optional 1D simple-array of single-float elements of size (* width height) for the alpha channel.
  PIXEL-TYPE   : Representation format. Supported values:
                 - :HALF  (16-bit half-precision float, standard default)
                 - :FLOAT (32-bit single-precision float)
  COMPRESSION  : Compression scheme. Supported values:
                 - :ZIPS (Single scanline Zlib deflate, best for random-access scanline readers)
                 - :ZIP  (16 scanline block Zlib deflate, better compression ratio)
  NUM-THREADS  : Number of worker threads to spawn for parallel block compression.
                 Defaults to the dynamic CPU core count.
  AUTOCROP     : If T, computes and writes an optimal Data Window based on alpha or positive RGB pixels.
  DATA-WINDOW  : A sequence/vector of 4 integers representing custom [xmin ymin xmax ymax] Data Window bounds.
  COMMENTS     : Optional string text comments to inject into EXR header metadata.

This encoder leverages bordeaux-threads for lock-free parallel Zlib compression blocks and conforms strictly to the OpenEXR format specification."
  (declare (type fixnum width height num-threads)
           (type (simple-array single-float (*)) rgb-array)
           (type (or null (simple-array single-float (*))) alpha-array)
           (type keyword pixel-type compression)
           (type (or null string) comments)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  
  ;; Determine exact Data Window bounds (dw-xmin, dw-ymin, dw-xmax, dw-ymax)
  (multiple-value-bind (dw-xmin dw-ymin dw-xmax dw-ymax)
      (cond
        ;; Auto-crop active
        (autocrop
         (compute-autocrop-bounds width height rgb-array alpha-array 0.001f0 8 t))
        ;; Custom Data Window provided
        (data-window
         (values (elt data-window 0) (elt data-window 1) (elt data-window 2) (elt data-window 3)))
        ;; Default: Entire Display canvas
        (t
         (values 0 0 (1- width) (1- height))))
    
    (declare (type fixnum dw-xmin dw-ymin dw-xmax dw-ymax))
    
    (let* ((has-alpha (if alpha-array t nil))
           (dw-height (1+ (- dw-ymax dw-ymin)))
           (rows-per-block (if (eq compression :zips) 1 16))
           (num-blocks (ceiling dw-height rows-per-block))
           (header (make-exr-header width height dw-xmin dw-ymin dw-xmax dw-ymax has-alpha pixel-type compression comments metadata))
           (compressed-payloads (make-array num-blocks))
           (threads nil)
           (blocks-per-thread (ceiling num-blocks num-threads)))
      (declare (type fixnum rows-per-block num-blocks blocks-per-thread dw-height)
               (type (vector (unsigned-byte 8)) header)
               (type simple-array compressed-payloads))
      
      ;; Warm up the compressor class in the main thread to prevent lazy CLOS initialization race conditions
      (make-instance 'salza2:zlib-compressor)
      ;; Spawn worker threads to compress cropped blocks in parallel
      (dotimes (t-idx num-threads)
        (let* ((b-start (* t-idx blocks-per-thread))
               (b-end (min num-blocks (* (1+ t-idx) blocks-per-thread))))
          (declare (type fixnum b-start b-end))
          (when (< b-start b-end)
            (push (bt:make-thread
                   (lambda ()
                     (sb-int:with-float-traps-masked (:overflow :underflow :inexact :invalid :divide-by-zero)
                       (let* ((dw-width (1+ (- dw-xmax dw-xmin)))
                              (bytes-per-val (if (eq pixel-type :half) 2 4))
                              (channels-count (if has-alpha 4 3))
                              (max-block-bytes (* dw-width bytes-per-val channels-count rows-per-block))
                              (u (make-array max-block-bytes :element-type '(unsigned-byte 8) :initial-element 0))
                              (i (make-array max-block-bytes :element-type '(unsigned-byte 8) :initial-element 0))
                              (d (make-array max-block-bytes :element-type '(unsigned-byte 8) :initial-element 0))
                              (state (make-comp-state))
                              (compressor (make-instance 'salza2:zlib-compressor
                                                         :callback (lambda (buf end)
                                                                     (declare (type (simple-array (unsigned-byte 8) (*)) buf)
                                                                              (type fixnum end))
                                                                     (incf (comp-state-size state) end)
                                                                     (push (subseq buf 0 end) (comp-state-chunks state))))))
                         (declare (type (simple-array (unsigned-byte 8) (*)) u i d))
                         (loop for b from b-start below b-end do
                           (let* ((y-start (+ dw-ymin (* b rows-per-block)))
                                  (block-rows (min rows-per-block (- (1+ dw-ymax) y-start)))
                                  (payload (process-block compressor state width dw-xmin dw-xmax y-start block-rows rgb-array alpha-array pixel-type u i d)))
                             (setf (aref compressed-payloads b) payload)))))))
                  threads))))
      
      ;; Join workers
      (dolist (th threads)
        (bt:join-thread th))
      
      ;; Write Header
      (write-sequence header stream)
      
      ;; Write Line Offset Table
      (let ((current-offset (+ (length header) (* num-blocks 8))))
        (declare (type (unsigned-byte 64) current-offset))
        (dotimes (b num-blocks)
          (write-u64-le stream current-offset)
          (let* ((payload (aref compressed-payloads b))
                 (payload-len (length payload)))
            (declare (type (simple-array (unsigned-byte 8) (*)) payload)
                     (type fixnum payload-len))
            (incf current-offset (+ 8 payload-len)))))
      
      ;; Write Compressed Blocks sequentially
      (dotimes (b num-blocks)
        (let* ((y-start (+ dw-ymin (* b rows-per-block)))
               (payload (aref compressed-payloads b))
               (payload-len (length payload)))
          (declare (type (simple-array (unsigned-byte 8) (*)) payload)
                   (type fixnum y-start payload-len))
          ;; Scanline block header: actual y coordinate in original coordinates
          (write-u32-le stream y-start)
          (write-u32-le stream payload-len)
          (write-sequence payload stream)))
      
      (force-output stream))))

(defun encode-single-channel-to-exr (stream width height data-array channel-name &key (pixel-type :half) (compression :zip) (num-threads (min 8 (detect-cores))) autocrop data-window comments)
  "Encodes a flat 1D array of single-floats representing a single channel into an OpenEXR stream.

Arguments:
  STREAM       : The output binary stream to write the EXR payload into.
  WIDTH        : Integer width of the image.
  HEIGHT       : Integer height of the image.
  DATA-ARRAY   : A 1D simple-array of single-float elements of size (* width height).
  CHANNEL-NAME : String identifier for the channel (e.g. \"Y\", \"Z\", \"depth\").

Keyword Arguments:
  PIXEL-TYPE   : Representation format. Supported values:
                 - :HALF  (16-bit half-precision float, standard default)
                 - :FLOAT (32-bit single-precision float)
  COMPRESSION  : Compression scheme. Supported values:
                 - :ZIPS (Single scanline Zlib deflate)
                 - :ZIP  (16 scanline block Zlib deflate)
  NUM-THREADS  : Number of worker threads to spawn for parallel block compression.
                 Defaults to the dynamic CPU core count.
  AUTOCROP     : If T, computes and writes an optimal Data Window.
  DATA-WINDOW  : A sequence/vector of 4 integers representing custom [xmin ymin xmax ymax] bounds.

This encoder leverages bordeaux-threads for parallelized compression blocks conforming to the OpenEXR spec."
  (declare (type fixnum width height num-threads)
           (type (simple-array single-float (*)) data-array)
           (type string channel-name)
           (type keyword pixel-type compression)
           (type (or null string) comments)
           (optimize (speed 3) (safety 0) (debug 0) (space 0)))
  
  ;; Determine exact Data Window bounds (dw-xmin, dw-ymin, dw-xmax, dw-ymax)
  (multiple-value-bind (dw-xmin dw-ymin dw-xmax dw-ymax)
      (cond
        (autocrop
         (compute-autocrop-bounds width height data-array nil 0.001f0 8 nil))
        (data-window
         (values (elt data-window 0) (elt data-window 1) (elt data-window 2) (elt data-window 3)))
        (t
         (values 0 0 (1- width) (1- height))))
    
    (declare (type fixnum dw-xmin dw-ymin dw-xmax dw-ymax))
    
    (let* ((dw-height (1+ (- dw-ymax dw-ymin)))
           (rows-per-block (if (eq compression :zips) 1 16))
           (num-blocks (ceiling dw-height rows-per-block))
           (header (make-exr-single-channel-header width height dw-xmin dw-ymin dw-xmax dw-ymax channel-name pixel-type compression comments))
           (compressed-payloads (make-array num-blocks))
           (threads nil)
           (blocks-per-thread (ceiling num-blocks num-threads)))
      (declare (type fixnum rows-per-block num-blocks blocks-per-thread dw-height)
               (type (vector (unsigned-byte 8)) header)
               (type simple-array compressed-payloads))
      
      ;; Warm up the compressor class in the main thread to prevent lazy CLOS initialization race conditions
      (make-instance 'salza2:zlib-compressor)
      ;; Spawn worker threads to compress blocks in parallel
      (dotimes (t-idx num-threads)
        (let* ((b-start (* t-idx blocks-per-thread))
               (b-end (min num-blocks (* (1+ t-idx) blocks-per-thread))))
          (declare (type fixnum b-start b-end))
          (when (< b-start b-end)
            (push (bt:make-thread
                   (lambda ()
                     (sb-int:with-float-traps-masked (:overflow :underflow :inexact :invalid :divide-by-zero)
                       (let* ((dw-width (1+ (- dw-xmax dw-xmin)))
                              (bytes-per-val (if (eq pixel-type :half) 2 4))
                              (max-block-bytes (* dw-width bytes-per-val rows-per-block))
                              (u (make-array max-block-bytes :element-type '(unsigned-byte 8) :initial-element 0))
                              (i (make-array max-block-bytes :element-type '(unsigned-byte 8) :initial-element 0))
                              (d (make-array max-block-bytes :element-type '(unsigned-byte 8) :initial-element 0))
                              (state (make-comp-state))
                              (compressor (make-instance 'salza2:zlib-compressor
                                                         :callback (lambda (buf end)
                                                                     (declare (type (simple-array (unsigned-byte 8) (*)) buf)
                                                                              (type fixnum end))
                                                                     (incf (comp-state-size state) end)
                                                                     (push (subseq buf 0 end) (comp-state-chunks state))))))
                         (declare (type (simple-array (unsigned-byte 8) (*)) u i d))
                         (loop for b from b-start below b-end do
                           (let* ((y-start (+ dw-ymin (* b rows-per-block)))
                                  (block-rows (min rows-per-block (- (1+ dw-ymax) y-start)))
                                  (payload (process-single-channel-block compressor state width dw-xmin dw-xmax y-start block-rows data-array pixel-type u i d)))
                             (setf (aref compressed-payloads b) payload)))))))
                  threads))))
      
      (dolist (th threads)
        (bt:join-thread th))
      
      ;; Write Header
      (write-sequence header stream)
      
      ;; Write Line Offset Table
      (let ((current-offset (+ (length header) (* num-blocks 8))))
        (declare (type (unsigned-byte 64) current-offset))
        (dotimes (b num-blocks)
          (write-u64-le stream current-offset)
          (let* ((payload (aref compressed-payloads b))
                 (payload-len (length payload)))
            (declare (type (simple-array (unsigned-byte 8) (*)) payload)
                     (type fixnum payload-len))
            (incf current-offset (+ 8 payload-len)))))
      
      ;; Write Compressed Blocks sequentially
      (dotimes (b num-blocks)
        (let* ((y-start (+ dw-ymin (* b rows-per-block)))
               (payload (aref compressed-payloads b))
               (payload-len (length payload)))
          (declare (type (simple-array (unsigned-byte 8) (*)) payload)
                   (type fixnum y-start payload-len))
          (write-u32-le stream y-start)
          (write-u32-le stream payload-len)
          (write-sequence payload stream)))
      
      (force-output stream))))
