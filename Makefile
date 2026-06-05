# Makefile for rawtohdri

VERSION := $(shell grep :version rawtohdri.asd | cut -d '"' -f 2)
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man/man1

.PHONY: all clean test install uninstall

all: bin/rawtohdri

.qlot/setup.lisp: qlfile
	qlot install

bin/rawtohdri: src/simple-exr.lisp src/libraw.lisp src/raw-to-hdri.lisp src/tui.lisp rawtohdri.asd .qlot/setup.lisp
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

install: bin/rawtohdri
	# Update version in the man page troff source to match ASDF version
	sed -i 's/\.TH RAWTOHDRI 1 \("[^"]*"\) \("[^"]*"\)/.TH RAWTOHDRI 1 \1 "v$(VERSION)"/' man/rawtohdri.1
	# Install binary
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 bin/rawtohdri $(DESTDIR)$(BINDIR)/rawtohdri
	# Install gzipped man page
	install -d $(DESTDIR)$(MANDIR)
	gzip -c man/rawtohdri.1 > $(DESTDIR)$(MANDIR)/rawtohdri.1.gz
	chmod 0644 $(DESTDIR)$(MANDIR)/rawtohdri.1.gz

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/rawtohdri
	rm -f $(DESTDIR)$(MANDIR)/rawtohdri.1.gz

clean:
	rm -rf bin/
