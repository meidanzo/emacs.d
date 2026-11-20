;;; init-ide.el --- language-neutral IDE operations  -*- lexical-binding: t; -*-
;; Copyright (C) 2026 meidanzo <meidanzo@foxmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The shared intersection (set C) of the language IDE layers: one key
;; does one thing in every supported language project.  Each language
;; layer (init-CIDE.el, init-rust.el, ...) registers its own
;; implementation of the operations below with `my-ide-register', and
;; binds its language-specific keys under the shared "," "t" prefix in
;; its own mode maps, so the buffer's mode decides which function a
;; key fires.
;;
;; Shared "," + "n" keys:
;;   ,nb 构建      ,nc 编译      ,nt 测试
;;   ,nd 调试      ,nl lint     ,nf 格式化
;;   ,nr 重命名    ,na 代码操作
;;   ,ni 引用      ,ne 重连
;;
;; Why "n": the comma is pressed with the right ring finger, so the
;; prefix letter should sit under the left hand; n (left index) was
;; the freest such key (only ,nm was taken, and it still works).
;;
;; Definition jump (`,vv' evil-goto-definition) is already bound
;; globally in init-evil.el.  To add another language, register its
;; commands and bind its language-specific keys under "," "t" from its
;; own init file; nothing here needs to change.
;;
;; This file also holds the language-neutral Eglot setup shared by
;; every LSP language layer (server completion first, inlay hints,
;; Flymake-only diagnostics), so init-CIDE.el and init-rust.el no
;; longer depend on each other.
;;
;; Loaded by `require-init' from init.el before init-CIDE and
;; init-rust; the `t' flag keeps it disabled in light weight mode.
;;
;; Dependencies (all loaded earlier by init.el):
;; - `my-comma-leader-def' from init-evil.el (requires evil)
;;
;; Section overview:
;;   1. Operation registry     the dispatch table behind set C
;;   2. Shared commands        my-ide-build/test/debug/lint/format
;;   3. Shared Eglot setup     language-neutral LSP behavior
;;   4. Self-check             M-x my-ide-doctor
;;   5. Keybindings            "," + "n" shared keys
;;; Code:

(require 'subr-x)
(require 'cl-lib)

;;; Operation registry

(defvar my-ide-operation-table nil
  "Alist mapping an operation symbol to (MODES . COMMAND) entries.
Each language layer registers its implementations with
`my-ide-register'.  MODES is a list of major-mode symbols matched
with `derived-mode-p'; COMMAND is called with `call-interactively'
so its interactive arguments (for example a prefix argument) pass
through.")

