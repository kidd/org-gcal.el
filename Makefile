THIS_MAKEFILE_DIR = $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
EMACS ?= emacs
SRC=org-gcal.el org-generic-id.el aio-iter2.el oauth2-auto.el
TEST=test/org-gcal-test.el test/org-generic-id-test.el
BUILD_LOG = build.log
CASK ?= cask
PKG_DIR := $(shell $(CASK) package-directory)
ELCFILES = $(SRC:.el=.elc)
.DEFAULT_GOAL := all

.PHONY: all clean load-path compile test test-checkdoc test-ert elpa \
	update-aio-iter2 update-oauth2-auto

all: compile test

clean:
	rm -f $(ELCFILES) $(BUILD_LOG); rm -rf $(PKG_DIR)

elpa: $(PKG_DIR)
$(PKG_DIR): Cask
	$(CASK) install
	touch $@

compile: $(SRC) elpa
	$(CASK) build 2>&1 | tee $(BUILD_LOG); \
	! ( grep -E -e ':(Warning|Error):' $(BUILD_LOG) )

test: $(SRC) $(TEST) elpa
	$(CASK) exec ert-runner -L $(THIS_MAKEFILE_DIR) \
		$(foreach test,$(TEST),$(addprefix $(THIS_MAKEFILE_DIR)/,$(test))) \
		</dev/null  # Make any prompts for user input fail during tests

# Vendor aio-iter2 from my fork until aio-iter2 is added to MELPA.
update-aio-iter2:
	curl -o aio-iter2.el \
		https://raw.githubusercontent.com/telotortium/emacs-aio-iter2/master/aio-iter2.el

# Vendor oauth2-auto from my fork until oauth2-auto is added to MELPA.
update-oauth2-auto:
	curl -o oauth2-auto.el \
		https://raw.githubusercontent.com/telotortium/emacs-oauth2-auto/main/oauth2-auto.el
