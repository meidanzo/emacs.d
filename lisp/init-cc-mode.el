;; -*- coding: utf-8; lexical-binding: t; -*-

    ;; emacs 设置tab键宽度为4个字符宽
    ;;  (启用自动缩进功能)
    ;;  (启用C语言缩进功能)
    ;;  (缩进宽度为4个字符宽)
    ;;  (打开语法高亮功能)
;;(setq-default c-default-style "stroustrup")


;; Tip 1: use more popular style "linux" instead of "gnu",
;;
;;   (setq c-default-style '((java-mode . "java")
;;                           (awk-mode . "awk")
;;                           (other . "linux")))

;; Tip 2: Search my article "C/C++/Java code indentation in Emacs"
;; My code might be obsolete, but the knowledge is still valid.kk
;;
;; C code example:
;;   if(1) // press ENTER here, zero means no indentation
;;   void fn() // press ENTER here, zero means no indentation

(defun my-common-cc-mode-setup ()
  "Setup shared by all languages (java/groovy/c++ ...)."
  ;; give me NO newline automatically after electric expressions are entered
  ;;默认设置:https://blog.csdn.net/nuaa_meteor/article/details/76653271
  (setq c-basic-offset 4)
  (setq c-auto-newline nil)
  (setq c-default-style "stroustrup")
  ;(setq indent-tabs-mode nil)
  ;make DEL take all previous whitespace with it
  (c-toggle-hungry-state 1))

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
  (setq c-electric-pound-behavior (quote (alignleft))))

(defun c-mode-common-hook-setup ()
  "C/C++ setup."
  (unless (my-buffer-file-temp-p)
    (my-common-cc-mode-setup)
    (unless (or (derived-mode-p 'java-mode) (derived-mode-p 'groovy-mode))
      (my-c-mode-setup))))
(add-hook 'c-mode-common-hook 'c-mode-common-hook-setup)

(provide 'init-cc-mode)
;;; init-cc-mode.el ends here
