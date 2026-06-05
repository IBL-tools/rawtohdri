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

(defun float-approx-equal (a b &optional (epsilon 1.0f-4))
  (<= (abs (- a b)) epsilon))

(defun test-stack-images ()
  (format t "Testing stack-images...~%")
  (let* ((bg (make-array 3 :element-type '(unsigned-byte 16) :initial-contents '(32768 32768 32768)))
         (fg (make-array 3 :element-type '(unsigned-byte 16) :initial-contents '(49151 49151 49151)))
         ;; Stacking bg and fg:
         ;; bg normalized = 32768 / 65535.0 = 0.5000076f0
         ;; fg normalized = 49151 / 65535.0 = 0.7499962f0
         ;; ev-step = 3.0f0 -> exposure-factor = 0.125f0
         ;; lo = 0.7f0, hi = 0.8f0
         ;; matte = (0.8 - 0.7499962) / 0.1 = 0.500038f0
         ;; output[i] = bg[i] * (1 - matte) + fg[i] * exposure-factor * matte
         ;;           = 0.5000076 * 0.499962 + 0.7499962 * 0.125 * 0.500038
         ;;           = 0.2499848 + 0.0468785 = 0.2968633f0
         ;; Then global scale factor is applied based on center:
         ;; center = 2 -> (1- center) = 1 -> center-factor = expt(2, 3.0f0) = 8.0f0
         ;; final value = 0.2968633 * 8 = 2.374906f0
         (result (raw-to-hdri::stack-images (list bg fg) 3.0f0 0.7f0 0.8f0 2)))
    (assert (float-approx-equal (aref result 0) 2.375f0))
    (assert (float-approx-equal (aref result 1) 2.375f0))
    (assert (float-approx-equal (aref result 2) 2.375f0)))
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
