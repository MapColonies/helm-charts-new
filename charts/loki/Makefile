# make test: run tests/*.sh in name order. They render a copy of the chart without its
# dependencies, so no registry access or helm dependency build is needed.
# tests/dashboard-queries.sh evaluates dashboard queries with promtool; set PROMTOOL to use your own.

PROMETHEUS_VERSION ?= v3.15.0
PROMTOOL ?= $(CURDIR)/.bin/promtool

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: test clean

test: $(PROMTOOL)
	for t in tests/*.sh; do PROMTOOL=$(PROMTOOL) $$t || exit 1; done

$(CURDIR)/.bin/promtool:
	mkdir -p $(@D)
	curl -sSfL https://github.com/prometheus/prometheus/releases/download/$(PROMETHEUS_VERSION)/prometheus-$(PROMETHEUS_VERSION:v%=%).$(OS)-$(ARCH).tar.gz \
		| tar -xz -C $(@D) --strip-components=1 prometheus-$(PROMETHEUS_VERSION:v%=%).$(OS)-$(ARCH)/promtool

clean:
	rm -rf .bin
