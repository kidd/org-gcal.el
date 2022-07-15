THIS_MAKEFILE_DIR = $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
EMACS ?= emacs
SRC=org-gcal.el org-generic-id.el aio-iter2.el oauth2-auto.el
TEST=test/org-gcal-test.el test/org-generic-id-test.el
TEST_DEPS=test/org-gcal-test.el
TEST_HELPER=test/test-helper.el
TEST_PATTERN ?= '.*'
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

test: $(SRC) $(TEST) $(TEST_DEPS) $(TEST_HELPER) elpa
	# Collect output for running all tests at once. Use </dev/null to
	# ensure any input from user fails.
	test_pattern () { \
		set -x; \
		$(CASK) exec ert-runner --debug \
			-l $(addprefix $(THIS_MAKEFILE_DIR)/,$(TEST_HELPER)) \
			-L $(THIS_MAKEFILE_DIR) \
			-p "$$1" \
			$(foreach test,$(TEST),$(addprefix $(THIS_MAKEFILE_DIR)/,$(test))) \
			</dev/null; \
		rv=$$?; set +x; return $$rv; \
	}; \
	output=$$(test_pattern $(TEST_PATTERN) 2>&1); \
	ran_test=$$(echo "$$output" | grep -E '^Ran [0-9]+ test'); \
	if [ -z "$$ran_test" ]; then printf "Running tests failed. Output: %%s" "$$output"; exit 1; fi; \
	failed_tests=$$(echo "$$output" | awk '/^[0-9]+ unexpected results:$$/ { print_test = 1 } /^ *FAILED  */ { if (!print_test) { next; } sub("^ *FAILED  *", ""); print; }'); \
	if [ -z "$$failed_tests" ]; then exit 0; fi; \
	echo "*** Failed tests - now rerunning individually:" $$failed_tests; echo; \
	rv=0; \
	final_failed_tests=""; \
	for test in $$failed_tests; do if ! test_pattern "$$test"; then final_failed_tests="$$final_failed_tests $$test"; rv=$$?; fi; done; \
	if [ -z "$$final_failed_tests" -a $$rv -eq 0 ]; then echo "*** Final success"; exit 0; fi; \
	echo "*** Final failed tests:" $$final_failed_tests; \
	exit $$rv

# Vendor aio-iter2 from my fork until aio-iter2 is added to MELPA.
update-aio-iter2:
	curl -o aio-iter2.el \
		https://raw.githubusercontent.com/telotortium/emacs-aio-iter2/master/aio-iter2.el

# Vendor oauth2-auto from my fork until oauth2-auto is added to MELPA.
update-oauth2-auto:
	curl -o oauth2-auto.el \
		https://raw.githubusercontent.com/telotortium/emacs-oauth2-auto/main/oauth2-auto.el
