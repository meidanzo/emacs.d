;; -*- coding: utf-8; lexical-binding: t; -*-

;; Tip 1: use more popular style "linux" instead of "gnu",
;;
;;   (setq c-default-style '((java-mode . "java")
;;                           (awk-mode . "awk")
;;                           (other . "linux")))

;; Tip 2: Search my article "C/C++/Java code indentation in Emacs"
;; My code might be obsolete, but the knowledge is still valid.
;;
;; C code example:
;;   if(1) // press ENTER here, zero means no indentation
;;   void fn() // press ENTER here, zero means no indentation
(require 'google-c-style)

(defun my-common-cc-mode-setup ()
  "Setup shared by all languages (java/groovy/c++ ...)."

  ;make DEL take all previous whitespace with it
  (c-toggle-auto-hungry-state 1)

  ;; give me NO newline automatically after electric expressions are entered
  ;;默认设置:https://blog.csdn.net/nuaa_meteor/article/details/76653271
  (setq c-auto-newline nil))

(defun my-c-mode-setup ()
  "C/C++ only setup."
  ;; @see http://stackoverflow.com/questions/3509919/ \
  ;; emacs-c-opening-corresponding-header-file
  ;; Use `ff-find-other-file' to open C/C++ header

  (setq cc-search-directories '("." "/usr/include" "/usr/local/include/*" "../*/include" "$WXWIN/include"))

  ;; In theory, you can write your own Makefile for `flymake-mode' without cmake.
  ;; Nobody actually does it in real world.

  ;; Browse Emacs' C code
  (push '(nil "^DEFUN *(\"\\([a-zA-Z0-9-]+\\)" 1) imenu-generic-expression )

  ;; make a #define be left-aligned
  (setq c-electric-pound-behavior (quote (alignleft)))

  ;; google-style设置
  (google-set-c-style)
  (google-make-newline-indent)
  (setq c-basic-offset 4)

  ;;多个缓冲区进行gdb，@see http://tuhdo.github.io/c-ide.html
  (setq gdb-many-windows t  ;; use gdb-many-windows by default
        gdb-show-main t))    ;; Non-nil means display source file containing the main routine at startup

(defun c-mode-common-hook-setup ()
  "C/C++ setup."
  (unless (my-buffer-file-temp-p)
    (my-common-cc-mode-setup)
    (unless (or (derived-mode-p 'java-mode) (derived-mode-p 'groovy-mode))
      (my-c-mode-setup))))
(add-hook 'c-mode-common-hook 'c-mode-common-hook-setup)

(provide 'init-cc-mode)
;;; init-cc-mode.el ends here
