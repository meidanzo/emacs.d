SHELL = /bin/sh
EMACS ?= emacs
PROFILER =
RM = @rm -rf
EMACS_BATCH_OPTS = --batch -Q --debug-init --eval "(setq my-disable-idle-timer t)"

.PHONY: test clean githooks spellcheck compile install

# Delete byte-compiled files etc.
clean:
	$(RM) *~
	$(RM) \#*\#
	$(RM) *.elc
	$(RM) lisp/*.elc

githooks:
	cd `git rev-parse --show-toplevel`/.git/hooks && ln -s ../../githooks/pre-commit pre-commit && cd -

install: clean
	@$(EMACS) $(EMACS_BATCH_OPTS) -l init.el

# Delete byte-compiled files etc.
spellcheck:
	@LANG=en_US.UTF-8 $(EMACS) $(EMACS_BATCH_OPTS) -L site-lisp/wucuo -l site-lisp/wucuo/wucuo.el -l tools/spellcheck.el

# Compile the personal Lisp files.  `byte-compile-file' reports syntax
# errors by returning nil while Emacs still exits 0, so collect those
# failures and fail only on them; warnings are counted, not fatal.
compile: install
	@log=$$(mktemp); \
	$(EMACS) $(EMACS_BATCH_OPTS) \
	  -l init.el \
	  --eval "(defvar my-byte-compile-failed nil)" \
	  --eval "(advice-add 'byte-compile-file :around (lambda (orig file &rest args) (let ((result (apply orig file args))) (unless result (push file my-byte-compile-failed)) result)))" \
	  -l tests/my-byte-compile.el \
	  --eval "(when my-byte-compile-failed (message \"Byte-compile failed: %S\" (nreverse my-byte-compile-failed)) (kill-emacs 1))" \
	  > $$log 2>&1; \
	status=$$?; \
	if [ $$status -ne 0 ]; then \
	  cat $$log; \
	  rm -f $$log; \
	  exit 1; \
	fi; \
	warnings=$$(grep -c "Warning:" $$log || true); \
	echo "Byte-compile OK ($$warnings warning(s))"; \
	rm -f $$log

# Run tests.
test: compile spellcheck
	@$(EMACS) $(EMACS_BATCH_OPTS) -l init.el -l tests/emacs.d-test.el
	@$(EMACS) -Q --batch -l lisp/test-ide-config.el -f ert-run-tests-batch-and-exit
