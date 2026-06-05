;;;; src/tui.lisp - cl-tuition terminal user interface for rawtohdri
;;;; Part of the rawtohdri package.

(in-package :raw-to-hdri)

;;; Struct for file item information
(defstruct file-item
  name
  path
  directory-p
  size)

;;; Struct for representing a queued directory batch
(defstruct queued-batch-dir
  path
  chunks
  total-chunks)

;;; Message for background chunk completion
(tui:defmessage chunk-finished-msg
  ((chunk-idx :initarg :chunk-idx :accessor msg-chunk-idx)
   (total-chunks :initarg :total-chunks :accessor msg-total-chunks)
   (filename :initarg :filename :accessor msg-filename)
   (dec-sec :initarg :dec-sec :accessor msg-dec-sec)
   (stack-sec :initarg :stack-sec :accessor msg-stack-sec)
   (save-sec :initarg :save-sec :accessor msg-save-sec)
   (total-sec :initarg :total-sec :accessor msg-total-sec)
   (success :initarg :success :accessor msg-success)
   (error-msg :initarg :error-msg :accessor msg-error-msg :initform nil)))

;;; TUI Model
(defclass tui-model ()
  ((step :initform :browse :accessor tui-step)
   (current-dir :initform "" :initarg :current-dir :accessor tui-current-dir)
   (items :initform nil :accessor tui-items)
   (selected :initform 0 :accessor tui-selected)
   (scroll-offset :initform 0 :accessor tui-scroll-offset)
   (term-width :initform 80 :accessor tui-term-width)
   (term-height :initform 24 :accessor tui-term-height)
   
   ;; Interactive Settings (mirrors CLI options)
   (nest-mode :initform nil :accessor tui-nest-mode)
   (float-mode :initform nil :accessor tui-float-mode)
   (zip-mode :initform :zip :accessor tui-zip-mode)
   (chunk-size :initform 3 :accessor tui-chunk-size)
   (ev-spacing :initform 3.0f0 :accessor tui-ev-spacing)
   (threads :initform 0 :accessor tui-threads)
   
   ;; Queue of directories
   (queued-dirs :initform nil :accessor tui-queued-dirs)
   
   ;; Stacking process state
   (active-dir-idx :initform 0 :accessor tui-active-dir-idx)
   (active-chunks :initform nil :accessor tui-active-chunks)
   (active-chunk-idx :initform 0 :accessor tui-active-chunk-idx)
   (active-total-chunks :initform 0 :accessor tui-active-total-chunks)
   (total-processed-chunks :initform 0 :accessor tui-total-processed-chunks)
   (overall-total-chunks :initform 0 :accessor tui-overall-total-chunks)
   
   (args :initform nil :initarg :args :accessor tui-args)
   (logs :initform nil :accessor tui-logs)
   (spinner :initform (tui.spinner:make-spinner
                       :frames tui.spinner:*spinner-dot*
                       :fps 0.08)
            :accessor tui-spinner)
   (progress-dir :initform (tui.progress:make-progress
                            :width 35
                            :show-percentage t)
                 :accessor tui-progress-dir)
   (progress-overall :initform (tui.progress:make-progress
                                :width 35
                                :show-percentage t)
                     :accessor tui-progress-overall)
   (error-message :initform nil :accessor tui-error-message)))

