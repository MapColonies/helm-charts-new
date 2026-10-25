# make test: render the chart with tests/values.yaml, then run tests/suites,
# tests/gator-test, tests/render-failures, tests/deploy-alerts.sh and the daily report
# tests (tests/daily-report.sh, tests/daily-report/).
# make daily-report-fixtures: rewrite tests/daily-report/fixtures (parity.sh fails when stale).
# gator matches the wrapped Gatekeeper version; set GATOR to use your own binary.

GATOR_VERSION ?= v3.22.0
GATOR ?= $(CURDIR)/.bin/gator
RELEASE := gatekeeper-constraints
RENDER_DIR := tests/rendered
TEST_VALUES := tests/values.yaml

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: test render clean daily-report-fixtures

test: render $(GATOR)
	cd tests && $(GATOR) verify ./suites/...
	for case in tests/gator-test/*/; do GATOR=$(GATOR) tests/expect-gator-test.sh $$case || exit 1; done
	for values in tests/render-failures/*.yaml; do tests/expect-render-failure.sh $$values || exit 1; done
	tests/deploy-alerts.sh
	tests/daily-report.sh
	python3 -I -B -m unittest discover -s tests/daily-report -t tests/daily-report
	GATOR=$(GATOR) tests/daily-report/parity.sh
	GATOR=$(GATOR) tests/daily-report/job-pod.sh

daily-report-fixtures: $(GATOR)
	tests/daily-report/make-fixtures.sh $(GATOR) tests/daily-report/fixtures

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
