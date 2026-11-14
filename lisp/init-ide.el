;;; init-ide.el --- language-neutral IDE operations  -*- lexical-binding: t; -*-
;;; Commentary:
;; The shared intersection (set C) of the language IDE layers: one key
;; does one thing in every supported language project.  Each language
;; layer (init-CIDE.el, init-rust.el, ...) registers its own
;; implementation of the operations below with `my-ide-register', and
;; keeps its language-specific keys under its own leader prefix.
;;
;; Shared "," + "o" keys:
;;   ,ob build   ,oT test   ,od debug
;;   ,oP lint    ,of format
;;   ,or rename  ,oa code actions  ,oi references  ,oR reconnect
;;
;; Definition jump (`,vv' evil-goto-definition) is already bound
;; globally in init-evil.el.  To add another language, register its
;; commands from its own init file; nothing here needs to change.
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
;;   4. Keybindings            "," + "o" shared keys
;;; Code:

(require 'subr-x)

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
OP is a symbol naming an operation, such as `build' or `debug'."
  (setf (alist-get op my-ide-operation-table)
        (cons (cons modes command)
              (alist-get op my-ide-operation-table))))

(defun my-ide-operation-command (op)
  "Return the command registered for OP in the current buffer, or nil."
  (catch 'my-ide-found
    (dolist (implementation (alist-get op my-ide-operation-table))
      (when (apply #'derived-mode-p (car implementation))
        (throw 'my-ide-found (cdr implementation))))
    nil))

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
  "Run the current project's tests with its language's test command."
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

(with-eval-after-load 'eglot
  (setq eglot-autoshutdown t)

  ;; Emacs 30.1's eglot returns the literal docstring
  ;; "LSP identifier at point" as the fallback of this method when not
  ;; prompting, so programmatic xref queries (for example evil's
  ;; `evil-goto-definition' xref backend, or any Lisp call to
  ;; `xref-find-definitions') send that junk string to the server and
  ;; every definition jump fails.  Return the symbol at point instead,
  ;; which is exactly what xref expects from this method.
  (cl-defmethod xref-backend-identifier-at-point ((_backend (eql eglot)))
    (or (thing-at-point 'symbol) ""))

  ;; Inlay hints (deduced types, parameter names) from the server.  The
  ;; mode turns itself off when the server lacks :inlayHintProvider.
  (when (fboundp 'eglot-inlay-hints-mode)
    (add-hook 'eglot-managed-mode-hook #'eglot-inlay-hints-mode)))

(defun my-ide-eglot-capf-first ()
  "Put the server's completion-at-point function before fallback sources."
  (when (fboundp 'eglot-completion-at-point)
    (setq-local completion-at-point-functions
                (cons #'eglot-completion-at-point
                      (remove #'eglot-completion-at-point
                              completion-at-point-functions)))))
(add-hook 'eglot-managed-mode-hook #'my-ide-eglot-capf-first)

;; Eglot reports diagnostics through Flymake; disable Flycheck in
;; Eglot-managed buffers so each diagnostic is not reported twice.
(defun my-ide-disable-flycheck ()
  (when (bound-and-true-p flycheck-mode)
    (flycheck-mode -1)))
(add-hook 'eglot-managed-mode-hook #'my-ide-disable-flycheck)

;;; Keybindings

;; The shared operations dispatch on the current buffer's language.
(with-eval-after-load 'evil
  (my-comma-leader-def
    "ob" #'my-ide-build
    "oT" #'my-ide-test
    "od" #'my-ide-debug
    "oP" #'my-ide-lint
    "of" #'my-ide-format))

;; The LSP keys wait for Eglot since the commands come from it.
(with-eval-after-load 'eglot
  (my-comma-leader-def
    "or" #'eglot-rename
    "oa" #'eglot-code-actions
    ;; Find references (M-? also works; this is the comma-leader alias)
    "oi" #'xref-find-references
    "oR" #'eglot-reconnect))

(provide 'init-ide)
;;; init-ide.el ends here
