;;; test-ide-config.el --- ERT tests for the IDE init files  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Loads init-tree-sitter, init-python, init-cc-mode, init-ide, init-CIDE
;; and init-rust into a bare Emacs and checks the logic that does not need
;; a language server: the operation registry, project and build-system
;; detection, interpreter lookup, formatter style, Eglot wiring and the
;; tree-sitter install decisions.  Things the other init files and the
;; ELPA packages normally provide (`my-comma-leader-def',
;; `my-buffer-file-temp-p', google-c-style) are replaced by stubs.
;;
;; Run it from the directory that holds the init-*.el files (the Makefile
;; uses `$(EMACS)'; it is the `$EMACS' executable here):
;;
;;   $EMACS -Q --batch -l test-ide-config.el -f ert-run-tests-batch-and-exit
;;
;; For the real machine (programs, grammars, packages) use
;; `M-x my-ide-doctor' in the running Emacs instead.
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function eglot-path-to-uri "eglot")

(defvar test-ide-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding the init files under test.")

;;; Harness

(defvar test-ide-leader-calls nil
  "Argument lists `my-comma-leader-def' was called with, newest first.")

(defvar test-ide-load-errors nil
  "Errors signalled while the harness loaded the init files.")

;; Stand-ins for what other init files and packages provide.
(provide 'google-c-style)
(defun google-set-c-style (&rest _)
  "Do nothing; stand in for the google-c-style.el function."
  nil)
(defun google-make-newline-indent (&rest _)
  "Do nothing; stand in for the google-c-style.el function."
  nil)
(defun my-buffer-file-temp-p ()
  "Return nil; the real predicate lives in init-utils.el."
  nil)
;; When this file is compiled after init.el, init-evil's macro is already
;; defined and the compiler warns about redefining it as a function; the
;; stub is intentional.
(with-no-warnings
  (defun my-comma-leader-def (&rest args)
    "Record ARGS; the real definer comes from init-evil.el."
    (push args test-ide-leader-calls)))

;; Load in the order init.el uses: tree-sitter, python and cc-mode first,
;; then the shared IDE layer and its consumers, C/C++ and Rust.  Loading
;; python before ide also exercises its `with-eval-after-load' path.
;; Then provide `init-evil' and load the libraries whose
;; `with-eval-after-load' forms bind keys or Eglot entries, so those run.
(dolist (step
         (list
          (lambda ()
            (dolist (file '("init-tree-sitter" "init-python" "init-cc-mode"
                            "init-ide" "init-CIDE" "init-rust"))
              ;; The explicit ".el" keeps a stale .elc (compiled before
              ;; the last edit) from silently replacing the code under
              ;; test.
              (load (expand-file-name (concat file ".el") test-ide-dir)
                    nil t)))
          (lambda () (provide 'init-evil))
          (lambda () (require 'python))
          (lambda () (require 'cc-mode))
          (lambda () (require 'find-file))
          (lambda () (require 'eglot))))
  (condition-case err
      (funcall step)
    (error (push err test-ide-load-errors))))

;;; Declarations
;; The init files define these options and variables.  Declaring them
;; here keeps the byte compiler from treating the `let' bindings in the
;; tests as lexical variables; a byte-compiled test file would then
;; silently bind and read the wrong (default) values.
(defvar my-ide-operation-table)
(defvar my-cpp-modes)
(defvar my-rust-modes)
(defvar my-cpp-keymaps)
(defvar my-rust-keymaps)
(defvar my-cpp-clangd-program)
(defvar my-cpp-clangd-args)
(defvar my-cpp-clangd-query-drivers)
(defvar my-rust-analyzer-options)
(defvar my-cpp-parallel-jobs)
(defvar my-cpp-memory-per-job-mb)
(defvar my-cpp-switch-source-header-timeout)
(defvar my-python-use-ts-mode)
(defvar my-rust-cargo-markers-override-vc)
(defvar my-cpp-clang-format-command)
(defvar my-cpp-company-backends)
(defvar my-python-company-backends)
(defvar my-rust-company-backends)
(defvar my-treesit-grammars-ready-hook)
(defvar my-treesit-grammar-directory)
(defvar cc-search-directories)
(defvar c-mode-common-hook)
(defvar c-ts-mode-hook)
(defvar cmake-mode-hook)
(defvar treesit-language-source-alist)
(defvar eglot-autoshutdown)
(defvar eglot-extend-to-xref)
(defvar eglot-inlay-hints-mode)
(defvar jsonrpc-default-request-timeout)
(defvar eglot-server-programs)
(defvar project-find-functions)

;;; Helpers

(defmacro test-ide--in-mode (mode &rest body)
  "Run BODY in a temporary buffer whose `major-mode' is MODE."
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local major-mode ,mode)
     ,@body))

(defun test-ide--populate (root files)
  "Create FILES under ROOT.
Each entry is a relative name (a trailing slash makes a directory) or a
cons (NAME . CONTENT)."
  (dolist (entry files)
    (let* ((name (if (consp entry) (car entry) entry))
           (content (if (consp entry) (cdr entry) ""))
           (path (expand-file-name name root)))
      (make-directory (file-name-directory path) t)
      (unless (string-suffix-p "/" name)
        (write-region content nil path nil 'silent)))))

(defun test-ide--temp-root ()
  "Return a base directory with readable ancestors for temporary trees.
The variable `temporary-file-directory' can sit under an unreadable
ancestor (systemd's per-user /tmp/user/UID has a root-owned, execute-only
parent), which makes the ancestor walk in `project-current' abort."
  (or (and (file-writable-p "/tmp") (file-name-as-directory "/tmp"))
      temporary-file-directory))

(defmacro test-ide--with-tree (spec &rest body)
  "Bind (ROOT FILES) of SPEC to a temporary tree, run BODY, then delete it."
  (declare (indent 1))
  (let ((root (car spec)))
    `(let* ((temporary-file-directory (test-ide--temp-root))
            (,root (file-name-as-directory (make-temp-file "ide-test" t))))
       (unwind-protect
           (progn
             (test-ide--populate ,root ,(cadr spec))
             ,@body)
         (delete-directory ,root t)))))

(defun test-ide--calls-binding (key function)
  "Return the `my-comma-leader-def' argument lists that bind KEY to FUNCTION."
  (seq-filter
   (lambda (args)
     (let ((rest args) found)
       (while rest
         (cond ((keywordp (car rest)) (setq rest (cddr rest)))
               ((and (stringp (car rest)) (equal (car rest) key)
                     (eq (cadr rest) function))
                (setq found t rest (cddr rest)))
               (t (setq rest (cdr rest)))))
       found))
   test-ide-leader-calls))

(defun test-ide--eglot-contact-p (entry expected)
  "Return non-nil when the Eglot contact ENTRY is EXPECTED.
On Emacs 30 `(function SYM)' evaluates to the symbol; on older Emacs it
yields the function object, so both forms are accepted."
  (or (eq entry expected)
      (eq entry (ignore-errors (symbol-function expected)))))

;;; Loading

(ert-deftest test-ide-files-load-without-errors ()
  (should (null test-ide-load-errors)))

(ert-deftest test-ide-features-provided ()
  (dolist (feature '(init-tree-sitter init-ide init-python init-CIDE
                     init-rust init-cc-mode))
    (should (featurep feature))))

;;; Shared operations and company backends

(ert-deftest test-ide-operations-registered ()
  (dolist (case '((c-mode build my-cpp-build)
                  (c++-ts-mode test my-cpp-test)
                  (objc-mode debug my-cpp-debug)
                  (c-ts-mode lint my-cpp-cppcheck)
                  (c++-mode format my-cpp-format-buffer)
                  (python-mode build my-python-check)
                  (python-ts-mode format my-python-format)
                  (python-mode test my-python-test)
                  (rust-mode lint my-rust-cargo-clippy)
                  (rust-ts-mode debug my-rust-debug)
                  (rust-ts-mode build my-rust-cargo-build)
                  (cmake-mode build my-cpp-build)
                  (cmake-ts-mode lint my-cpp-cppcheck)))
    (pcase-let ((`(,mode ,operation ,command) case))
      (test-ide--in-mode mode
        (should (eq (my-ide-operation-command operation) command))))))

(ert-deftest test-ide-cmake-has-no-format-operation ()
  (test-ide--in-mode 'cmake-mode
    (should-not (my-ide-operation-command 'format))))

(ert-deftest test-ide-unknown-mode-signals-user-error ()
  (test-ide--in-mode 'text-mode
    (should-error (my-ide-build) :type 'user-error)))

(ert-deftest test-ide-register-replaces-duplicates ()
  (let ((my-ide-operation-table nil))
    (my-ide-register 'build '(foo-mode) #'ignore)
    (my-ide-register 'build '(foo-mode) #'identity)
    (should (= 1 (length (alist-get 'build my-ide-operation-table))))
    (test-ide--in-mode 'foo-mode
      (should (eq (my-ide-operation-command 'build) #'identity)))))

(ert-deftest test-ide-company-backends-per-mode ()
  (test-ide--in-mode 'rust-mode
    (should (equal (my-ide-company-backends) my-rust-company-backends)))
  (test-ide--in-mode 'python-ts-mode
    (should (equal (my-ide-company-backends) my-python-company-backends)))
  (test-ide--in-mode 'c++-mode
    (should (equal (my-ide-company-backends) my-cpp-company-backends)))
  (test-ide--in-mode 'text-mode
    (should-not (my-ide-company-backends))))

(ert-deftest test-ide-flycheck-modes-excluding ()
  (should (equal (my-ide-flycheck-modes-excluding t '(a b)) '(not a b)))
  (let ((result (my-ide-flycheck-modes-excluding '(not x) '(a b))))
    (should (eq (car result) 'not))
    (should (seq-set-equal-p (cdr result) '(x a b))))
  ;; Excluding twice must not duplicate entries.
  (let ((result (my-ide-flycheck-modes-excluding '(not a) '(a))))
    (should (seq-set-equal-p (cdr result) '(a))))
  (should (seq-set-equal-p
           (my-ide-flycheck-modes-excluding '(a b c) '(b)) '(a c)))
  (should-not (my-ide-flycheck-modes-excluding nil '(a))))

;;; Eglot wiring

(ert-deftest test-ide-eglot-settings ()
  (should eglot-autoshutdown)
  (should eglot-extend-to-xref)
  (should (= 60 jsonrpc-default-request-timeout))
  (dolist (function '(my-ide-eglot-inlay-hints my-ide-eglot-capf-first
                      my-ide-restore-company-backends my-ide-disable-flycheck))
    (should (memq function (default-value 'eglot-managed-mode-hook)))))

(ert-deftest test-ide-eglot-server-programs ()
  (should (test-ide--eglot-contact-p
           (alist-get my-cpp-modes eglot-server-programs nil nil #'equal)
           'my-cpp-clangd-contact))
  (should (test-ide--eglot-contact-p
           (alist-get my-rust-modes eglot-server-programs nil nil #'equal)
           'my-rust-analyzer-contact))
  (should (alist-get '(python-mode python-ts-mode) eglot-server-programs
                     nil nil #'equal))
  (should (alist-get '(cmake-mode cmake-ts-mode) eglot-server-programs
                     nil nil #'equal)))

(ert-deftest test-ide-inlay-hook-is-safe-outside-eglot ()
  ;; The stop path of `eglot-managed-mode-hook': no server, mode not managed.
  (with-temp-buffer
    (my-ide-eglot-inlay-hints)
    (should-not (bound-and-true-p eglot-inlay-hints-mode))))

(ert-deftest test-ide-inlay-hook-starts-mode-when-managed ()
  ;; The start path of `eglot-managed-mode-hook': mode managed.
  (let (argument)
    (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
              ((symbol-function 'eglot-inlay-hints-mode)
               (lambda (arg) (setq argument arg))))
      (my-ide-eglot-inlay-hints)
      (should (eq argument 1)))))

(ert-deftest test-ide-inlay-hook-stops-mode-when-unmanaged ()
  ;; The stop path of `eglot-managed-mode-hook': the mode is still on
  ;; when the hook runs, but Eglot no longer manages the buffer.
  (let (argument)
    (cl-letf (((symbol-function 'eglot-managed-p) (lambda () nil))
              ((symbol-function 'eglot-inlay-hints-mode)
               (lambda (arg) (setq argument arg))))
      (with-temp-buffer
        (setq eglot-inlay-hints-mode t)
        (my-ide-eglot-inlay-hints)
        (should (eq argument -1))))))

(ert-deftest test-cpp-clangd-contact ()
  (let ((my-cpp-clangd-program "clangd-19")
        (my-cpp-clangd-args '("--x"))
        (my-cpp-clangd-query-drivers '("/a/*" "/b/*")))
    (should (equal (my-cpp-clangd-contact)
                   '("clangd-19" "--x" "--query-driver=/a/*,/b/*"))))
  (let ((my-cpp-clangd-query-drivers nil))
    (should-not (seq-some (lambda (argument)
                            (string-prefix-p "--query-driver" argument))
                          (my-cpp-clangd-contact)))))

(ert-deftest test-rust-analyzer-contact ()
  (let ((my-rust-analyzer-options '(:check (:command "clippy"))))
    (should (equal (my-rust-analyzer-contact)
                   '("rust-analyzer" :initializationOptions
                     (:check (:command "clippy")))))))

;;; Leader keys

(ert-deftest test-ide-shared-keys-bound ()
  (dolist (binding '(("nb" . my-ide-build) ("nt" . my-ide-test)
                     ("nd" . my-ide-debug) ("nl" . my-ide-lint)
                     ("nf" . my-ide-format) ("nc" . compile)
                     ("nr" . eglot-rename) ("na" . eglot-code-actions)
                     ("ni" . xref-find-references) ("ne" . eglot-reconnect)))
    (should (test-ide--calls-binding (car binding) (cdr binding)))))

(ert-deftest test-ide-language-keys-bound-in-mode-maps ()
  (should (test-ide--calls-binding "tr" 'my-python-run))
  (should (test-ide--calls-binding "tr" 'my-rust-cargo-run))
  (should (test-ide--calls-binding "tc" 'my-cpp-configure))
  ;; cc-mode was loaded by the harness, so its maps must have been bound.
  (should (seq-some
           (lambda (args) (memq 'c-mode-map (plist-get args :keymaps)))
           (test-ide--calls-binding "tc" 'my-cpp-configure)))
  (should (seq-some
           (lambda (args) (memq 'python-mode-map (plist-get args :keymaps)))
           (test-ide--calls-binding "tr" 'my-python-run))))

(ert-deftest test-ide-language-keys-not-bound-without-maps ()
  ;; With no mode map bound yet, an empty `:keymaps' would make
  ;; `general-def' bind into the global evil map; the binders must do
  ;; nothing instead.  The binders are macros, so expand by hand to keep
  ;; this file safe to byte-compile.
  (let ((test-ide-leader-calls nil)
        (my-cpp-keymaps '(test-ide-void-map-1 test-ide-void-map-2)))
    (eval (macroexpand-1 '(my-cpp-bind-t-keys)))
    (should-not test-ide-leader-calls))
  (let ((test-ide-leader-calls nil)
        (my-rust-keymaps '(test-ide-void-map-3)))
    (eval (macroexpand-1 '(my-rust-bind-t-keys)))
    (should-not test-ide-leader-calls)))

;;; C/C++

(ert-deftest test-cpp-detect-build-system ()
  (dolist (case '((("CMakeLists.txt") . cmake)
                  (("meson.build") . meson)
                  (("xmake.lua") . xmake)
                  (("configure.ac" "Makefile.am") . autotools)
                  (("configure") . autotools)
                  (("app.pro") . qmake)
                  (("Makefile") . make)
                  (("build.ninja") . ninja)
                  (("README") . generic)
                  (("CMakeLists.txt" "Makefile") . cmake)))
    (test-ide--with-tree (root (car case))
      (should (eq (my-cpp-detect-build-system root) (cdr case))))))

(ert-deftest test-cpp-project-root-is-nearest-marker ()
  (test-ide--with-tree (root '("Makefile" "src/deep/a.c"))
    (let ((default-directory (expand-file-name "src/deep/" root)))
      (should (file-equal-p (my-cpp-project-root) root)))))

(ert-deftest test-cpp-cmake-root-skips-fragments ()
  (test-ide--with-tree
      (root '(("CMakeLists.txt"
               . "cmake_minimum_required(VERSION 3.16)\nproject(demo)\n")
              ("lib/CMakeLists.txt" . "add_library(x x.cc)\n")
              "lib/x.cc"))
    (let ((default-directory (expand-file-name "lib/" root)))
      (should (file-equal-p (my-cpp-cmake-root) root)))))

(ert-deftest test-cpp-parallel-jobs ()
  (let ((my-cpp-parallel-jobs 7))
    (should (= 7 (my-cpp-effective-parallel-jobs))))
  (let ((my-cpp-parallel-jobs nil) (my-cpp-memory-per-job-mb nil))
    (should (>= (my-cpp-effective-parallel-jobs) 1)))
  (skip-unless (my-cpp--available-memory-mb))
  ;; An absurd per-job figure leaves room for one job only, never zero.
  (let ((my-cpp-parallel-jobs nil)
        (my-cpp-memory-per-job-mb most-positive-fixnum))
    (should (= 1 (my-cpp-effective-parallel-jobs)))))

(ert-deftest test-cpp-parallel-jobs-ignores-nonpositive ()
  ;; 0 and negative values are explicit (truthy) but nonsensical: `-j 0'
  ;; means unlimited jobs.  They must fall back to the automatic count.
  (dolist (value '(0 -1 -100))
    (let ((my-cpp-parallel-jobs value)
          (my-cpp-memory-per-job-mb nil))
      (should (>= (my-cpp-effective-parallel-jobs) 1)))))

(ert-deftest test-cpp-available-memory-mb ()
  (cl-letf (((symbol-function 'file-readable-p) (lambda (_) t))
            ((symbol-function 'insert-file-contents)
             (lambda (&rest _)
               ;; The real one leaves point at the start of the inserted
               ;; text; plain `insert' would leave it at the end, where
               ;; the caller's forward search starts and finds nothing.
               (insert "MemAvailable:   2048000 kB\n")
               (goto-char (point-min)))))
    (should (= 2000 (my-cpp--available-memory-mb))))
  (cl-letf (((symbol-function 'file-readable-p) (lambda (_) nil)))
    (should-not (my-cpp--available-memory-mb))))

(ert-deftest test-cpp-switch-source-header-timeout-sanitized ()
  (let ((my-cpp-switch-source-header-timeout 5))
    (should (= 5 (my-cpp--switch-source-header-timeout))))
  (dolist (value '(0 -3))
    (let ((my-cpp-switch-source-header-timeout value))
      (should-not (my-cpp--switch-source-header-timeout))))
  (let ((my-cpp-switch-source-header-timeout 2.5))
    (should (= 2.5 (my-cpp--switch-source-header-timeout)))))

(ert-deftest test-cpp-switch-source-header-passes-timeout ()
  (let (requested target)
    (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
              ((symbol-function 'jsonrpc-request)
               (lambda (_server _method _params &rest args)
                 (setq requested args)
                 "file:///tmp/a.h"))
              ((symbol-function 'my-cpp--uri-to-path)
               (lambda (_uri) "/tmp/a.h"))
              ((symbol-function 'find-file)
               (lambda (file) (setq target file))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/a.c")
        (let ((my-cpp-switch-source-header-timeout 3))
          (my-cpp-switch-source-header))
        (should (equal (plist-get requested :timeout) 3))
        (should (equal target "/tmp/a.h"))))))

(ert-deftest test-cpp-switch-source-header-nil-timeout ()
  ;; nil asks jsonrpc to use its default rather than meaning "no limit".
  (let (requested)
    (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
              ((symbol-function 'jsonrpc-request)
               (lambda (_server _method _params &rest args)
                 (setq requested args)
                 nil))
              ((symbol-function 'ff-find-other-file)
               (lambda () (interactive) nil)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/a.c")
        (let ((my-cpp-switch-source-header-timeout nil))
          (my-cpp-switch-source-header))
        (should (equal (plist-get requested :timeout) nil))))))

(ert-deftest test-cpp-path-uri-shims ()
  (should (equal (my-cpp--path-to-uri "/tmp/a b.c")
                 (eglot-path-to-uri "/tmp/a b.c")))
  (should (equal (my-cpp--uri-to-path (eglot-path-to-uri "/tmp/a b.c"))
                 "/tmp/a b.c"))
  ;; On builds without the public names the double-dash aliases are used.
  ;; Clearing the public cell would also void the alias (it points at the
  ;; same symbol), so stub the alias and check the dispatch instead.
  (cl-letf (((symbol-function 'eglot-path-to-uri) nil)
            ((symbol-function 'eglot--path-to-uri)
             (lambda (path) (concat "alias:" path))))
    (should (equal (my-cpp--path-to-uri "/tmp/x.c")
                   "alias:/tmp/x.c"))))

(ert-deftest test-cpp-clang-format-style ()
  (should (string-match-p "AccessModifierOffset: -2"
                          (prin1-to-string my-cpp-clang-format-command)))
  (test-ide--with-tree (root '("Makefile"))
    (let ((default-directory root))
      (my-cpp-write-clang-format)
      (should (string-match-p
               "AccessModifierOffset: -2"
               (with-temp-buffer
                 (insert-file-contents (expand-file-name ".clang-format" root))
                 (buffer-string)))))))

(ert-deftest test-cpp-check-compilation-database ()
  (test-ide--with-tree (root nil)
    (write-region
     (format "[{\"directory\":%S,\"file\":\"missing.c\",\"command\":\"cc missing.c\"},{\"directory\":\"/no/such/dir\",\"file\":\"x.c\",\"command\":\"cc x.c\"}]"
             root)
     nil (expand-file-name "compile_commands.json" root) nil 'silent)
    (let (warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warnings))))
        (my-cpp-check-compilation-database root))
      ;; One entry points at a missing file, one has no valid directory.
      (should (= 2 (length warnings))))))

(ert-deftest test-cpp-search-directories-are-additive ()
  (should (member "/usr/include" cc-search-directories))
  (should (member "../*/include" cc-search-directories))
  (should (member "../src" cc-search-directories)))

(ert-deftest test-cpp-cc-mode-hooks ()
  (should (memq 'c-mode-common-hook-setup c-mode-common-hook))
  (should (memq 'my-c-ts-mode-setup c-ts-mode-hook))
  (should (memq 'my-cmake-mode-imenu-setup cmake-mode-hook)))

;;; Rust

(ert-deftest test-rust-workspace-root-and-edition ()
  (test-ide--with-tree
      (root '(("Cargo.toml"
               . "[workspace]\nmembers = [\"crates/a\"]\n[workspace.package]\nedition = \"2024\"\n")
              ("crates/a/Cargo.toml"
               . "[package]\nname = \"a\"\nedition.workspace = true\n")
              "crates/a/src/lib.rs"))
    (let ((member (expand-file-name "crates/a/" root)))
      (should (file-equal-p
               (my-rust-workspace-root (expand-file-name "src/" member)) root))
      (should (file-equal-p
               (cdr (my-rust-project-try-local member)) root))
      ;; `edition.workspace = true' has no value to read ...
      (should-not (my-rust--manifest-edition member))
      ;; ... so the edition comes from the workspace root.
      (let ((default-directory (expand-file-name "src/" member)))
        (should (equal (my-rust-cargo-edition) "2024"))))))

(ert-deftest test-rust-manifest-edition-ignores-comments ()
  (test-ide--with-tree
      (root '(("Cargo.toml" . "[package]\n# edition = \"2015\"\nedition = '2021'\n")))
    (should (equal (my-rust--manifest-edition root) "2021"))))

(ert-deftest test-rust-find-function-registered-before-vc ()
  ;; The default (`my-rust-cargo-markers-override-vc' t) uses
  ;; project-vc-extra-root-markers instead; with nil the find function
  ;; must land before `project-try-vc', and reloading must not move it.
  (let ((my-rust-cargo-markers-override-vc nil)
        (saved project-find-functions))
    (unwind-protect
        (progn
          (load (expand-file-name "init-rust.el" test-ide-dir) nil t)
          (let ((head (take (- (length project-find-functions)
                               (length (memq 'project-try-vc
                                             project-find-functions)))
                            project-find-functions)))
            (should (memq 'my-rust-project-try-local head)))
          ;; Idempotent: a second run keeps the same order.
          (let ((before (copy-sequence project-find-functions)))
            (load (expand-file-name "init-rust.el" test-ide-dir) nil t)
            (should (equal project-find-functions before))))
      (setq project-find-functions saved))))

;;; Python

(ert-deftest test-python-venv-is-found-and-preferred ()
  (test-ide--with-tree
      (root '("pyproject.toml"
              (".venv/pyvenv.cfg" . "home = /usr/bin\n")
              (".venv/bin/python" . "#!/bin/sh\n")
              "src/a.py"))
    (set-file-modes (expand-file-name ".venv/bin/python" root) #o755)
    (let ((default-directory (expand-file-name "src/" root))
          (venv (expand-file-name ".venv" root)))
      (should (file-equal-p (my-python--project-root) root))
      (should (my-python--venv-p venv))
      (should (file-equal-p (my-python--project-venv) venv))
      ;; The buffer's own interpreter beats whatever PATH currently holds.
      (should (file-equal-p (my-python-program)
                            (expand-file-name "bin/python" venv))))))

(ert-deftest test-python-program-without-venv ()
  (test-ide--with-tree (root '("pyproject.toml" "a.py"))
    (let ((default-directory root))
      (should-not (my-python--project-venv))
      (should (stringp (my-python-program))))))

(ert-deftest test-python-venv-executable-finds-project-tools ()
  (test-ide--with-tree
      (root '("pyproject.toml"
              (".venv/pyvenv.cfg" . "home = /usr/bin\n")
              (".venv/bin/python" . "#!/bin/sh\n")
              (".venv/bin/ruff" . "#!/bin/sh\n")))
    (set-file-modes (expand-file-name ".venv/bin/ruff" root) #o755)
    (let ((default-directory root))
      (should (file-equal-p (my-python--venv-executable "ruff")
                            (expand-file-name ".venv/bin/ruff" root)))
      (should-not (my-python--venv-executable "pylint")))))

(ert-deftest test-python-lint-prefers-project-venv-ruff ()
  (test-ide--with-tree
      (root '("pyproject.toml"
              (".venv/pyvenv.cfg" . "home = /usr/bin\n")
              (".venv/bin/python" . "#!/bin/sh\n")
              (".venv/bin/ruff" . "#!/bin/sh\n")))
    (dolist (file '(".venv/bin/python" ".venv/bin/ruff"))
      (set-file-modes (expand-file-name file root) #o755))
    (let ((default-directory root)
          command)
      (cl-letf (((symbol-function 'compile)
                 (lambda (cmd &optional _comint) (setq command cmd))))
        (my-python-lint))
      (should (string-match-p
               (regexp-quote (expand-file-name ".venv/bin/ruff" root))
               command)))))

(ert-deftest test-python-remap-ts-mode ()
  (skip-unless (fboundp 'treesit-available-p))
  (should (memq 'my-python-remap-ts-mode my-treesit-grammars-ready-hook))
  (let ((major-mode-remap-alist nil))
    (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
              ((symbol-function 'treesit-language-available-p)
               (lambda (&rest _) t)))
      (my-python-remap-ts-mode))
    (should (eq (alist-get 'python-mode major-mode-remap-alist)
                'python-ts-mode)))
  (let ((major-mode-remap-alist nil))
    (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
              ((symbol-function 'treesit-language-available-p)
               (lambda (&rest _) nil)))
      (my-python-remap-ts-mode))
    (should-not (alist-get 'python-mode major-mode-remap-alist))))

(ert-deftest test-python-remap-ts-mode-opt-out ()
  (skip-unless (fboundp 'treesit-available-p))
  (let ((major-mode-remap-alist nil)
        (my-python-use-ts-mode nil))
    (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
              ((symbol-function 'treesit-language-available-p)
               (lambda (&rest _) t)))
      (my-python-remap-ts-mode))
    (should-not (alist-get 'python-mode major-mode-remap-alist))))

;;; Tree-sitter installation decisions

(ert-deftest test-treesit-recipes-registered ()
  (dolist (language '(c cpp cmake python rust))
    (should (stringp (car (alist-get language treesit-language-source-alist)))))
  (should (equal (car (alist-get 'python treesit-language-source-alist))
                 "https://github.com/tree-sitter/tree-sitter-python")))

(ert-deftest test-treesit-revision-follows-abi ()
  (cl-letf (((symbol-function 'treesit-library-abi-version)
             (lambda (&rest _) 15)))
    (should (equal (my-treesit-grammar-revision "v1" "master") "master")))
  (cl-letf (((symbol-function 'treesit-library-abi-version)
             (lambda (&rest _) 14)))
    (should (equal (my-treesit-grammar-revision "v1" "master") "v1"))))

(ert-deftest test-treesit-languages-to-install ()
  ;; Only the language whose server exists is installed.
  (cl-letf (((symbol-function 'my-cpp-langserver-exist) (lambda () nil))
            ((symbol-function 'my-cmake-langserver-exist) (lambda () nil))
            ((symbol-function 'my-python-langserver-exist)
             (lambda () "/bin/pyls"))
            ((symbol-function 'my-rust-langserver-exist) (lambda () nil))
            ((symbol-function 'my-treesit-grammar-available-p)
             (lambda (_) nil)))
    (should (equal (my-treesit--languages-to-install) '(python)))
    (should (equal (my-treesit--languages-to-install t) '(python))))
  ;; Every server exists; c and cpp are already built.
  (cl-letf (((symbol-function 'my-cpp-langserver-exist) (lambda () t))
            ((symbol-function 'my-cmake-langserver-exist) (lambda () t))
            ((symbol-function 'my-python-langserver-exist) (lambda () t))
            ((symbol-function 'my-rust-langserver-exist) (lambda () t))
            ((symbol-function 'my-treesit-grammar-available-p)
             (lambda (language) (memq language '(c cpp)))))
    (should (equal (my-treesit--languages-to-install) '(cmake python rust)))
    (should (equal (my-treesit--languages-to-install t)
                   '(c cpp cmake python rust)))))

(ert-deftest test-treesit-install-form-keeps-emacs29-path ()
  ;; Emacs 29's public installer has no output-directory argument; the
  ;; generated form must keep the internal-installer fallback.
  (let ((text (prin1-to-string (my-treesit--install-form '(python)))))
    (should (string-match-p "func-arity" text))
    (should (string-match-p "treesit--install-language-grammar-1" text))))

(ert-deftest test-treesit-installer-passes-out-dir ()
  (let (captured)
    (cl-letf (((symbol-function 'treesit-install-language-grammar)
               (lambda (language &optional directory)
                 (setq captured (list language directory))))
              ((symbol-function 'treesit--install-language-grammar-1)
               (lambda (&rest args) (setq captured args))))
      (my-treesit--install-language-grammar 'python))
    (should (equal captured
                   (list 'python my-treesit-grammar-directory)))))

(ert-deftest test-treesit-installer-emacs29-fallback ()
  ;; A one-argument public installer means Emacs 29: the wrapper must
  ;; call the internal installer with the configured output directory.
  (let (captured)
    (cl-letf (((symbol-function 'treesit-install-language-grammar)
               (lambda (language)
                 (setq captured (list 'public language))))
              ((symbol-function 'treesit--install-language-grammar-1)
               (lambda (&rest args) (setq captured args))))
      (my-treesit--install-language-grammar 'python))
    (should (equal (car captured) my-treesit-grammar-directory))
    (should (eq (cadr captured) 'python))
    (should (equal (cddr captured)
                   (cdr (assq 'python treesit-language-source-alist))))))

;;; Self-check

(ert-deftest test-ide-doctor-report ()
  (let* ((rows (my-ide-doctor-report))
         (failures (seq-filter (lambda (row) (eq (car row) 'fail)) rows)))
    (should rows)
    (dolist (row rows)
      (should (memq (car row) '(ok warn fail)))
      (should (stringp (nth 1 row)))
      (should (stringp (nth 2 row))))
    ;; Warnings (missing programs) are fine here; broken wiring is not.
    (should (null failures))))

(ert-deftest test-ide-doctor-local-bin-accepts-trailing-slash ()
  ;; `exec-path-from-shell' leaves the trailing slash of a PATH entry;
  ;; that must not turn the environment check into a false warning.
  (skip-unless (file-directory-p (expand-file-name "~/.local/bin")))
  (let* ((bin (file-name-as-directory (expand-file-name "~/.local/bin")))
         (exec-path (list bin))
         (row (seq-find (lambda (row)
                          (and (equal (nth 1 row) "env")
                               (string-match-p "local/bin" (nth 2 row))))
                        (my-ide-doctor-report))))
    (should row)
    (should (eq (car row) 'ok))))

(ert-deftest test-ide-doctor-eglot-contacts-as-function-objects ()
  ;; On Emacs < 30 the layers register the function object, not the
  ;; symbol; the doctor must accept both forms.
  (let ((eglot-server-programs (copy-tree eglot-server-programs)))
    (setf (alist-get my-cpp-modes eglot-server-programs nil nil 'equal)
          (symbol-function 'my-cpp-clangd-contact))
    (setf (alist-get my-rust-modes eglot-server-programs nil nil 'equal)
          (symbol-function 'my-rust-analyzer-contact))
    (should-not
     (seq-find
      (lambda (row) (and (eq (car row) 'fail) (equal (nth 1 row) "eglot")))
      (my-ide-doctor-report)))))

(ert-deftest test-ide-doctor-batch-output ()
  (let ((noninteractive t) failures output)
    (setq output (with-output-to-string (setq failures (my-ide-doctor))))
    (should (string-match-p "failure(s)" output))
    (should (= failures 0))))

(provide 'test-ide-config)
;;; test-ide-config.el ends here
