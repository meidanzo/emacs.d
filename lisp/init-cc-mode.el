;;; init-cc-mode.el --- C/C++/CMake editing setup -*- lexical-binding: t; -*-
;; Copyright (C) 2026 meidanzo <meidanzo@foxmail.com> and others
;; Derived from redguardtoo/emacs.d (GPL-3.0-or-later); modified by meidanzo, 2026.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Editing-level setup for C/C++/CMake buffers:
;;   1. C/C++ (cc-mode)     Google style, 4-space indent
;;   2. C/C++ (tree-sitter) same 4-space indent for c-ts-mode/c++-ts-mode
;;   3. CMake                imenu index for both cmake-mode and cmake-ts-mode
;; GDB window layout (gdb-many-windows, gdb-show-main) lives in
;; init-CIDE.el's debugging section.
;;; Code:

(require 'google-c-style)

;; Tip 1: use more popular style "linux" instead of "gnu",
;;
;;   (setq c-default-style '((java-mode . "java")
;;                           (awk-mode . "awk")
;;                           (other . "linux")))

;;; C/C++: cc-mode

;; Defined by find-file.el (a defcustom); the declaration silences the
;; byte compiler for the reference inside `with-eval-after-load'.
(defvar cc-search-directories)

;; Directories searched by `ff-find-other-file' for headers.  Added to the
;; default list once find-file.el loads, not from the per-buffer hook below
;; and not with a plain `setq': init-CIDE.el appends its own directories the
;; same way, and a `setq' here would wipe them whenever this file happened
;; to load after find-file.el.
(with-eval-after-load 'find-file
  (dolist (directory '("../*/include" "$WXWIN/include"))
    (add-to-list 'cc-search-directories directory t)))

;; Defined by cc-mode.el, which loads on the first classic C/C++ buffer;
;; the declarations silence the byte compiler for the functions below.
;; `c-toggle-auto-hungry-state' itself is defined in cc-cmds.el, which
;; cc-mode.el requires (check-declare finds it there, not in cc-mode.el).
(defvar c-auto-newline)
(defvar c-electric-pound-behavior)
(defvar c-basic-offset)
(declare-function c-toggle-auto-hungry-state "cc-cmds")

(defun my-common-cc-mode-setup ()
  "Setup shared by all languages (java/groovy/c++ ...)."
  ;; Make DEL take all previous whitespace with it.
  (c-toggle-auto-hungry-state 1)
  ;; No automatic newline after electric expressions are entered.
  (setq c-auto-newline nil))

(defun my-c-mode-setup ()
  "C/C++ only setup."
  ;; Browse Emacs' C code.
  (push '(nil "^DEFUN *(\"\\([a-zA-Z0-9-]+\\)" 1) imenu-generic-expression)

  ;; Make a #define be left-aligned.
  (setq c-electric-pound-behavior (quote (alignleft)))

  ;; Google style with a four-space indent (Google defaults to 2).
  (google-set-c-style)
  (google-make-newline-indent)
  (setq c-basic-offset 4
        indent-tabs-mode nil))

(defun c-mode-common-hook-setup ()
  "C/C++ setup."
  (unless (my-buffer-file-temp-p)
    (my-common-cc-mode-setup)
    (unless (or (derived-mode-p 'java-mode) (derived-mode-p 'groovy-mode))
      (my-c-mode-setup))))
(add-hook 'c-mode-common-hook 'c-mode-common-hook-setup)

;;; C/C++: tree-sitter modes

(defun my-c-ts-mode-setup ()
  "Use four-space indentation in tree-sitter C/C++ modes."
  (setq-local c-ts-mode-indent-offset 4
              indent-tabs-mode nil))
(add-hook 'c-ts-mode-hook #'my-c-ts-mode-setup)
(add-hook 'c++-ts-mode-hook #'my-c-ts-mode-setup)

;;; CMake

(defun my-cmake-mode-imenu-setup ()
  "Imenu setup for `cmake-mode' and `cmake-ts-mode'.
`cmake-ts-mode' has no built-in imenu rules, so the same regex-based
index is installed for both modes.  Use `setq-local' so the value
stays in the buffer instead of clobbering the global default."
  (setq-local imenu-generic-expression
              '(("Functions" "^\\s-*function\\s-*(\\s-*\\([a-zA-Z0-9_]+\\)" 1)
                ("Macros"    "^\\s-*macro\\s-*(\\s-*\\([a-zA-Z0-9_]+\\)" 1)
                ("Targets"   "^\\s-*add_\\(?:executable\\|library\\)\\s-*(\\s-*\\([a-zA-Z0-9_]+\\)" 1)
                ("Options"   "^\\s-*option\\s-*(\\s-*\\([a-zA-Z0-9_]+\\)" 1))))

(add-hook 'cmake-mode-hook #'my-cmake-mode-imenu-setup)
(add-hook 'cmake-ts-mode-hook #'my-cmake-mode-imenu-setup)
(provide 'init-cc-mode)
;;; init-cc-mode.el ends here
