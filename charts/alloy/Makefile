# make test: run the render tests (tests/*.sh), then the e2e tests (tests/*-e2e.sh), which run the
# rendered configs in the real Alloy binary. It matches the chart's appVersion; set ALLOY to use your own.

ALLOY_VERSION ?= $(shell sed -n 's/^appVersion: //p' Chart.yaml)
ALLOY ?= $(CURDIR)/.bin/alloy

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: test deps clean

test: deps $(ALLOY)
	for t in tests/*.sh; do \
		case $$t in *-e2e.sh) ALLOY=$(ALLOY) $$t ;; tests/lib.sh) continue ;; *) $$t ;; esac || exit 1; \
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

clean:
	rm -rf .bin
