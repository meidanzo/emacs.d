;;; early-init.el ---   -*- lexical-binding: t -*-

;; Copyright (C) 2022 Chen Bin
;;
;; Keywords: keyword1 keyword2
;; Author: Chen Bin <chenbin@gmail.com>

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(when (or (featurep 'esup-child)
          (fboundp 'profile-dotemacs)
          (daemonp)
          (boundp 'startup-now)
          noninteractive)
  (setq package-enable-at-startup nil))

;; Make user-installed binaries available even when Emacs is started
;; from a desktop environment with a minimal PATH.
(let ((local-bin (expand-file-name "~/.local/bin"))
      (sep (if (characterp path-separator)
               (char-to-string path-separator)
             path-separator)))
  (when (file-directory-p local-bin)
    (add-to-list 'exec-path local-bin)
    (let ((dirs (parse-colon-path (or (getenv "PATH") ""))))
      (unless (member (file-name-as-directory local-bin) dirs)
        (setenv "PATH"
                (mapconcat #'identity
                           (cons local-bin dirs)
                           sep))))))

(defvar my-computer-has-smaller-memory-p nil
  "Installing&Compiling many packages could cost too much memory.")

;; @see https://www.reddit.com/r/emacs/comments/ofhket/further_boost_start_up_time_with_a_simple_tweak/
;; 10% speed up of startup for my configuration
(unless my-computer-has-smaller-memory-p
  (setq gc-cons-percentage 0.6)
  (setq gc-cons-threshold most-positive-fixnum))

;; {{ Character encoding
;; 统一使用 UTF-8 编码
(prefer-coding-system 'utf-8)
(set-default-coding-systems 'utf-8)
;; 新建文件默认使用 UTF-8 Unix 换行符
(setq-default buffer-file-coding-system 'utf-8-unix)
;; }}

(setq read-process-output-max (* 1024 1024)) ;; <=$(cat /proc/sys/fs/pipe-max-size)

;; 加载策略
(setq load-prefer-newer t)   ; 让修改后的 .el 优先于旧的 .elc

;; 显示与交互性能优化
(setq-default bidi-display-reordering t)
(setq-default bidi-paragraph-direction 'left-to-right)
(setq bidi-inhibit-bpa t)
(setq redisplay-skip-fontification-on-input t)           ;; Skip Fontification During Input

(setq inhibit-startup-screen t)

;; no menu bar, toolbar, scroll bar
(setq default-frame-alist
      '((menu-bar-lines . 0)
        (tool-bar-lines . 0)
        (horizontal-scroll-bars)
        (vertical-scroll-bars)))

(provide 'early-init)
;;; early-init.el ends here
