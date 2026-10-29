# make test: run the render tests (tests/*.sh), then the e2e tests (tests/*-e2e.sh), which run the
# rendered configs in the real Alloy binary. It matches the chart's appVersion; set ALLOY to use your own.
# tests/alert-rules.sh evaluates the alert expressions with promtool; set PROMTOOL to use your own.

ALLOY_VERSION ?= $(shell sed -n 's/^appVersion: //p' Chart.yaml)
ALLOY ?= $(CURDIR)/.bin/alloy
PROMETHEUS_VERSION ?= v3.15.0
PROMTOOL ?= $(CURDIR)/.bin/promtool

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: test deps clean

test: deps $(ALLOY) $(PROMTOOL)
	for t in tests/*.sh; do \
		case $$t in tests/lib.sh) continue ;; esac; \
		ALLOY=$(ALLOY) PROMTOOL=$(PROMTOOL) $$t || exit 1; \
	done

deps:
	ls charts/*.tgz > /dev/null 2>&1 || helm dependency build .

$(CURDIR)/.bin/alloy:
	mkdir -p $(@D)
	curl -sSfL https://github.com/grafana/alloy/releases/download/$(ALLOY_VERSION)/alloy-$(OS)-$(ARCH).zip -o $(@D)/alloy.zip
	unzip -q -o $(@D)/alloy.zip -d $(@D)
	mv $(@D)/alloy-$(OS)-$(ARCH) $@
	chmod +x $@
	rm $(@D)/alloy.zip

$(CURDIR)/.bin/promtool:
	mkdir -p $(@D)
	curl -sSfL https://github.com/prometheus/prometheus/releases/download/$(PROMETHEUS_VERSION)/prometheus-$(PROMETHEUS_VERSION:v%=%).$(OS)-$(ARCH).tar.gz \
		| tar -xz -C $(@D) --strip-components=1 prometheus-$(PROMETHEUS_VERSION:v%=%).$(OS)-$(ARCH)/promtool

clean:
	rm -rf .bin
