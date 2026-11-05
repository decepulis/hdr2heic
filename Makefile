PREFIX ?= $(HOME)/.local

hdr2heic: hdr2heic.swift
	swiftc -O hdr2heic.swift -o hdr2heic

install: hdr2heic
	mkdir -p $(PREFIX)/bin
	cp hdr2heic $(PREFIX)/bin/hdr2heic

clean:
	rm -f hdr2heic

.PHONY: install clean
