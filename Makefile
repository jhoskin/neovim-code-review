NVIM ?= nvim

.PHONY: test health lint clean

# Launch Neovim with the minimal test config
test:
	$(NVIM) -u tests/minimal_init.lua

# Run health check in headless mode
health:
	$(NVIM) -u tests/minimal_init.lua --headless -c 'checkhealth code-review' -c 'w! /dev/stderr | qa!'

# Lint with luacheck (install: luarocks install luacheck)
lint:
	luacheck lua/ plugin/ --no-unused-args --no-max-line-length

# Remove test dependencies
clean:
	rm -rf .tests/
