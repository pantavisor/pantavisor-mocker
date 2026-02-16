INSTALL_DIR := $(HOME)/.local/bin
BINARY := pantavisor-mocker
ZIG_OUT := zig-out/bin/$(BINARY)

.PHONY: build install uninstall

build:
	zig build -Doptimize=ReleaseSafe

install: build
	@mkdir -p $(INSTALL_DIR)
	@cp $(ZIG_OUT) $(INSTALL_DIR)/$(BINARY)
	@echo "Installed $(BINARY) to $(INSTALL_DIR)"
	@if echo "$$PATH" | tr ':' '\n' | grep -qx "$(INSTALL_DIR)"; then \
		echo "$(INSTALL_DIR) is already in PATH"; \
	else \
		RC_FILE=""; \
		if [ -n "$$ZSH_VERSION" ] || [ "$$SHELL" = "/bin/zsh" ] || [ "$$SHELL" = "/usr/bin/zsh" ]; then \
			RC_FILE="$(HOME)/.zshrc"; \
		elif [ -f "$(HOME)/.bashrc" ]; then \
			RC_FILE="$(HOME)/.bashrc"; \
		elif [ -f "$(HOME)/.profile" ]; then \
			RC_FILE="$(HOME)/.profile"; \
		fi; \
		if [ -n "$$RC_FILE" ]; then \
			echo 'export PATH="$$HOME/.local/bin:$$PATH"' >> "$$RC_FILE"; \
			echo "Added $(INSTALL_DIR) to PATH in $$RC_FILE"; \
			echo "Run 'source $$RC_FILE' or restart your shell to apply"; \
		else \
			echo "WARNING: Could not detect shell rc file."; \
			echo "Manually add $(INSTALL_DIR) to your PATH."; \
		fi; \
	fi

uninstall:
	@rm -f $(INSTALL_DIR)/$(BINARY)
	@echo "Removed $(BINARY) from $(INSTALL_DIR)"