;;; Helper for file size
(defun get-file-size (path)
  "Gets the size of a file in bytes."
  (handler-case
      (with-open-file (stream path
                              :direction :input
                              :if-does-not-exist nil
                              :element-type '(unsigned-byte 8))
        (when stream
          (file-length stream)))
    (error () nil)))

(defun format-size (bytes)
  "Formats bytes into a human-readable string."
  (cond
    ((null bytes) "---")
    ((< bytes 1024) (format nil "~DB" bytes))
    ((< bytes (* 1024 1024)) (format nil "~,1FKB" (/ bytes 1024.0)))
    ((< bytes (* 1024 1024 1024))
     (format nil "~,1FMB" (/ bytes (* 1024.0 1024))))
    (t (format nil "~,1FGB" (/ bytes (* 1024.0 1024 1024))))))

;;; Directory listing
(defun load-directory (path)
  "Returns sorted file-item list representing the directory contents."
  (handler-case
      (let* ((dir (uiop:directory-exists-p (uiop:ensure-directory-pathname path)))
             (subdirs (uiop:subdirectories dir))
             (files (uiop:directory-files dir))
             (items nil))
        ;; Parent dir entry
        (unless (or (string= (namestring dir) "/")
                    (string= (namestring dir) "./"))
          (let ((parent (uiop:pathname-parent-directory-pathname dir)))
            (when parent
              (push (make-file-item :name ".."
                                    :path (namestring parent)
                                    :directory-p t
                                    :size nil)
                    items))))
        ;; Add directories sorted
        (setf subdirs (sort subdirs #'string< :key #'namestring))
        (dolist (sub subdirs)
          (let* ((dir-list (pathname-directory sub))
                 (name (car (last dir-list))))
            (when (and name (not (char= (char name 0) #\.)))
              (push (make-file-item :name name
                                    :path (namestring sub)
                                    :directory-p t
                                    :size nil)
                    items))))
        (setf items (nreverse items))
        ;; Add files sorted
        (setf files (sort files #'string< :key #'namestring))
        (let ((file-items nil))
          (dolist (f files)
            (let ((name (file-namestring f)))
              (when (and name
                         (not (char= (char name 0) #\.))
                         (not (uiop:string-suffix-p (string-downcase name) ".exr")))
                (push (make-file-item :name name
                                      :path (namestring f)
                                      :directory-p nil
                                      :size (get-file-size f))
                      file-items))))
          (setf items (append items (nreverse file-items))))
        items)
    (error (c)
      (list (make-file-item
             :name (format nil "Error loading directory: ~A" c)
             :path ""
             :directory-p nil
             :size nil)))))

(defun adjust-scroll (model viewport-height)
  "Adjusts the scroll offset to keep the selected item visible."
  (let* ((selected (tui-selected model))
         (offset (tui-scroll-offset model))
         (num-items (length (tui-items model)))
         (max-offset (max 0 (- num-items viewport-height))))
    (cond
      ((< selected offset)
       (setf (tui-scroll-offset model) selected))
      ((>= selected (+ offset viewport-height))
       (setf (tui-scroll-offset model)
             (min max-offset (- selected viewport-height -1))))
      ((> offset max-offset)
       (setf (tui-scroll-offset model) max-offset)))))

;;; Stacking task command
(defun start-batch-chunk-cmd (model idx)
  "Returns a background command to process active chunk idx."
  (let* ((batch-dir (elt (tui-queued-dirs model) (1- (tui-active-dir-idx model))))
         (dir-path (queued-batch-dir-path batch-dir))
         (chunk (elt (tui-active-chunks model) (1- idx)))
         (total-in-dir (tui-active-total-chunks model))
         (args (tui-args model)))
    (lambda ()
      (handler-case
          (let ((t-start (get-internal-real-time))
                (rotate (cli-args-rotate args))
                (max-threads (tui-threads model))
                (ev (tui-ev-spacing model))
                (nest (tui-nest-mode model))
                (float-mode (tui-float-mode model))
                (zip-mode (tui-zip-mode model))
                (center (cli-args-center args))
                (lo (cli-args-lo args))
                (hi (cli-args-hi args))
                (output-basename (cli-args-output-basename args)))
            (let* ((out-dir (if nest
                                (namestring (ensure-directories-exist
                                             (merge-pathnames "exr/" dir-path)))
                                dir-path))
                   (decoded-images (decode-chunk chunk rotate max-threads))
                   (t-dec-end (get-internal-real-time))
                   (first-img (first decoded-images))
                   (width (decoded-image-width first-img))
                   (height (decoded-image-height first-img)))
              (dolist (img (rest decoded-images))
                (unless (and (= (decoded-image-width img) width)
                             (= (decoded-image-height img) height))
                  (error "Size mismatch in chunk: ~Ax~A vs ~Ax~A"
                         width height
                         (decoded-image-width img)
                         (decoded-image-height img))))
              (let* ((t-stack-start (get-internal-real-time))
                     (layers (mapcar #'decoded-image-data decoded-images))
                     (stacked-data (stack-images layers ev lo hi center))
                     (t-stack-end (get-internal-real-time))
                     (meta-img (elt decoded-images (1- center)))
                     (metadata (list (cons "camera" (decoded-image-camera meta-img))
                                     (cons "date" (decoded-image-date meta-img))
                                     (cons "iso" (decoded-image-iso meta-img))
                                     (cons "shutter" (decoded-image-shutter meta-img))
                                     (cons "aperture" (decoded-image-aperture meta-img))
                                     (cons "focal" (decoded-image-focal meta-img))))
                     (out-filename (format nil "~A~4,'0D" output-basename idx))
                     (out-pathname (merge-pathnames
                                    (make-pathname :name out-filename :type "exr")
                                    out-dir)))
                (with-open-file (out-stream out-pathname
                                            :direction :output
                                            :element-type '(unsigned-byte 8)
                                            :if-exists :supersede)
                  (exr:encode-rgb-to-exr
                   out-stream width height stacked-data
                   :pixel-type (if float-mode :float :half)
                   :compression zip-mode
                   :comments "Made with rawtohdri 1.0 (Lisp) by Aaron Estrada"
                   :metadata metadata))
                (let* ((t-save-end (get-internal-real-time))
                       (dec-sec (/ (coerce (- t-dec-end t-start) 'single-float)
                                   internal-time-units-per-second))
                       (stack-sec (/ (coerce (- t-stack-end t-stack-start) 'single-float)
                                     internal-time-units-per-second))
                       (save-sec (/ (coerce (- t-save-end t-stack-end) 'single-float)
                                    internal-time-units-per-second))
                       (total-sec (/ (coerce (- t-save-end t-start) 'single-float)
                                     internal-time-units-per-second)))
                  (make-instance 'chunk-finished-msg
                                 :chunk-idx idx
                                 :total-chunks total-in-dir
                                 :filename (file-namestring out-pathname)
                                 :dec-sec dec-sec
                                 :stack-sec stack-sec
                                 :save-sec save-sec
                                 :total-sec total-sec
                                 :success t)))))
        (error (c)
          (make-instance 'chunk-finished-msg
                         :chunk-idx idx
                         :total-chunks total-in-dir
                         :filename ""
                         :dec-sec 0.0f0
                         :stack-sec 0.0f0
                         :save-sec 0.0f0
                         :total-sec 0.0f0
                         :success nil
                         :error-msg (format nil "~A" c)))))))

(defun start-batch-processing (model)
  "Initializes the active directory from the queue."
  (let* ((batch-dir (elt (tui-queued-dirs model) (1- (tui-active-dir-idx model))))
         (chunks (queued-batch-dir-chunks batch-dir)))
    (setf (tui-active-chunks model) chunks
          (tui-active-chunk-idx model) 1
          (tui-active-total-chunks model) (length chunks))
    (tui.progress:progress-set-percent (tui-progress-dir model) 0.0)
    (tui:batch
     (tui.spinner:spinner-init (tui-spinner model))
     (start-batch-chunk-cmd model 1))))

(defun start-queue-stacking (model)
  "Starts batch processing of all queued directories."
  (let ((qd (tui-queued-dirs model)))
    (if qd
        (let ((batch-dirs nil)
              (overall-total 0))
          (dolist (dir-path (reverse qd))
            (let* ((files (get-sorted-files dir-path))
                   (chunks (group-by-chunks files (tui-chunk-size model)))
                   (total (length chunks)))
              (when (> total 0)
                (push (make-queued-batch-dir :path dir-path
                                             :chunks chunks
                                             :total-chunks total)
                      batch-dirs)
                (incf overall-total total))))
          (if (= overall-total 0)
              (progn
                (setf (tui-step model) :error
                      (tui-error-message model)
                      "No RAW images found in queued directories.")
                (values model nil))
              (progn
                (setf (tui-step model) :processing
                      (tui-queued-dirs model) (nreverse batch-dirs)
                      (tui-active-dir-idx model) 1
                      (tui-total-processed-chunks model) 0
                      (tui-overall-total-chunks model) overall-total)
                (tui.progress:progress-set-percent (tui-progress-overall model) 0.0)
                (values model (start-batch-processing model)))))
        (values model nil))))

(defmethod tui:init ((model tui-model))
  (let ((size (tui:get-terminal-size)))
    (when size
      (setf (tui-term-width model) (car size)
            (tui-term-height model) (cdr size))))
  ;; Set initial directory
  (let ((init-path (or (tui-current-dir model) (namestring (uiop:getcwd)))))
    (setf (tui-current-dir model)
          (namestring (uiop:ensure-directory-pathname init-path)))
    (setf (tui-items model) (load-directory (tui-current-dir model)))
    (setf (tui-selected model) 0
          (tui-scroll-offset model) 0))
  nil)

(defmethod tui:update-message ((model tui-model) (msg tui:window-size-msg))
  (setf (tui-term-width model) (tui:window-size-msg-width msg)
        (tui-term-height model) (tui:window-size-msg-height msg))
  (values model nil))

(defmethod tui:update-message ((model tui-model) (msg tui:key-press-msg))
  (let ((key (tui:key-event-code msg))
        (ctrl (tui:mod-contains (tui:key-event-mod msg) tui:+mod-ctrl+)))
    (cond
      ((and ctrl (characterp key) (char= key #\c))
       (values model (tui:quit-cmd)))
      ((eq key :escape)
       (values model (tui:quit-cmd)))
      ((and (member (tui-step model) '(:done :error))
            (or (eq key :enter) (eq key #\q) (eq key #\Q)))
       (values model (tui:quit-cmd)))
      ((eq (tui-step model) :browse)
       (cond
         ((or (eq key :up) (and (characterp key) (char= key #\k)))
          (when (> (tui-selected model) 0)
            (decf (tui-selected model)))
          (values model nil))
         ((or (eq key :down) (and (characterp key) (char= key #\j)))
          (when (< (tui-selected model) (1- (length (tui-items model))))
            (incf (tui-selected model)))
          (values model nil))
         ((eq key :enter)
          (let ((item (nth (tui-selected model) (tui-items model))))
            (when (and item (file-item-directory-p item))
              (setf (tui-current-dir model) (file-item-path item))
              (setf (tui-items model) (load-directory (tui-current-dir model)))
              (setf (tui-selected model) 0
                    (tui-scroll-offset model) 0)))
          (values model nil))
         ((or (eq key :backspace) (and (characterp key) (char= key #\h)))
          (let ((parent (uiop:pathname-parent-directory-pathname
                         (uiop:ensure-directory-pathname (tui-current-dir model)))))
            (when parent
              (setf (tui-current-dir model) (namestring parent))
              (setf (tui-items model) (load-directory (tui-current-dir model)))
              (setf (tui-selected model) 0
                    (tui-scroll-offset model) 0)))
          (values model nil))
         ((and (characterp key) (char= key #\n))
          (setf (tui-nest-mode model) (not (tui-nest-mode model)))
          (values model nil))
         ((and (characterp key) (char= key #\f))
          (setf (tui-float-mode model) (not (tui-float-mode model)))
          (values model nil))
         ((and (characterp key) (char= key #\z))
          (setf (tui-zip-mode model)
                (if (eq (tui-zip-mode model) :zip) :zips :zip))
          (values model nil))
         ((and (characterp key) (char= key #\c))
          (setf (tui-chunk-size model)
                (case (tui-chunk-size model)
                  (2 3) (3 4) (4 5) (5 6) (6 7) (7 8) (8 2) (t 3)))
          (values model nil))
         ((and (characterp key) (char= key #\C))
          (setf (tui-chunk-size model)
                (case (tui-chunk-size model)
                  (2 8) (3 2) (4 3) (5 4) (6 5) (7 6) (8 7) (t 3)))
          (values model nil))
         ((and (characterp key) (char= key #\e))
          (setf (tui-ev-spacing model)
                (cond
                  ((= (tui-ev-spacing model) 1.0f0) 1.5f0)
                  ((= (tui-ev-spacing model) 1.5f0) 2.0f0)
                  ((= (tui-ev-spacing model) 2.0f0) 2.5f0)
                  ((= (tui-ev-spacing model) 2.5f0) 3.0f0)
                  ((= (tui-ev-spacing model) 3.0f0) 4.0f0)
                  (t 1.0f0)))
          (values model nil))
         ((and (characterp key) (char= key #\E))
          (setf (tui-ev-spacing model)
                (cond
                  ((= (tui-ev-spacing model) 1.0f0) 4.0f0)
                  ((= (tui-ev-spacing model) 1.5f0) 1.0f0)
                  ((= (tui-ev-spacing model) 2.0f0) 1.5f0)
                  ((= (tui-ev-spacing model) 2.5f0) 2.0f0)
                  ((= (tui-ev-spacing model) 3.0f0) 2.5f0)
                  (t 3.0f0)))
          (values model nil))
         ((and (characterp key) (char= key #\t))
          (setf (tui-threads model)
                (case (tui-threads model)
                  (0 1) (1 2) (2 4) (4 8) (8 12) (12 16) (16 0) (t 0)))
          (values model nil))
         ((and (characterp key) (char= key #\T))
          (setf (tui-threads model)
                (case (tui-threads model)
                  (0 16) (1 0) (2 1) (4 2) (8 4) (12 8) (16 12) (t 0)))
          (values model nil))
         ((and (characterp key) (char= key #\a))
          (let* ((item (nth (tui-selected model) (tui-items model)))
                 (is-dir-p (and item
                                (file-item-directory-p item)
                                (not (string= (file-item-name item) ".."))))
                 (target-dir (if is-dir-p
                                 (file-item-path item)
                                 (tui-current-dir model))))
            (pushnew target-dir
                     (tui-queued-dirs model)
                     :test #'string=))
          (values model nil))
         ((and (characterp key) (char= key #\x))
          (setf (tui-queued-dirs model) nil)
          (values model nil))
         ((and (characterp key) (char= key #\s))
          (start-queue-stacking model))
         ((eq key #\Space)
          (let ((item (nth (tui-selected model) (tui-items model))))
            (when (and item
                       (file-item-directory-p item)
                       (not (string= (file-item-name item) "..")))
              (pushnew (file-item-path item)
                       (tui-queued-dirs model)
                       :test #'string=)))
          (values model nil))
         (t (values model nil))))
      (t (values model nil)))))

(defmethod tui:update-message ((model tui-model) (msg tui:mouse-click-msg))
  (let* ((x (tui:mouse-event-x msg))
         (y (tui:mouse-event-y msg))
         (v-y (1- y))
         (btn (tui:mouse-event-button msg)))
    (if (and (eq btn :left) (eq (tui-step model) :browse))
        (cond
          ;; Row 3: Settings Box Line 1
          ((= v-y 3)
           (cond
             ((< x 28) (setf (tui-nest-mode model) (not (tui-nest-mode model))))
             ((< x 55) (setf (tui-float-mode model) (not (tui-float-mode model))))
             (t (setf (tui-zip-mode model)
                      (if (eq (tui-zip-mode model) :zip) :zips :zip))))
           (values model nil))
          ;; Row 4: Settings Box Line 2
          ((= v-y 4)
           (cond
             ((< x 28)
              (setf (tui-chunk-size model)
                    (case (tui-chunk-size model)
                      (2 3) (3 4) (4 5) (5 6) (6 7) (7 8) (8 2) (t 3))))
             ((< x 55)
              (setf (tui-ev-spacing model)
                    (cond
                      ((= (tui-ev-spacing model) 1.0f0) 1.5f0)
                      ((= (tui-ev-spacing model) 1.5f0) 2.0f0)
                      ((= (tui-ev-spacing model) 2.0f0) 2.5f0)
                      ((= (tui-ev-spacing model) 2.5f0) 3.0f0)
                      ((= (tui-ev-spacing model) 3.0f0) 4.0f0)
                      (t 1.0f0))))
             (t
              (setf (tui-threads model)
                    (case (tui-threads model)
                      (0 1) (1 2) (2 4) (4 8) (8 12) (12 16) (16 0) (t 0)))))
           (values model nil))
          ;; Browser Viewport Click
          ((let* ((vh (max 4 (- (tui-term-height model) 16))))
             (and (>= v-y 7) (< v-y (+ 7 vh))))
           (let ((clicked-idx (+ (tui-scroll-offset model) (- v-y 7))))
             (when (< clicked-idx (length (tui-items model)))
               (if (= clicked-idx (tui-selected model))
                   (let ((item (nth clicked-idx (tui-items model))))
                     (when (and item (file-item-directory-p item))
                       (setf (tui-current-dir model) (file-item-path item))
                       (setf (tui-items model)
                             (load-directory (tui-current-dir model)))
                       (setf (tui-selected model) 0
                             (tui-scroll-offset model) 0)))
                   (setf (tui-selected model) clicked-idx))))
           (values model nil))
          ;; Actions Line click at the bottom
          ((= v-y (1- (tui-term-height model)))
           (cond
             ((< x 24)
              (let* ((item (nth (tui-selected model) (tui-items model)))
                     (is-dir-p (and item
                                    (file-item-directory-p item)
                                    (not (string= (file-item-name item) ".."))))
                     (target-dir (if is-dir-p
                                     (file-item-path item)
                                     (tui-current-dir model))))
                (pushnew target-dir
                         (tui-queued-dirs model)
                         :test #'string=))
              (values model nil))
             ((< x 42)
              (setf (tui-queued-dirs model) nil)
              (values model nil))
             (t
              (start-queue-stacking model))))
          (t (values model nil)))
        (values model nil))))

(defmethod tui:update-message ((model tui-model) (msg tui:mouse-wheel-msg))
  (cond
    ((eq (tui:mouse-wheel-direction msg) :up)
     (when (> (tui-selected model) 0)
       (decf (tui-selected model)))
     (values model nil))
    ((eq (tui:mouse-wheel-direction msg) :down)
     (when (< (tui-selected model) (1- (length (tui-items model))))
       (incf (tui-selected model)))
     (values model nil))
    (t (values model nil))))

(defmethod tui:update-message ((model tui-model) (msg tui.spinner:spinner-tick-msg))
  (if (eq (tui-step model) :processing)
      (multiple-value-bind (new-spinner cmd)
          (tui.spinner:spinner-update (tui-spinner model) msg)
        (setf (tui-spinner model) new-spinner)
        (values model cmd))
      (values model nil)))

(defmethod tui:update-message ((model tui-model) (msg chunk-finished-msg))
  (let ((idx (msg-chunk-idx msg)))
    (if (msg-success msg)
        (progn
          (push (format nil "[Dir ~D] [~D/~D] ~A: Dec: ~,2fs | Stack: ~,2fs | Save: ~,2fs"
                        (tui-active-dir-idx model)
                        idx
                        (msg-total-chunks msg)
                        (msg-filename msg)
                        (msg-dec-sec msg)
                        (msg-stack-sec msg)
                        (msg-save-sec msg))
                (tui-logs model))
          (incf (tui-total-processed-chunks model))
          (incf (tui-active-chunk-idx model))
          ;; Set per-directory progress
          (tui.progress:progress-set-percent
           (tui-progress-dir model)
           (/ (coerce (1- (tui-active-chunk-idx model)) 'single-float)
              (coerce (tui-active-total-chunks model) 'single-float)))
          ;; Set overall progress
          (tui.progress:progress-set-percent
           (tui-progress-overall model)
           (/ (coerce (tui-total-processed-chunks model) 'single-float)
              (coerce (tui-overall-total-chunks model) 'single-float)))
          (if (<= (tui-active-chunk-idx model) (tui-active-total-chunks model))
              (values model
                      (start-batch-chunk-cmd model (tui-active-chunk-idx model)))
              (if (< (tui-active-dir-idx model) (length (tui-queued-dirs model)))
                  (progn
                    (incf (tui-active-dir-idx model))
                    (values model (start-batch-processing model)))
                  (progn
                    (setf (tui-step model) :done)
                    (values model nil)))))
        (progn
          (setf (tui-step model) :error
                (tui-error-message model) (msg-error-msg msg))
          (values model nil)))))

;;; View Box Drawing
(defun render-box (title content width)
  "Wraps content inside a borders-rounded box with a header title."
  (let* ((box-w (- width 2))
         (title-str (format nil "─ ~A ─" title))
         (title-len (length title-str))
         (top-border (format nil "┌~A~A┐"
                             title-str
                             (make-string (max 0 (- box-w title-len))
                                          :initial-element #\─)))
         (bottom-border (format nil "└~A┘"
                                (make-string box-w :initial-element #\─)))
         (lines (tui:split-string-by-newline content))
         (padded-lines (mapcar (lambda (line)
                                 (let* ((vis-len (tui:visible-length line))
                                        (padding (max 0 (- box-w vis-len))))
                                   (format nil "│~A~A│"
                                           line
                                           (make-string padding
                                                        :initial-element #\Space))))
                               lines)))
    (apply #'tui:join-vertical
           tui:+left+
           top-border
           (append padded-lines (list bottom-border)))))

;;; Content Generators
(defun render-settings-content (model)
  "Generates content for the Settings box."
  (let* ((n-chk (if (tui-nest-mode model) "[X]" "[ ]"))
         (f-chk (if (tui-float-mode model) "[X]" "[ ]"))
         (z-chk (if (eq (tui-zip-mode model) :zips) "[X]" "[ ]"))
         (c-val (tui-chunk-size model))
         (e-val (tui-ev-spacing model))
         (t-val (tui-threads model))
         (line1 (format nil "  [n] ~A Nest EXR   [f] ~A Save as FLOAT   [z] ~A ZIPS"
                        n-chk f-chk z-chk))
         (line2 (format nil "  [c] Chunk Size: ~D    [e] EV Spacing: ~,1Ff0   [t] Threads: ~D"
                        c-val e-val t-val)))
    (tui:join-vertical tui:+left+ line1 line2)))

(defun render-browser-content (model viewport-height)
  "Generates content for the File Browser box."
  (let* ((items (tui-items model))
         (offset (tui-scroll-offset model))
         (num-items (length items))
         (visible-count (min viewport-height (- num-items offset)))
         (visible-items (subseq items offset (+ offset visible-count)))
         (lines nil))
    (loop for item in visible-items
          for i from offset
          do (let* ((selected-p (= i (tui-selected model)))
                    (is-dir (file-item-directory-p item))
                    (icon (if is-dir "📁" "📄"))
                    (name (file-item-name item))
                    (queued-p (and is-dir
                                   (member (file-item-path item)
                                           (tui-queued-dirs model)
                                           :test #'string=)))
                    (suffix (cond
                              (queued-p (tui:colored " [Queued]"
                                                     :fg tui:*fg-bright-green*))
                              (is-dir "")
                              (t (format nil " (~A)"
                                         (format-size (file-item-size item))))))
                    (line-text (format nil " ~A ~A~A" icon name suffix)))
               (push (if selected-p
                         (tui:colored (format nil ">~A" line-text)
                                      :fg tui:*fg-bright-cyan*)
                         (format nil " ~A" line-text))
                     lines)))
    (loop repeat (- viewport-height (length lines)) do (push "  " lines))
    (apply #'tui:join-vertical tui:+left+ (nreverse lines))))

(defun render-queue-content (model)
  "Generates content for the Queue box (strictly 7 lines)."
  (let* ((qd (tui-queued-dirs model))
         (lines nil)
         (item (nth (tui-selected model) (tui-items model)))
         (is-dir-p (and item
                        (file-item-directory-p item)
                        (not (string= (file-item-name item) ".."))))
         (add-label (if is-dir-p "Add Selected Dir" "Add Current Dir")))
    (if qd
        (progn
          (push " Queued Directories:" lines)
          (let ((count 0)
                (shown 0))
            (dolist (dir (reverse qd))
              (incf count)
              (when (<= count 3)
                (push (format nil "  ~D. ~A" count dir) lines)
                (incf shown)))
            (loop repeat (- 3 shown) do (push "  " lines))
            (if (> (length qd) 3)
                (push (format nil "  ... and ~D more" (- (length qd) 3)) lines)
                (push "  " lines))))
        (progn
          (push "  Queue is empty." lines)
          (push "  Select a directory and press SPACE to queue it," lines)
          (push "  or double-click/double-select a directory row." lines)
          (push "  " lines)
          (push "  " lines)))
    (push "  " lines)
    (push (format nil
                  "  [a] ~A   [x] Clear Queue   [s] Start Stacking (~D dirs)"
                  add-label
                  (length qd))
          lines)
    (apply #'tui:join-vertical tui:+left+ (nreverse lines))))

;;; Main View method
(defmethod tui:view ((model tui-model))
  (case (tui-step model)
    (:browse
     (let* ((width (tui-term-width model))
            (height (tui-term-height model))
            (vh (max 4 (- height 16))))
       (adjust-scroll model vh)
       (tui:make-view
        (tui:join-vertical
         tui:+left+
         (tui:colored (tui:bold "  RAW to HDRI Stacking Tool (TUI)  ")
                      :fg tui:*fg-cyan*)
         (render-box "Settings" (render-settings-content model) width)
         (render-box (format nil "File Browser: ~A" (tui-current-dir model))
                     (render-browser-content model vh)
                     width)
         (render-box "Queue" (render-queue-content model) width))
        :alt-screen t
        :mouse-mode :cell-motion)))
    (:processing
     (let* ((spin (tui.spinner:spinner-view (tui-spinner model)))
            (prog-dir-str (tui.progress:progress-view (tui-progress-dir model)))
            (prog-overall-str (tui.progress:progress-view
                               (tui-progress-overall model)))
            (active-dir (elt (tui-queued-dirs model)
                             (1- (tui-active-dir-idx model))))
            (dir-name (car (last (pathname-directory
                                  (uiop:ensure-directory-pathname
                                   (queued-batch-dir-path active-dir))))))
            (header (tui:join-vertical
                     tui:+left+
                     (tui:colored
                      (tui:bold "  Processing HDR Bracket Batches...  ")
                      :fg tui:*fg-bright-cyan*)
                     (format nil "  Directory ~D of ~D: ~A"
                             (tui-active-dir-idx model)
                             (length (tui-queued-dirs model))
                             dir-name)
                     "  "))
            (meters (tui:join-vertical
                     tui:+left+
                     (format nil "  Current Dir:  ~A  ~A" prog-dir-str spin)
                     (format nil "  Overall:      ~A" prog-overall-str)))
            (logs-title (tui:bold "  Speed Reports & Logs:"))
            (recent-logs (loop for log in (subseq (tui-logs model)
                                                  0 (min 5 (length (tui-logs model))))
                               collect (format nil "    ~A" log)))
            (footer "  Press ESC or Ctrl+C to abort processing."))
       (tui:make-view
        (apply #'tui:join-vertical
               tui:+left+
               header
               meters
               "  "
               logs-title
               (append recent-logs (list "  " footer)))
        :alt-screen t)))
    (:done
     (let* ((header (tui:join-vertical
                     tui:+left+
                     (tui:colored
                      (tui:bold "  Stacking Completed Successfully! 🎉  ")
                      :fg tui:*fg-green*)
                     "  "))
            (status-line (format nil "  Processed ~D directories (~D total chunks)."
                                 (length (tui-queued-dirs model))
                                 (tui-total-processed-chunks model)))
            (logs-title (tui:bold "  All Reports:"))
            (all-logs (loop for log in (reverse (tui-logs model))
                            collect (format nil "    ~A" log)))
            (footer (tui:colored "  Press ENTER or Q to exit."
                                 :fg tui:*fg-bright-yellow*)))
       (tui:make-view
        (apply #'tui:join-vertical
               tui:+left+
               header
               status-line
               "  "
               logs-title
               (append all-logs (list "  " footer)))
        :alt-screen t)))
    (:error
     (tui:make-view
      (tui:join-vertical
       tui:+left+
       (tui:colored (tui:bold "  Fatal Error Encountered! ❌  ") :fg tui:*fg-red*)
       "  "
       (format nil "  ~A" (tui-error-message model))
       "  "
       (tui:colored "  Press ENTER or Q to exit." :fg tui:*fg-bright-yellow*))
      :alt-screen t))))

(defun run-tui (args)
  "Runs the rawtohdri TUI."
  (let* ((input-dir (cli-args-input-dir args))
         (model (make-instance 'tui-model
                               :args args
                               :current-dir (or input-dir ""))))
    (let ((program (tui:make-program model)))
      (tui:run program))))
