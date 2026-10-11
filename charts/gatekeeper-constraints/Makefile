# Chart tests: render the chart with the test values and evaluate the rendered
# ConstraintTemplates and Constraints with gator against sample objects.
#
#   make test     run every gator Suite under tests/suites, every
#                 tests/gator-test/<case> (see tests/expect-gator-test.sh)
#                 and every tests/render-failures/<values> (see
#                 tests/expect-render-failure.sh)
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
	for case in tests/gator-test/*/; do GATOR=$(GATOR) tests/expect-gator-test.sh $$case || exit 1; done
	for values in tests/render-failures/*.yaml; do tests/expect-render-failure.sh $$values || exit 1; done

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
