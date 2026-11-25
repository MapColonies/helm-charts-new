# make test: run tests/*.sh in name order. They render a copy of the chart without its
# dependencies, so no registry access or helm dependency build is needed.

.PHONY: test

test:
	for t in tests/*.sh; do $$t || exit 1; done
