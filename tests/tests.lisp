;;;; tests/tests.lisp - Unit tests for rawtohdri

(in-package :cl-user)

(defpackage :raw-to-hdri-tests
  (:use :cl)
  (:export #:run-tests))

(in-package :raw-to-hdri-tests)

(defun test-ev-to-exposure-factor ()
  (format t "Testing ev-to-exposure-factor...~%")
  (assert (= (raw-to-hdri::ev-to-exposure-factor 0.0f0) 1.0f0))
  (assert (= (raw-to-hdri::ev-to-exposure-factor 3.0f0) 0.125f0))
  (assert (= (raw-to-hdri::ev-to-exposure-factor -3.0f0) 8.0f0))
  (format t "  ev-to-exposure-factor passed.~%"))

(defun test-luma-clip ()
  (format t "Testing luma-clip...~%")
  (assert (= (raw-to-hdri::luma-clip 0.9f0 0.7f0 0.8f0) 0.0f0))
  (assert (= (raw-to-hdri::luma-clip 0.6f0 0.7f0 0.8f0) 1.0f0))
  (assert (= (raw-to-hdri::luma-clip 0.75f0 0.7f0 0.8f0) 0.5f0))
  (format t "  luma-clip passed.~%"))

(defun test-format-shutter ()
  (format t "Testing format-shutter...~%")
  (assert (string= (raw-to-hdri::format-shutter 0.0004f0) "1/2500 sec"))
  (assert (string= (raw-to-hdri::format-shutter 0.25f0) "1/4 sec"))
  (assert (string= (raw-to-hdri::format-shutter 2.0f0) "2.0 sec"))
  (format t "  format-shutter passed.~%"))

(defun test-format-unix-timestamp ()
  (format t "Testing format-unix-timestamp...~%")
  ;; 1305945194 is Sat May 21 02:33:14 2011 UTC
  (assert (string= (raw-to-hdri::format-unix-timestamp 1305945194)
                   "Sat May 21 02:33:14 2011"))
  (format t "  format-unix-timestamp passed.~%"))

(defun test-stack-images ()
  (format t "Testing stack-images...~%")
  (let* ((bg (make-array 3 :element-type 'single-float :initial-contents '(0.5f0 0.5f0 0.5f0)))
         (fg (make-array 3 :element-type 'single-float :initial-contents '(0.75f0 0.75f0 0.75f0)))
         ;; Stacking bg and fg:
         ;; ev-step = 3.0f0 -> exposure-factor = 0.125f0
         ;; lo = 0.7f0, hi = 0.8f0
         ;; fg values are 0.75f0. matte = (0.8 - 0.75) / (0.8 - 0.7) = 0.5f0
         ;; For each pixel component:
         ;; output[i] = bg[i] * (1 - matte) + fg[i] * exposure-factor * matte
         ;;           = 0.5 * 0.5 + 0.75 * 0.125 * 0.5
         ;;           = 0.25 + 0.046875 = 0.296875f0
         ;; Then global scale factor is applied based on center:
         ;; center = 2 -> (1- center) = 1 -> center-factor = expt(2, 3.0f0) = 8.0f0
         ;; final value = 0.296875 * 8 = 2.375f0
         (result (raw-to-hdri::stack-images (list bg fg) 3.0f0 0.7f0 0.8f0 2)))
    (assert (= (aref result 0) 2.375f0))
    (assert (= (aref result 1) 2.375f0))
    (assert (= (aref result 2) 2.375f0)))
  (format t "  stack-images passed.~%"))

(defun run-tests ()
  (handler-bind ((error (lambda (c)
                          (format t "Test failed: ~A~%" c)
                          (sb-ext:exit :code 1))))
    (test-ev-to-exposure-factor)
    (test-luma-clip)
    (test-format-shutter)
    (test-format-unix-timestamp)
    (test-stack-images)
    (format t "ALL_TESTS_PASSED~%SUCCESS~%")))

(run-tests)
