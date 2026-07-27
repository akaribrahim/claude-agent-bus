.PHONY: test

# `make test` runs everything; `make test FILTER=locks` runs one file.
# The suite creates and destroys its own AGENTBUS_HOME, so it never touches the
# state of the sessions live on this machine.
test:
	@./tests/run.sh $(FILTER)
