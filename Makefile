NVIM ?= nvim

.PHONY: test test-e2e unit health lint trace clean

# Launch Neovim with the minimal test config (interactive)
test:
	$(NVIM) -u tests/minimal_init.lua

# Run the fast headless unit + property test suite (zero external deps).
unit:
	$(NVIM) --headless -l tests/unit/run.lua

# Run the end-to-end test suite (tmux-driven)
test-e2e:
	bash tests/e2e/run_all.sh

# Spec-traceability gate: assert every requirement maps to a passing test
trace:
	$(NVIM) --headless -l tests/traceability.lua

# Run health check in headless mode
health:
	$(NVIM) -u tests/minimal_init.lua --headless -c 'checkhealth code-review' -c 'w! /dev/stderr | qa!'

# Lint with luacheck (install: luarocks install luacheck)
lint:
	luacheck lua/ plugin/ --no-unused-args --no-max-line-length

# Remove test dependencies
clean:
	rm -rf .tests/
