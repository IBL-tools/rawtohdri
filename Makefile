# Makefile for rawtohdri

.PHONY: all clean test

all: bin/rawtohdri

.qlot/setup.lisp: qlfile
	qlot install

bin/rawtohdri: src/simple-exr.lisp src/libraw.lisp src/raw-to-hdri.lisp rawtohdri.asd .qlot/setup.lisp
	mkdir -p bin
	qlot exec sbcl --noinform --non-interactive \
		--load .qlot/setup.lisp \
		--eval "(asdf:load-system :rawtohdri)" \
		--eval "(sb-ext:save-lisp-and-die \"bin/rawtohdri\" :executable t :toplevel 'raw-to-hdri:main :save-runtime-options t :purify t :compression 9)"

test: .qlot/setup.lisp
	qlot exec sbcl --noinform --non-interactive \
		--load .qlot/setup.lisp \
		--eval "(asdf:load-system :rawtohdri)" \
		--load "tests/tests.lisp"

clean:
	rm -rf bin/
