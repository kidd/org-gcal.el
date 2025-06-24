THIS_MAKEFILE_DIR = $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
EMACS ?= emacs
SRC=org-gcal.el org-generic-id.el
TEST=test/org-gcal-test.el test/org-generic-id-test.el
BUILD_LOG = build.log
CASK ?= cask
PKG_DIR := $(shell $(CASK) package-directory)
ELCFILES = $(SRC:.el=.elc)
.DEFAULT_GOAL := all

.PHONY: all clean load-path compile test elpa install

all: compile test

load-path:
	$(CASK) load-path

clean:
	rm -f $(ELCFILES) $(BUILD_LOG)
	rm -rf $(PKG_DIR)
	$(CASK) clean-elc

install: elpa
elpa: $(PKG_DIR)
$(PKG_DIR): Cask
	$(CASK) install
	touch $@

compile: $(SRC) $(TEST) elpa
	$(CASK) emacs -batch -L . -L test \
	  -f batch-byte-compile $$($(CASK) files) \
	  $(foreach test,$(TEST),$(addprefix $(THIS_MAKEFILE_DIR)/,$(test)))

test: $(SRC) $(TEST) elpa compile
	$(CASK) emacs --batch \
	-L $(THIS_MAKEFILE_DIR) \
	$(foreach test,$(TEST),$(addprefix -l $(THIS_MAKEFILE_DIR)/,$(test))) \
	-f ert-run-tests-batch-and-exit
