;; -*- coding: utf-8; lexical-binding: t; -*-
;; Derived from redguardtoo/emacs.d (GPL-3.0-or-later).
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(defvar ispell-program-name)

(defvar my-default-spell-check-language "en_US"
  "Language used by aspell and hunspell CLI.")

(with-eval-after-load 'flyspell
  ;; You can also use "M-x ispell-word" or hotkey "M-$". It pop up a multiple choice
  ;; @see http://frequal.com/Perspectives/EmacsTip03-FlyspellAutoCorrectWord.html
  (global-set-key (kbd "C-c s") 'flyspell-auto-correct-word)

  ;; better performance
  (setq flyspell-issue-message-flag nil))

  ;; flyspell-lazy is outdated and conflicts with latest flyspell

;; Basic Logic Summary:
;; If (aspell is installed) { use aspell}
;; else if (hunspell is installed) { use hunspell }
;; English dictionary is used.
;;
;; I prefer aspell because:
;; - aspell is very stable and easy to install
;; - looks Kevin Atkinson still get some road map for aspell:
;; @see http://lists.gnu.org/archive/html/aspell-announce/2011-09/msg00000.html
(defun my-detect-ispell-args (&optional run-together)
  "If RUN-TOGETHER is true, spell check the CamelCase words.
RUN-TOGETHER makes aspell less capable to find plain English typo.
So it should be used in `prog-mode-hook' only."
  (let* (args)
    (when ispell-program-name
      (cond
       ;; use aspell
       ((string-match "aspell" ispell-program-name)
        ;; force the English dictionary, support Camel Case spelling check (tested with aspell 0.6)
        ;; For aspell's option "--lang", "two letter ISO 3166 country code after a underscore" is OPTIONAL.
        (setq args (list "--sug-mode=ultra" (format "--lang=%s" my-default-spell-check-language)))
        ;; "--run-together-min" could not be 3, see `check` in "speller_impl.cpp".
        ;; The algorithm is not precise.
        ;; Run `echo tasteTableConfig | aspell --lang=en_US -C --run-together-limit=16  --encoding=utf-8 -a` in shell.
        (when run-together
          (cond
           ;; Kevin Atkinson said now aspell supports camel case directly
           ;; https://github.com/redguardtoo/emacs.d/issues/796
           ((string-match "--.*camel-case"
                            (shell-command-to-string (concat ispell-program-name " --help")))
            (setq args (append args '("--camel-case"))))

           ;; old aspell uses "--run-together". Please note we are not dependent on this option
           ;; to check camel case word. wucuo is the final solution. This aspell options is just
           ;; some extra check to speed up the whole process.
           (t
            (setq args (append args '("--run-together" "--run-together-limit=16")))))))

       ;; use hunspell
       ((string-match "hunspell" ispell-program-name)
        (setq args nil))))
    args))

;; Aspell Setup (recommended):
;; It's easy to set up aspell. So the details are skipped.
;;
;; Hunspell Setup:
;; 1. Install hunspell from http://hunspell.sourceforge.net/
;;
;; 2. Download openoffice dictionary extension from
;; http://extensions.openoffice.org/en/project/english-dictionaries-apache-openoffice
;;
;; 3. Say `dict-en.oxt' is downloaded. Rename it to `dict-en.zip' and unzip
;; the contents to a temporary folder. Got "en_US.dic" and "en_US.aff" in
;; that folder.
;;
;; 4. Hunspell's option "-d en_US" means finding dictionary "en_US"
;; Modify `ispell-local-dictionary-alist' to set that option of hunspell
;;
;; 5. Copy "en_US.dic" and "en_US.aff" from that temporary folder to
;; the place for dictionary files. I use "~/usr_local/share/hunspell/".
;;
;; 6. Add that folder to shell environment variable "DICPATH"
;;
;; 7. Restart emacs so when hunspell is run by ispell/flyspell to make
;; "DICPATH" take effect
;;
;; hunspell searches a dictionary named "en_US" in the path specified by
;; "DICPATH" by default.

(defvar my-force-to-use-hunspell nil
  "Force to use hunspell.  If nil, try to detect aspell&hunspell.")

(defun my-configure-ispell-parameters ()
  "Set `ispell-program-name' and other parameters."
  (cond
   ;; use aspell
   ((and (not my-force-to-use-hunspell) (executable-find "aspell"))
    (setq ispell-program-name "aspell"))

   ;; use hunspell
   ((executable-find "hunspell")
    (setq ispell-program-name "hunspell")
    (setq ispell-local-dictionary my-default-spell-check-language)
    (setq ispell-local-dictionary-alist
          (list (list my-default-spell-check-language
                      "[[:alpha:]]" "[^[:alpha:]]" "[']"
                      nil
                      (list "-d" my-default-spell-check-language)
                      nil
                      'utf-8)))
    ;; New variable `ispell-hunspell-dictionary-alist' is defined in Emacs
    ;; If it's nil, Emacs tries to automatically set up the dictionaries.
    (when (boundp 'ispell-hunspell-dictionary-alist)
      (setq ispell-hunspell-dictionary-alist ispell-local-dictionary-alist)))

   (t (setq ispell-program-name nil)
      (message "You need install either aspell or hunspell for ispell"))))

;; You could define your own configuration and call `my-configure-ispell-parameters' in "~/.custom.el"
(my-configure-ispell-parameters)

(defvar wucuo-flyspell-start-mode)
(declare-function wucuo-spell-check-internal "wucuo")

(defun my-spell-check-buffer ()
  "Spell check current buffer with wucuo."
  (interactive)
  (unless (and (stringp ispell-program-name)
               (executable-find ispell-program-name)
               (string-match-p "\\(?:aspell\\|hunspell\\)\\(?:\\.exe\\)?\\'"
                               ispell-program-name))
    (user-error "Spell checking unavailable.  Install aspell or hunspell and restart Emacs"))
  (my-ensure 'wucuo)
  (unless (fboundp 'wucuo-spell-check-internal)
    (user-error "Spell checking unavailable.  Failed to load wucuo"))
  (let ((wucuo-flyspell-start-mode "normal"))
    (wucuo-spell-check-internal)))

(defun my-ispell-word-hack (orig-func &rest args)
  "Use Emacs original arguments when calling `ispell-word'.
When fixing a typo, avoid pass camel case option to cli program.
ORIG-FUNC and ARGS are used."
  (let* ((old-ispell-extra-args ispell-extra-args))
    (ispell-kill-ispell t)
    ;; use emacs original arguments
    (setq ispell-extra-args (my-detect-ispell-args))
    (apply orig-func args)
    ;; restore our own ispell arguments
    (setq ispell-extra-args old-ispell-extra-args)
    (ispell-kill-ispell t)))
(advice-add 'ispell-word :around #'my-ispell-word-hack)
(advice-add 'flyspell-auto-correct-word :around #'my-ispell-word-hack)

(defvar my-disable-wucuo nil
  "Disable wucuo.")

(defun text-mode-hook-setup ()
  "Set up text mode."
  ;; Turn off RUN-TOGETHER option when spell check text.
  (unless my-disable-wucuo
    (setq-local ispell-extra-args (my-detect-ispell-args))
    (my-ensure 'wucuo)
    (wucuo-start)))
(add-hook 'text-mode-hook 'text-mode-hook-setup)

(defun my-clean-aspell-dict ()
  "Clean ~/.aspell.pws (dictionary used by aspell)."
  (interactive)
  (let* ((dict (file-truename "~/.aspell.en.pws"))
         (lines (my-read-lines dict))
         ;; sort words
         (aspell-words (sort (cdr lines) 'string<)))
    (save-buffer)
    (sit-for 1)
    (with-temp-file dict
      (insert (format "%s %d\n%s"
                        "personal_ws-1.1 en"
                        (length aspell-words)
                        (mapconcat 'identity aspell-words "\n"))))))


(with-eval-after-load 'wucuo
  ;; {{ wucuo is used to check camel cased code and plain text.  Code is usually written
  ;; in English. If your code uses other language (Spanish?),
  ;; Un-comment and modify below two lines:

  ;; (setq wucuo-aspell-language-to-use "en")
  ;; (setq wucuo-hunspell-dictionary-base-name "en_US")

  ;; }}

  (setq wucuo-spell-check-buffer-predicate
        (lambda ()
          ;; don't spell check buffer created by gptel
          (not (string-match "\\*AI " (or (buffer-name) "")))))
  ;; do NOT turn on `flyspell-mode' automatically.
  ;; check buffer or visible region only
  ;; spell check buffer every 30 seconds
  (setq wucuo-update-interval 2))

;; {{ 消除 "Blocking call to accept-process-output with quit inhibited!!"
;; wucuo 的检查只由 `after-save-hook' 触发 (见 `wucuo-mode-on'), 而本配置中
;; auto-save-visited-mode (init-misc.el) 由 idle timer 每 0.5 秒空闲调用
;; `save-some-buffers'. Emacs 的 timer 回调运行在 `inhibit-quit' 为 t 的
;; 上下文 (keyboard.c 中 timer handler 前 specbind), 于是 wucuo ->
;; `flyspell-buffer' -> `flyspell-region' -> `flyspell-external-point-words'
;; -> `flyspell-word' 内部等待 ispell 响应的无超时
;; `(accept-process-output ispell-process)' (flyspell.el, "Wait until ispell
;; has processed word.") 满足 process.c 的警告条件, 每检查一个错词就打印一次
;; "Blocking call to accept-process-output with quit inhibited!!".
;; 用 `with-local-quit' 包裹 `flyspell-word': 进入时临时允许 quit, 警告条件
;; 随之消失, 且 C-g 可以中断卡住的 ispell 查询. 这与上游
;; `flyspell-post-command-hook' 用 `with-local-quit' 包裹拼写检查的做法一致.
(defun my-flyspell-word-with-local-quit (orig-fun &rest args)
  "Call ORIG-FUN with quitting temporarily allowed.

ORIG-FUN is `flyspell-word'; ARGS are passed through unchanged.
Used as :around advice so that the blocking wait inside
`flyspell-word' neither triggers the C-level \"Blocking call to
accept-process-output with quit inhibited!!\" warning nor hangs
uninterruptibly when called from idle timers."
  (with-local-quit
    (apply orig-fun args)))

(with-eval-after-load 'flyspell
  (advice-add 'flyspell-word :around #'my-flyspell-word-with-local-quit))
;; }}

(provide 'init-spelling)
;;; init-spelling.el ends here