(defun my-ide-register (op modes command)
  "Register COMMAND as MODES' implementation of the shared operation OP.
OP is a symbol naming an operation, such as `build' or `debug'.
A second registration for the same OP and MODES replaces the first, so
re-evaluating a language layer does not pile up duplicate entries."
  (setf (alist-get op my-ide-operation-table)
        (cons (cons modes command)
              (assoc-delete-all modes (alist-get op my-ide-operation-table)
                                #'equal))))

(defun my-ide-find-entry (entries)
  "Return the cdr of the first ENTRY whose mode list matches this buffer.
ENTRIES is a list of (MODES . VALUE); MODES is matched with
`derived-mode-p'.  Shared by the operation and company tables, which
have the same shape."
  (catch 'my-ide-found
    (dolist (entry entries)
      (when (apply #'derived-mode-p (car entry))
        (throw 'my-ide-found (cdr entry))))
    nil))

(defun my-ide-operation-command (op)
  "Return the command registered for OP in the current buffer, or nil."
  (my-ide-find-entry (alist-get op my-ide-operation-table)))

;;; Shared commands

(defun my-ide-run-operation (op)
  "Run the OP implementation registered for the current buffer's language.
Used by the interactive shared commands below."
  (if-let* ((command (my-ide-operation-command op)))
      (call-interactively command)
    (user-error "No `%s' command for %s" op major-mode)))

(defun my-ide-build ()
  "Build the current project with its language's build command."
  (interactive)
  (my-ide-run-operation 'build))

(defun my-ide-test ()
  "Run the current project's test suite with its language's test command."
  (interactive)
  (my-ide-run-operation 'test))

(defun my-ide-debug ()
  "Start the configured debugger for the current buffer's language."
  (interactive)
  (my-ide-run-operation 'debug))

(defun my-ide-lint ()
  "Run the current language's linter or static analyzer."
  (interactive)
  (my-ide-run-operation 'lint))

(defun my-ide-format ()
  "Format the code with the current language's formatter."
  (interactive)
  (my-ide-run-operation 'format))

;;; Shared Eglot setup

;; These hooks and fixes apply to every Eglot-managed buffer no matter
;; which language server it talks to; the language layers used to pick
;; them up from init-CIDE.el.

(defcustom my-ide-eglot-log-events nil
  "Non-nil keeps Eglot's per-server events buffer (for debugging).
The events buffer records every JSON-RPC message, which costs CPU and
memory with chatty servers such as clangd.  Leave it nil and turn it on
only while diagnosing a server problem."
  :type 'boolean
  :group 'tools)

;; The option has been `jsonrpc-default-request-timeout' since Emacs
;; 28.1 and this configuration requires 29.1, so no fallback name is
;; needed.  The declarations silence the byte compiler; the variables
;; themselves are defined when eglot loads jsonrpc.
(defvar jsonrpc-default-request-timeout)
(defvar eglot-autoshutdown)
(defvar eglot-extend-to-xref)

(defun my-ide-eglot-set-request-timeout (seconds)
  "Set the JSON-RPC request timeout used by Eglot to SECONDS.
A fresh language-server session on a large workspace can need more
than the 10s default for its first completion or xref answer
\\(rust-analyzer on yazi, clangd on a big Qt project); the request
then fails with a misleading \"Timed out\" error, so set it
generously."
  (setq jsonrpc-default-request-timeout seconds))

(with-eval-after-load 'eglot
  (setq eglot-autoshutdown t)

  ;; Verified on real projects: rust-analyzer's first completion in the
  ;; yazi workspace exceeded Emacs' 10s default timeout.
  (my-ide-eglot-set-request-timeout 60)

  ;; Jumping to a definition outside the project (a system header, say)
  ;; opens a file the project's server does not own.  Without this, the
  ;; language layers' `eglot-ensure' mode hooks would start another
  ;; server rooted at that file's directory, one per directory visited.
  (setq eglot-extend-to-xref t)

  (unless my-ide-eglot-log-events
    (cond
     ;; Emacs 30 / Eglot 1.17+: a plist of :size and :format.
     ((boundp 'eglot-events-buffer-config)
      (setq eglot-events-buffer-config
            (plist-put (copy-sequence eglot-events-buffer-config) :size 0)))
     ;; Emacs 29.
     ((boundp 'eglot-events-buffer-size)
      (setq eglot-events-buffer-size 0))))

  ;; Emacs 30.1's eglot returns the literal docstring
  ;; "LSP identifier at point" as the fallback of this method when not
  ;; prompting, so programmatic xref queries (for example evil's
  ;; `evil-goto-definition' xref backend, or any Lisp call to
  ;; `xref-find-definitions') send that junk string to the server and
  ;; every definition jump fails.  Return the symbol at point instead,
  ;; which is exactly what xref expects from this method.
  (cl-defmethod xref-backend-identifier-at-point ((_backend (eql eglot)))
    (or (thing-at-point 'symbol) ""))

  ;; Inlay hints (deduced types, parameter names) from the server.
  (add-hook 'eglot-managed-mode-hook #'my-ide-eglot-inlay-hints))

(defun my-ide-eglot-inlay-hints ()
  "Show inlay hints while Eglot manages the buffer, hide them afterwards.
On Emacs 30 `eglot-managed-mode-hook' runs when Eglot starts and when it
stops managing a buffer; on Emacs 29 it only runs on start, where Eglot
itself turns the mode off again.  Hooking `eglot-inlay-hints-mode'
directly would also call it on stop, where no server is left to ask for
:inlayHintProvider (the mode then signals instead of turning itself off)
and the hint overlays stay behind.  The mode still turns itself off when
the server lacks the capability."
  (when (fboundp 'eglot-inlay-hints-mode)
    (cond
     ((and (fboundp 'eglot-managed-p) (eglot-managed-p))
      (eglot-inlay-hints-mode 1))
     ((bound-and-true-p eglot-inlay-hints-mode)
      (eglot-inlay-hints-mode -1)))))

(defun my-ide-eglot-capf-first ()
  "Put the server's `completion-at-point' function before fallback sources.
`eglot-managed-mode-hook' runs both when Eglot starts and when it stops
managing a buffer.  Do nothing on stop: Eglot has just removed its
function and re-adding it would leave a dead capf behind."
  (when (and (fboundp 'eglot-completion-at-point)
             (fboundp 'eglot-managed-p)
             (eglot-managed-p))
    ;; completion-at-point-functions is a hook variable: its
    ;; buffer-local value ends with the hook's t marker (meaning "run
    ;; the global hook members after the local ones").  Rebuilding the
    ;; list by hand with setq-local can duplicate or misplace members
    ;; and must special-case the marker, so use add-hook rather than
    ;; rebuilding the list.  `add-hook' does nothing for a function
    ;; that is already a member, and Eglot has already added its own
    ;; entry; remove that first so the negative depth below really
    ;; moves the function to the front.
    (remove-hook 'completion-at-point-functions
                 #'eglot-completion-at-point t)
    (add-hook 'completion-at-point-functions
              #'eglot-completion-at-point -100 t)))
(add-hook 'eglot-managed-mode-hook #'my-ide-eglot-capf-first)

;;; Company backends

;; Emacs 30's `eglot--managed-mode' narrows `company-backends' to
;; '(company-capf) while the server manages the buffer and restores the
;; previous value on shutdown.  The language layers deliberately keep
;; fallback backends (company-dabbrev-code, company-files) behind
;; company-capf for positions where the server has no candidates, so
;; each layer registers its backends in the table below and this hook
;; re-applies them after Eglot's narrowing.  The hook runs after the
;; minor mode body, so it wins; on disconnect Eglot restores its saved
;; binding, which is the same layer backend list, so both sides agree.
(defvar my-ide-company-backends-table nil
  "Alist of (MODES . BACKENDS) registered by the language layers.
Filled by `my-ide-register-company-backends'.")

(defun my-ide-register-company-backends (modes backends)
  "Register BACKENDS as MODES' company completion backend list.
MODES is a list of major-mode symbols matched with `derived-mode-p',
mirroring `my-ide-register'.  `my-ide-restore-company-backends'
re-applies the registered backends after Eglot narrows them.
A second registration for the same MODES replaces the first."
  (setq my-ide-company-backends-table
        (cons (cons modes backends)
              (assoc-delete-all modes my-ide-company-backends-table
                                #'equal))))

(defun my-ide-company-backends ()
  "Return the company backends registered for the current buffer, or nil."
  (my-ide-find-entry my-ide-company-backends-table))

(defun my-ide-restore-company-backends ()
  "Re-apply the language layer's company backends in this Eglot buffer."
  (when-let* ((backends (my-ide-company-backends)))
    (setq-local company-backends backends)))
(add-hook 'eglot-managed-mode-hook #'my-ide-restore-company-backends)

;; Eglot reports diagnostics through Flymake; disable Flycheck in
;; Eglot-managed buffers so each diagnostic is not reported twice.
(defun my-ide-disable-flycheck ()
  "Turn Flycheck off in the current buffer when Eglot manages it."
  (when (and (bound-and-true-p flycheck-mode)
             (fboundp 'eglot-managed-p)
             (eglot-managed-p))
    (flycheck-mode -1)))
(add-hook 'eglot-managed-mode-hook #'my-ide-disable-flycheck)

;; Language layers also keep `global-flycheck-mode' out of their modes
;; from the start.  They must do it additively: a plain `setq' of
;; `flycheck-global-modes' in each layer would make the layer loaded
;; last silently undo the others.
(defvar flycheck-global-modes)

(defun my-ide-flycheck-modes-excluding (current modes)
  "Return the `flycheck-global-modes' value CURRENT with MODES excluded."
  (pcase current
    ('t (cons 'not (copy-sequence modes)))
    (`(not . ,old) (cons 'not (cl-union old modes)))
    ((pred consp) (cl-set-difference current modes))
    (_ current)))

(defun my-ide-flycheck-exclude (modes)
  "Keep Flycheck's global mode out of the major MODES, keeping other exclusions."
  (with-eval-after-load 'flycheck
    (setq flycheck-global-modes
          (my-ide-flycheck-modes-excluding flycheck-global-modes modes))))

;;; Apheleia and idle auto-save

;; `auto-save-visited-mode' (init-misc.el, 0.5s interval) saves through
;; `save-some-buffers', which runs `after-save-hook', so without this
;; advice apheleia would reformat the buffer during every idle pause.
;; `current-idle-time' is non-nil inside the idle auto-save timer but nil
;; while a user save command is running, so skip formatting only for
;; auto-saves.  A small threshold guards against edge cases where
;; `current-idle-time' returns a zero-length value.  This is language
;; neutral (every layer formats through apheleia), so it lives here
;; rather than in one language layer.
(defun my-apheleia-skip-auto-save (orig-fun &rest args)
  "Call ORIG-FUN with ARGS unless the save came from idle auto-save.
Skip apheleia formatting in that case."
  (if (and (current-idle-time)
           (> (float-time (current-idle-time)) 0.05))
      nil
    (apply orig-fun args)))

(with-eval-after-load 'apheleia
  ;; Apheleia's after-save entry point is spelled `apheleia--format-after-save'
  ;; in some versions and `apheleia-format-after-save' in others.  Advise
  ;; whichever exists, and warn if neither does: advice on an undefined
  ;; name is accepted silently and then never runs.
  (let ((advised nil))
    (dolist (function '(apheleia--format-after-save apheleia-format-after-save))
      (when (fboundp function)
        (advice-add function :around #'my-apheleia-skip-auto-save)
        (setq advised t)))
    (unless advised
      (display-warning
       'my-ide
       "Cannot find Apheleia's after-save function; idle auto-saves will reformat the buffer"))))

;;; Self-check

;; `M-x my-ide-doctor' (or `emacs --batch -l init.el -f my-ide-doctor')
;; reports whether this configuration is wired up on the current machine:
;; tree-sitter grammars, language servers and tools, the packages the
;; layers rely on, the shared-operation registry and the Eglot entries.
;; Missing optional programs are warnings; broken wiring is a failure.

;; Defined by eglot.el; the declaration silences the byte compiler for
;; the reference below.
(defvar eglot-server-programs)

(defun my-ide-doctor-report ()
  "Return rows (STATUS TOPIC MESSAGE) describing this IDE setup.
STATUS is `ok', `warn' (an optional piece is missing) or `fail' (the
configuration itself is not wired up)."
  (let (rows)
    (cl-flet* ((row (status topic format-string &rest args)
                 (push (list status topic (apply #'format format-string args))
                       rows))
               (tool (topic label path hint)
                 (row (if path 'ok 'warn) topic "%s: %s" label (or path hint))))
      ;; Emacs and tree-sitter.
      (row (if (version<= "29.1" emacs-version) 'ok 'fail)
           "emacs" "Emacs %s" emacs-version)
      (let ((ts (and (fboundp 'treesit-available-p) (treesit-available-p))))
        (if ts
            (row 'ok "tree-sitter" "available, runtime ABI %s"
                 (if (fboundp 'treesit-library-abi-version)
                     (treesit-library-abi-version)
                   "unknown"))
          (row 'warn "tree-sitter" "this Emacs has no tree-sitter support"))
        (when (and ts (fboundp 'treesit-language-available-p))
          (dolist (lang '(c cpp cmake python rust))
            (if (treesit-language-available-p lang)
                (row 'ok "grammar" "%s installed" lang)
              (row 'warn "grammar" "%s missing: %s" lang
                   (if (and (fboundp 'my-treesit--languages-to-install)
                            (memq lang (my-treesit--languages-to-install)))
                       "run M-x my-treesit-ensure-grammars"
                     "its language server is missing, so it is not auto-installed"))))))
      ;; Language servers.
      (tool "c/c++" "clangd"
            (executable-find (or (bound-and-true-p my-cpp-clangd-program)
                                 "clangd"))
            "not found, no C/C++ LSP")
      (tool "cmake" "language server"
            (and (fboundp 'my-cmake-langserver-exist) (my-cmake-langserver-exist))
            "not found (neocmakelsp or cmake-language-server)")
      (tool "rust" "rust-analyzer" (executable-find "rust-analyzer")
            "not found, no Rust LSP")
      (tool "python" "language server"
            (and (fboundp 'my-python-langserver-exist) (my-python-langserver-exist))
            "not found (basedpyright, pyrefly, pyright or pylsp)")
      ;; Other programs the layers call.
      (let (found missing)
        (dolist (program '("clang-format" "cppcheck" "gdb" "cmake" "make" "bear"
                           "cargo" "rustfmt" "ruff" "uv" "git" "cc" "c++"))
          (if (executable-find program)
              (push program found)
            (push program missing)))
        (row (if missing 'warn 'ok) "tools" "missing: %s; found: %s"
             (if missing (mapconcat #'identity (reverse missing) " ") "none")
             (if found (mapconcat #'identity (reverse found) " ") "none")))
      ;; Packages.
      (let ((missing (seq-remove
                      (lambda (feature)
                        (or (featurep feature)
                            (locate-library (symbol-name feature))))
                      '(company flycheck apheleia treesit-auto pyvenv
                        google-c-style rust-mode cmake-mode general evil eglot))))
        (if missing
            (row 'warn "packages" "not installed: %s"
                 (mapconcat #'symbol-name missing ", "))
          (row 'ok "packages" "all present")))
      ;; The shared-operation registry, per major mode.
      (dolist (mode '(c-mode c++-ts-mode objc-mode python-mode python-ts-mode
                      rust-mode rust-ts-mode cmake-mode cmake-ts-mode))
        (let* ((operations (if (memq mode '(cmake-mode cmake-ts-mode))
                               '(build test debug lint)
                             '(build test debug lint format)))
               (missing (with-temp-buffer
                          (setq-local major-mode mode)
                          (seq-remove #'my-ide-operation-command operations))))
          (row (if missing 'fail 'ok) "operations" "%s: %s" mode
               (if missing
                   (format "not registered: %s" missing)
                 (mapconcat #'symbol-name operations " ")))))
      ;; Eglot entries installed by the layers.
      (when (require 'eglot nil t)
        ;; Each check is (TOPIC MODES CONTACT): CONTACT is the function the
        ;; layer installs, or nil when any entry for MODES will do.
        (dolist (check (list
                        (list "c/c++" (bound-and-true-p my-cpp-modes)
                              'my-cpp-clangd-contact)
                        (list "rust" (bound-and-true-p my-rust-modes)
                              'my-rust-analyzer-contact)
                        (list "python" '(python-mode python-ts-mode) nil)
                        (list "cmake" '(cmake-mode cmake-ts-mode) nil)))
          (let* ((modes (nth 1 check))
                 (expected (nth 2 check))
                 (entry (and modes
                             (alist-get modes eglot-server-programs nil nil #'equal)))
                 ;; The layers register the contact with `#'FUNCTION',
                 ;; which Emacs 30 evaluates to the symbol and earlier
                 ;; Emacs to the function object; accept both forms.
                 (good (and entry
                             (or (null expected)
                                 (eq entry expected)
                                 (eq entry (ignore-errors
                                             (symbol-function expected)))))))
            (row (if good 'ok 'fail) "eglot" "%s entry %s" (car check)
                 (if good "installed" "missing or replaced by another entry")))))
      ;; Environment.
      (let* ((bin (file-name-as-directory
                   (expand-file-name "~/.local/bin")))
             ;; `exec-path-from-shell' keeps the trailing slash of a PATH
             ;; entry, so compare normalized directory names.
             (on-path (member bin
                              (mapcar #'file-name-as-directory exec-path))))
        (when (file-directory-p bin)
          (row (if on-path 'ok 'warn)
               "env" "~/.local/bin %s exec-path"
               (if on-path "is on" "is NOT on"))))
      (when (fboundp 'my-cpp-effective-parallel-jobs)
        (row 'ok "env" "C/C++ build jobs: %d; CARGO_BUILD_JOBS: %s"
             (my-cpp-effective-parallel-jobs)
             (or (getenv "CARGO_BUILD_JOBS") "unset")))
      (row (if (fboundp 'my-comma-leader-def) 'ok 'fail)
           "keys" "`my-comma-leader-def' %s"
           (if (fboundp 'my-comma-leader-def)
               "is defined"
             "is undefined: the leader keys cannot be bound")))
    (nreverse rows)))

(defun my-ide-doctor ()
  "Check this IDE configuration and show the result in *IDE doctor*.
In a batch session the report goes to standard output instead.  Return the
number of failures."
  (interactive)
  (let* ((rows (my-ide-doctor-report))
         (failures (seq-count (lambda (row) (eq (car row) 'fail)) rows))
         (warnings (seq-count (lambda (row) (eq (car row) 'warn)) rows))
         (text (concat
                (mapconcat
                 (lambda (row)
                   (format "[%-4s] %-13s %s"
                           (pcase (car row) ('ok "ok") ('warn "warn") (_ "FAIL"))
                           (nth 1 row) (nth 2 row)))
                 rows "\n")
                (format "\n\n%d failure(s), %d warning(s)\n" failures warnings))))
    (if noninteractive
        (princ text)
      (with-current-buffer (get-buffer-create "*IDE doctor*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text))
        (special-mode)
        (goto-char (point-min))
        (pop-to-buffer (current-buffer))))
    failures))

;;; Keybindings

;; The shared operations dispatch on the current buffer's language.
;; These keys stay global (usable in every buffer); the
;; language-specific layers share one prefix, "," "t", bound in their
;; respective mode maps (init-CIDE.el, init-rust.el) so the mode
;; decides which function fires.
;; Wait for init-evil rather than for evil itself (like init-python.el):
;; `my-comma-leader-def' is defined in init-evil.el, and evil finishes
;; loading inside it, before the definer exists.
(with-eval-after-load 'init-evil
  ;; Expand at run time: `my-comma-leader-def' is a macro without a
  ;; function cell, so a file compiled without init-evil loaded would
  ;; turn a direct call into a broken function call.
  (eval (macroexpand
         '(my-comma-leader-def
           "nb" #'my-ide-build
           ;; ,nc does not dispatch: `compile' is already language-neutral and
           ;; works in every buffer.  Formerly ,op; `my-compile' was removed
           ;; upstream (commit e5ab235a).
           "nc" #'compile
           "nt" #'my-ide-test
           "nd" #'my-ide-debug
           "nl" #'my-ide-lint
           "nf" #'my-ide-format))))

;; The LSP keys wait for Eglot since the commands come from it, and for
;; init-evil as well: if Eglot is already loaded when this file loads,
;; the first form runs at once, before `my-comma-leader-def' exists.
(with-eval-after-load 'eglot
  (with-eval-after-load 'init-evil
    ;; Expand at run time: `my-comma-leader-def' is a macro without a
    ;; function cell, so a file compiled without init-evil loaded would
    ;; turn a direct call into a broken function call.
    (eval (macroexpand
           '(my-comma-leader-def
             "nr" #'eglot-rename
             "na" #'eglot-code-actions
             ;; Find references (M-? also works; this is the comma-leader alias)
             "ni" #'xref-find-references
             "ne" #'eglot-reconnect)))))

(provide 'init-ide)
;;; init-ide.el ends here
