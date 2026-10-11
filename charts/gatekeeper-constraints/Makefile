# Chart tests: render the chart with the test values and evaluate the rendered
# ConstraintTemplates and Constraints with gator against sample objects.
#
#   make test     run every gator Suite under tests/suites
#
# gator is pinned to the upstream Gatekeeper version this chart wraps.
# It is downloaded into .bin/ unless GATOR points at an existing binary.

GATOR_VERSION ?= v3.22.0
GATOR ?= $(CURDIR)/.bin/gator
RELEASE := gatekeeper-constraints
RENDER_DIR := tests/rendered
TEST_VALUES := tests/values.yaml

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: test render clean

test: render $(GATOR)
	cd tests && $(GATOR) verify ./suites/...

render:
	ls charts/*.tgz > /dev/null 2>&1 || helm dependency build .
	rm -rf $(RENDER_DIR)
	helm template $(RELEASE) . -f $(TEST_VALUES) --output-dir $(RENDER_DIR) > /dev/null

$(CURDIR)/.bin/gator:
	mkdir -p $(@D)
	curl -sSfL https://github.com/open-policy-agent/gatekeeper/releases/download/$(GATOR_VERSION)/gator-$(GATOR_VERSION)-$(OS)-$(ARCH).tar.gz \
		| tar -xz -C $(@D) gator

clean:
	rm -rf .bin $(RENDER_DIR)
