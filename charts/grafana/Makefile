# make test: render assertions in tests/*.sh (helm template, no cluster).

.PHONY: test

test:
	ls charts/*.tgz > /dev/null 2>&1 || helm dependency build .
	for t in tests/*.sh; do echo "== $$t"; bash $$t || exit 1; done
