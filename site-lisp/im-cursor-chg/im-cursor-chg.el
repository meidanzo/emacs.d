;;; im-cursor-chg.el --- Change cursor color for input method  -*- lexical-binding: t; -*-

;; Inspired by code from cursor-chg
;; URL: https://github.com/emacsmirror/cursor-chg/blob/master/cursor-chg.el
;; URL: https://github.com/Eason0210/im-cursor-chg
;; LICENSE: https://www.emacswiki.org/

;;; Commentary:
;;
;; This package is compatible with GNU Emacs 30.1 and later.  It handles
;; dynamic cursor color changes based on input method state and Evil visual mode.
;; Tested for robustness in daemon and terminal modes.
;;
;; This software package must be used with Emacs-rime and must
;; be loaded after Emacs-rime has been loaded.
;;
;; To turn on the cursor color change by default,
;; put the following in your Emacs init file.
;;
;; (require 'im-cursor-chg)
;; (cursor-chg-mode 1)
;;

;;; Code:

(require 'rime nil t)
(require 'evil nil t)

(defvar im-cursor-color "orange"
  "The color for input method.")

(defvar im-default-cursor-color nil
  "The default cursor color.  Initialized lazily to handle daemon mode.")

(defvar im-visual-cursor-color "green"
  "The cursor color in Evil visual state.")

(defun im--terminal-default-color ()
  "Setup terminal color."
  (if (and (stringp im-default-cursor-color)
           (string= im-default-cursor-color "black"))
      "white"
    (or im-default-cursor-color "white")))


(defun im--ensure-default-cursor-color ()
  "Lazily initialize `im-default-cursor-color`."
  (unless (stringp im-default-cursor-color)
    (setq im-default-cursor-color
          (or (frame-parameter nil 'cursor-color) "white"))))


(defun im--chinese-p ()
  "Check if the current input state is Chinese."
  (if (featurep 'rime)
      (and (rime--should-enable-p)
           (not (rime--should-inline-ascii-p))
           current-input-method)
    current-input-method))

(defun im--evil-visual-p ()
  "Check if current state is Evil visual state."
  (and (featurep 'evil)
       (fboundp 'evil-visual-state-p)
       (evil-visual-state-p)))

(defun im--send-terminal-cursor-color (color)
  "Function wrapping, but only effective for certain terminal emulators.
COLOR: Input variables"
  (send-string-to-terminal
   (format "\e]12;%s\a" color)))

(defun im--current-cursor-color ()
  "Return the cursor color according to current state."
  (im--ensure-default-cursor-color)
  (cond
   ((im--evil-visual-p) im-visual-cursor-color)
   ((im--chinese-p) im-cursor-color)
   (t (if (display-graphic-p)
          im-default-cursor-color
        (im--terminal-default-color)))))


(defun gui-cursor-color ()
  "GUI Emacs cursor color."
  (set-cursor-color (im--current-cursor-color)))

;;; 注意:  rainbow-delimiters-mode, show-paren-mode 会遮盖绿色.
(defun terminal-cursor-color ()
  "Terminal Emacs cursor color."
  (im--send-terminal-cursor-color (im--current-cursor-color)))


(defun terminal-restore-cursor-color ()
  "Restore terminal cursor color."
  (unless (display-graphic-p)
    (im--send-terminal-cursor-color (im--terminal-default-color))))

(defun terminal-restore-before-exit (&rest _)
  "Exit terminal Emacs restore terminal color."
  (terminal-restore-cursor-color))

; exit emacs
(add-hook 'kill-emacs-hook #'terminal-restore-cursor-color t)
; suspend emacs
(add-hook 'suspend-hook #'terminal-restore-cursor-color t)
; daemon/client, exit emacsclient
(advice-add 'save-buffers-kill-terminal
            :before
            #'terminal-restore-before-exit)


(defun im-change-cursor-color ()
  "Set cursor color depending on input method."
  (interactive)
  (if (display-graphic-p)
      (gui-cursor-color)
    (terminal-cursor-color)))

(define-minor-mode cursor-chg-mode
  "Toggle changing cursor color.
With numeric ARG, turn cursor changing on if ARG is positive.
When this mode is on, `im-change-cursor-color' control cursor changing."
  :init-value nil :global t :group 'frames
  (if cursor-chg-mode
      (add-hook 'post-command-hook #'im-change-cursor-color t)
    (remove-hook 'post-command-hook #'im-change-cursor-color)))


(provide 'im-cursor-chg)
;;; im-cursor-chg.el ends here
