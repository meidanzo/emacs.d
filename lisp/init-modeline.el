;; -*- coding: utf-8; lexical-binding: t; -*-

;; @see http://emacs-fu.blogspot.com/2011/08/customizing-mode-line.html
;; @see http://www.delorie.com/gnu/docs/elisp-manual-21/elisp_360.html
;; use setq-default to set it for /all/ modes

;; ---------------------------------------------------------------------------
;; doom-modeline segments (vcs / check / debug)
;; 只加载 doom-modeline的 `vcs'、`check' 和 `debug' segment
;; ---------------------------------------------------------------------------

(defun my-doom-modeline-setup ()
  "Load doom-modeline and install the hooks its segments need.
Errors are caught so a broken package cannot prevent the rest of the
mode line from being configured."
  (condition-case err
      (progn
        (require 'doom-modeline)
        ;; 只要这些 segment，不需要语言版本探测，避免 Python/Ruby 等 buffer 启动子进程。
        (setq doom-modeline-env-version nil)
        ;; 原有 mode line 在每个窗口显示相同内容，让 check/debug 也保持一致，
        ;; 不随窗口是否选中而消失。
        (setq doom-modeline-always-visible-segments '(check debug))
        ;; 不要在窄窗口里隐藏 debug、截断 vcs/check，保持所有窗口一致。
        (setq doom-modeline-window-width-limit nil)
        ;; `check'/`debug' segment 用 `doom-modeline--active' 区分活动/非活动窗口。
        ;; 通常由 `doom-modeline-mode' 安装这些 hook，这里手动安装。
        (add-hook 'window-selection-change-functions
                  #'doom-modeline-set-selected-window)
        (if (boundp 'after-focus-change-function)
            (add-function :after after-focus-change-function #'doom-modeline-focus-change)
          (with-no-warnings
            (add-hook 'focus-in-hook #'doom-modeline-set-selected-window)
            (add-hook 'focus-out-hook #'doom-modeline-unset-selected-window)))
        (doom-modeline-set-selected-window)
        (force-mode-line-update t))
    (error (message "my-doom-modeline-setup: %S" err))))

(if (ignore-errors (require 'doom-modeline nil t))
    (my-doom-modeline-setup)
  ;; daemon/非交互启动时，包激活发生在 init.el 更靠后的位置（init-elpa）。
  (add-hook 'after-init-hook #'my-doom-modeline-setup))

;; 如果 `find-file-hook' 中的 VC 检测被禁用，只在本地 Git 仓库里补一次，
;; 保证 `vc-mode' 有值，VCS segment 才能显示。
(defun my-doom-modeline-vcs-find-file-hook ()
  "Populate `vc-mode' for local Git files when VC auto-detection is off."
  (when (and buffer-file-name
             (not (file-remote-p buffer-file-name))
             (not vc-mode)
             (locate-dominating-file buffer-file-name ".git"))
    (vc-refresh-state)))
(add-hook 'find-file-hook #'my-doom-modeline-vcs-find-file-hook)

;; 文件在外部被修改时，让 auto-revert 同步 VC 状态。
(setq auto-revert-check-vc-info t)

(defvar my-extra-mode-line-info '()
  "Extra info displayed at the end of the mode line.")

(setq-default
 mode-line-format
 '("%b" ;; the buffer name

   (:eval " (%l,%C) ")

   "["

   ;; major mode, please note "%m" is legacy format since emacs 28
   (:eval (if (stringp mode-name)
              mode-name
            (format "%s" (if (consp mode-name) (car mode-name) mode-name))))

   ;; buffer file encoding
   (:eval (let ((sys (coding-system-plist buffer-file-coding-system)))
            (format " %s "
                    (if (memq (plist-get sys :category)
                              '(coding-category-undecided coding-category-utf-8))
                        "UTF-8"
                      (upcase (symbol-name (plist-get sys :name)))))))

   (:eval (propertize (concat (if overwrite-mode "O" "I")
                              (and (buffer-modified-p) "M")
                              (and buffer-read-only "R"))
                      'face
                      'font-lock-keyword-face))

   "]"

   ;; doom-modeline 的 debug/vcs/check segment 都自带前后空格，没有内容时为空。
   ;; 顺序与 doom-modeline 默认的一致：debug 在 vcs 前，check 在 vcs 后。
   (:eval (and (fboundp 'doom-modeline-segment--debug)
               (doom-modeline-segment--debug)))

   ;; VCS segment 不在仓库中时返回 nil，用 " " 兜底，避免后面的内容贴到 "]".
   (:eval (or (and (fboundp 'doom-modeline-segment--vcs)
                   (doom-modeline-segment--vcs))
              " "))

   (:eval (and (fboundp 'doom-modeline-segment--check)
               (doom-modeline-segment--check)))

   ;; `org-timer-set-timer' uses it
   (:eval mode-line-misc-info)

   (:eval my-extra-mode-line-info)

   mode-line-end-spaces
   ))

(with-eval-after-load 'time
  ;; Donot show system load in mode line
  (setq display-time-default-load-average nil)
  ;; By default, the file in environment variable MAIL is checked
  ;; It's "/var/mail/my-username"
  ;; I set `display-time-mail-function' to display NO mail notification in mode line
  (setq display-time-mail-function (lambda () nil)))

(provide 'init-modeline)
