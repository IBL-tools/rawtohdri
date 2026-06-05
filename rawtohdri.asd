;;;; rawtohdri.asd - ASDF system definition for rawtohdri

(asdf:defsystem #:rawtohdri
  :description "Pure in-memory parallel camera raw stacker to OpenEXR"
  :author "Aaron Estrada"
  :license "MIT"
  :version "1.1.0"
  :depends-on (#:cffi #:bordeaux-threads #:salza2 #:sb-simd #:tuition)
  :serial t
  :components ((:module "src"
                :components
                ((:file "simple-exr")
                 (:file "libraw")
                 (:file "raw-to-hdri")
                 (:file "tui"))))
  :build-operation "program-op"
  :build-pathname "bin/rawtohdri"
  :entry-point "raw-to-hdri:main")

#+sbcl
(defmethod asdf:perform ((o asdf:image-op) (c (eql (asdf:find-system :rawtohdri))))
  (sb-ext:save-lisp-and-die (asdf:output-file o c)
                            :executable t
                            :toplevel (uiop:ensure-function (asdf/system::component-entry-point c))
                            :save-runtime-options t
                            :purify t
                            :compression 9))

