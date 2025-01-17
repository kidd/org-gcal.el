THIS_MAKEFILE_DIR = $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

export EMACS ?= emacs

.PHONY: cask
cask:
	cask install
	@touch cask

.PHONY: compile
compile: cask
	cask emacs -batch -L . -L test \
          --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $$(cask files); \
	  (ret=$$? ; cask clean-elc && exit $$ret)

test: $(SRC) $(TEST) elpa
	$(CASK) exec ert-runner -L $(THIS_MAKEFILE_DIR) \
		$(foreach test,$(TEST),$(addprefix $(THIS_MAKEFILE_DIR)/,$(test)))
