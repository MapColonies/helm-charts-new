# make test:   render the consumer charts in tests/consumers and compare with tests/expected,
#              then check that tests/failures fail with the expected errors.
# make update: rewrite tests/expected from the current templates (review the diff before committing).

.PHONY: test update deps

test: deps
	tests/run.sh

update: deps
	tests/run.sh --update

# Always update: a file:// dependency is copied into the consumer, so it goes stale when the library changes.
deps:
	for consumer in tests/consumers/*/; do helm dependency update --skip-refresh $$consumer > /dev/null; done
