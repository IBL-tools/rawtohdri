;;;; libraw.lisp - CFFI bindings for LibRaw library
;;;; Part of the rawtohdri package.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ql:quickload :cffi :silent t))

(defpackage :libraw
  (:use :cl)
  (:export #:with-libraw
           #:with-processed-image
           #:libraw-open-file
           #:libraw-unpack
           #:libraw-dcraw-process
           #:libraw-dcraw-make-mem-image
           #:libraw-strerror
           ;; Accessors
           #:get-sizes-height
           #:get-sizes-width
           #:get-idata-make
           #:get-idata-model
           #:get-other-iso-speed
           #:get-other-shutter
           #:get-other-aperture
           #:get-other-focal-len
           #:get-other-timestamp
           ;; Setters
           #:set-params-user-flip
           #:set-params-output-bps
           #:set-params-use-camera-wb
           #:set-params-gamm
           #:set-params-no-auto-bright
           #:set-params-half-size))

(in-package :libraw)

;; Define and load libraw
(cffi:define-foreign-library libraw
  (:unix (:or "libraw.so" "libraw.so.25"))
  (t (:default "libraw")))

(cffi:use-foreign-library libraw)

;; Foreign Function Definitions
(cffi:defcfun ("libraw_init" %libraw-init) :pointer
  (flags :uint))

(cffi:defcfun ("libraw_open_file" %libraw-open-file) :int
  (data :pointer)
  (filename :string))

(cffi:defcfun ("libraw_unpack" %libraw-unpack) :int
  (data :pointer))

(cffi:defcfun ("libraw_dcraw_process" %libraw-dcraw-process) :int
  (data :pointer))

(cffi:defcfun ("libraw_dcraw_make_mem_image" %libraw-dcraw-make-mem-image) :pointer
  (data :pointer)
  (errcode :pointer))

(cffi:defcfun ("libraw_recycle" %libraw-recycle) :void
  (data :pointer))

(cffi:defcfun ("libraw_close" %libraw-close) :void
  (data :pointer))

(cffi:defcfun ("libraw_dcraw_clear_mem" %libraw-dcraw-clear-mem) :void
  (img-ptr :pointer))

(cffi:defcfun ("libraw_strerror" %libraw-strerror) :string
  (errcode :int))

;; Resource Management Macros
(defmacro with-libraw ((handle-var) &body body)
  "Initializes a LibRaw context, binds it to HANDLE-VAR, and guarantees
proper disposal with libraw_close under unwind-protect."
  `(let ((,handle-var (%libraw-init 0)))
     (if (cffi:null-pointer-p ,handle-var)
         (error "Failed to initialize LibRaw context via libraw_init")
         (unwind-protect
              (progn ,@body)
           (%libraw-close ,handle-var)))))

(defmacro with-processed-image ((image-var handle-ptr) &body body)
  "Demosaics and extracts the raw image to memory, binds the structure pointer
to IMAGE-VAR, and guarantees freeing the C memory buffer under unwind-protect."
  (let ((err-var (gensym "ERR")))
    `(cffi:with-foreign-object (,err-var :int)
       (let ((,image-var (%libraw-dcraw-make-mem-image ,handle-ptr ,err-var)))
         (if (cffi:null-pointer-p ,image-var)
             (error "Failed to generate in-memory processed image: ~A"
                    (%libraw-strerror (cffi:mem-ref ,err-var :int)))
             (unwind-protect
                  (progn ,@body)
               (%libraw-dcraw-clear-mem ,image-var)))))))

;; High-level wrappers for operations that return status codes
(defun libraw-open-file (handle filename)
  (let ((ret (%libraw-open-file handle filename)))
    (unless (zerop ret)
      (error "libraw_open_file failed on ~S: ~A" filename (%libraw-strerror ret)))
    t))

(defun libraw-unpack (handle)
  (let ((ret (%libraw-unpack handle)))
    (unless (zerop ret)
      (error "libraw_unpack failed: ~A" (%libraw-strerror ret)))
    t))

(defun libraw-dcraw-process (handle)
  (let ((ret (%libraw-dcraw-process handle)))
    (unless (zerop ret)
      (error "libraw_dcraw_process failed: ~A" (%libraw-strerror ret)))
    t))

;; Offset-based Accessors for libraw_data_t
(defun get-sizes-height (ptr)
  (cffi:mem-ref ptr :ushort 12))

(defun get-sizes-width (ptr)
  (cffi:mem-ref ptr :ushort 14))

(defun get-idata-make (ptr)
  (cffi:foreign-string-to-lisp (cffi:inc-pointer ptr 196)))

(defun get-idata-model (ptr)
  (cffi:foreign-string-to-lisp (cffi:inc-pointer ptr 260)))

(defun set-params-user-flip (ptr val)
  (setf (cffi:mem-ref ptr :int 5444) val))

(defun set-params-output-bps (ptr val)
  (setf (cffi:mem-ref ptr :int 5432) val))

(defun set-params-use-camera-wb (ptr val)
  (setf (cffi:mem-ref ptr :int 5384) val))

(defun set-params-gamm (ptr gamma-values)
  (let ((gamm-ptr (cffi:inc-pointer ptr 5296)))
    (dotimes (i 6)
      (setf (cffi:mem-aref gamm-ptr :double i) (coerce (elt gamma-values i) 'double-float)))))

(defun set-params-no-auto-bright (ptr val)
  (setf (cffi:mem-ref ptr :int 5488) val))

(defun set-params-half-size (ptr val)
  (setf (cffi:mem-ref ptr :int 5368) val))

(defun get-other-iso-speed (ptr)
  (cffi:mem-ref ptr :float 192680))

(defun get-other-shutter (ptr)
  (cffi:mem-ref ptr :float 192684))

(defun get-other-aperture (ptr)
  (cffi:mem-ref ptr :float 192688))

(defun get-other-focal-len (ptr)
  (cffi:mem-ref ptr :float 192692))

(defun get-other-timestamp (ptr)
  (cffi:mem-ref ptr :int64 192696))
