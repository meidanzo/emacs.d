;;; init-ide.el --- language-neutral IDE operations  -*- lexical-binding: t; -*-
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
;;   4. Keybindings            "," + "n" shared keys
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
    ;; completion-at-point-functions is a hook variable: its
    ;; buffer-local value ends with the hook's t marker (meaning "run
    ;; the global hook members after the local ones").  Rebuilding the
    ;; list by hand with setq-local can duplicate or misplace members
    ;; and must special-case the marker, so use add-hook with a
    ;; negative depth instead; it conses the function onto the front
    ;; of the local hook and keeps the hook structure intact.
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
re-applies the registered backends after Eglot narrows them."
  (push (cons modes backends) my-ide-company-backends-table))

(defun my-ide-company-backends ()
  "Return the company backends registered for the current buffer, or nil."
  (catch 'my-ide-found
    (dolist (entry my-ide-company-backends-table)
      (when (apply #'derived-mode-p (car entry))
        (throw 'my-ide-found (cdr entry))))
    nil))

(defun my-ide-restore-company-backends ()
  "Re-apply the language layer's company backends in this Eglot buffer."
  (when-let* ((backends (my-ide-company-backends)))
    (setq-local company-backends backends)))
(add-hook 'eglot-managed-mode-hook #'my-ide-restore-company-backends)

;; Eglot reports diagnostics through Flymake; disable Flycheck in
;; Eglot-managed buffers so each diagnostic is not reported twice.
(defun my-ide-disable-flycheck ()
  (when (bound-and-true-p flycheck-mode)
    (flycheck-mode -1)))
(add-hook 'eglot-managed-mode-hook #'my-ide-disable-flycheck)

;;; Keybindings

;; The shared operations dispatch on the current buffer's language.
;; These keys stay global (usable in every buffer); the
;; language-specific layers share one prefix, "," "t", bound in their
;; respective mode maps (init-CIDE.el, init-rust.el) so the mode
;; decides which function fires.
(with-eval-after-load 'evil
  (my-comma-leader-def
    "nb" #'my-ide-build
    ;; ,nc does not dispatch: my-compile (init-essential.el) is already
    ;; language-neutral and works in every buffer.  Formerly ,op.
    "nc" #'my-compile
    "nt" #'my-ide-test
    "nd" #'my-ide-debug
    "nl" #'my-ide-lint
    "nf" #'my-ide-format))

;; The LSP keys wait for Eglot since the commands come from it.
(with-eval-after-load 'eglot
  (my-comma-leader-def
    "nr" #'eglot-rename
    "na" #'eglot-code-actions
    ;; Find references (M-? also works; this is the comma-leader alias)
    "ni" #'xref-find-references
    "ne" #'eglot-reconnect))

(provide 'init-ide)
;;; init-ide.el ends here
