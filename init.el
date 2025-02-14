;; -*- coding: utf-8; lexical-binding: t; -*-

;;; Code:

;; Without this comment emacs25 adds (package-initialize) here
;; (package-initialize)

(let* ((minver "28.1"))
  (when (version< emacs-version minver)
    (error "Emacs v%s or higher is required" minver)))

(setq user-init-file (or load-file-name (buffer-file-name)))
(setq user-emacs-directory (file-name-directory user-init-file))

(defvar my-debug nil "Enable debug mode.")

(setq *is-a-mac* (eq system-type 'darwin))
(setq *win64* (eq system-type 'windows-nt))
(setq *cygwin* (eq system-type 'cygwin) )
(setq *linux* (or (eq system-type 'gnu/linux) (eq system-type 'linux)) )
(setq *unix* (or *linux* (eq system-type 'usg-unix-v) (eq system-type 'berkeley-unix)) )
(setq *emacs29* (>= emacs-major-version 29))

;; don't GC during startup to save time
(unless (bound-and-true-p my-computer-has-smaller-memory-p)
  (setq gc-cons-percentage 0.6)
  (setq gc-cons-threshold most-positive-fixnum))

;; {{ emergency security fix
;; https://bugs.debian.org/766397
(with-eval-after-load 'enriched
  (defun enriched-decode-display-prop (start end &optional param)
    (list start end)))
;; }}

(setq *no-memory* (cond
                   (*is-a-mac*
                    ;; @see https://discussions.apple.com/thread/1753088
                    ;; "sysctl -n hw.physmem" does not work
                    (<= (string-to-number (shell-command-to-string "sysctl -n hw.memsize"))
                        (* 4 1024 1024)))
                   (*linux* nil)
                   (t nil)))

(defconst my-emacs-d (file-name-as-directory user-emacs-directory)
  "Directory of emacs.d.")

(defconst my-site-lisp-dir (concat my-emacs-d "site-lisp")
  "Directory of site-lisp.")

(defconst my-lisp-dir (concat my-emacs-d "lisp")
  "Directory of personal configuration.")

;; Light weight mode, fewer packages are used.
(setq my-lightweight-mode-p (and (boundp 'startup-now) (eq startup-now t)))

(defun require-init (pkg &optional maybe-disabled)
  "Load PKG if MAYBE-DISABLED is nil or it's nil but start up in normal slowly."
  (when (or (not maybe-disabled) (not my-lightweight-mode-p))
    (load (file-truename (format "%s/%s" my-lisp-dir pkg)) t t)))

(defun my-add-subdirs-to-load-path (lisp-dir)
  "Add sub-directories under LISP-DIR into `load-path'."
  (let* ((default-directory lisp-dir))
    (setq load-path
          (append
           (delq nil
                 (mapcar (lambda (dir)
                           (unless (string-match "^\\." dir)
                             (expand-file-name dir)))
                         (directory-files lisp-dir)))
           load-path))))

;; @see https://www.reddit.com/r/emacs/comments/3kqt6e/2_easy_little_known_steps_to_speed_up_emacs_start/
;; Normally file-name-handler-alist is set to
;; (("\\`/[^/]*\\'" . tramp-completion-file-name-handler)
;; ("\\`/[^/|:][^/|]*:" . tramp-file-name-handler)
;; ("\\`/:" . file-name-non-special))
;; Which means on every .el and .elc file loaded during start up, it has to runs those regexps against the filename.
(let* ((file-name-handler-alist nil))

  (require-init 'init-autoload)
  ;; `package-initialize' takes 35% of startup time
  ;; need check https://github.com/hlissner/doom-emacs/wiki/FAQ#how-is-dooms-startup-so-fast for solution
  (require-init 'init-modeline)
  (require-init 'init-utils)
  (require-init 'init-file-type)
  (require-init 'init-elpa)

  ;; make all packages in "site-lisp/" loadable right now because idle loader
  ;; are not used and packages need be available on the spot.
  (when (or my-lightweight-mode-p my-disable-idle-timer)
    (my-add-subdirs-to-load-path (file-name-as-directory my-site-lisp-dir)))

  ;; Any file use flyspell should be initialized after init-spelling.el
  (require-init 'init-spelling t)
  (require-init 'init-ibuffer t)
  (require-init 'init-bookmark)
  (require-init 'init-ivy)
  (require-init 'init-windows)
  (require-init 'init-javascript t)
  (require-init 'init-org t)
  (require-init 'init-python t)
  (require-init 'init-lisp t)
  (require-init 'init-yasnippet t)
  (require-init 'init-cc-mode t)
  (require-init 'init-linum-mode)
  (require-init 'init-git)
  (require-init 'init-gtags t)
  (require-init 'init-clipboard)
  (require-init 'init-ctags t)
  (require-init 'init-gnus t)
  (require-init 'init-lua-mode t)
  (require-init 'init-term-mode)
  (require-init 'init-web-mode t)
  (require-init 'init-company t)
  (require-init 'init-chinese t) ;; cannot be idle-required
  ;; need statistics of keyfreq asap
  (require-init 'init-keyfreq t)
  (require-init 'init-httpd t)

  ;; projectile costs 7% startup time

  ;; don't play with color-theme in light weight mode
  ;; color themes are already installed in `init-elpa.el'
  (require-init 'init-theme)

  ;; essential tools
  (require-init 'init-essential)
  ;; tools nice to have
  (require-init 'init-ai t)
  (require-init 'init-misc t)
  (require-init 'init-dictionary t)
  (require-init 'init-emms t)

  (require-init 'init-emacs-w3m t)
  (require-init 'init-browser t)
  (require-init 'init-shackle t)
  (require-init 'init-dired t)
  (require-init 'init-writting t)
  (require-init 'init-hydra) ; hotkey is required everywhere
  ;; use evil mode (vi key binding)
  (require-init 'init-evil) ; init-evil dependent on init-clipboard
  (require-init 'init-pdf)

  ;; ediff configuration should be last so it can override
  ;; the key bindings in previous configuration
  (when my-lightweight-mode-p
    (require-init 'init-ediff))

  ;; @see https://github.com/hlissner/doom-emacs/wiki/FAQ
  ;; Adding directories under "site-lisp/" to `load-path' slows
  ;; down all `require' statement. So we do this at the end of startup
  ;; NO ELPA package is dependent on "site-lisp/".
  (unless my-disable-idle-timer
    (my-add-subdirs-to-load-path (file-name-as-directory my-site-lisp-dir)))

  (require-init 'init-no-byte-compile t)

  (unless my-lightweight-mode-p
    ;; @see https://www.reddit.com/r/emacs/comments/4q4ixw/how_to_forbid_emacs_to_touch_configuration_files/
    ;; See `custom-file' for details.
    (setq custom-file (concat my-emacs-d "custom-set-variables.el"))
    (if (file-exists-p custom-file) (load custom-file t t))

    ;; my personal setup, other major-mode specific setup need it.
    ;; It's dependent on *.el in `my-site-lisp-dir'
    (my-run-with-idle-timer 1 (lambda () (load "~/.custom.el" t nil)))))


;; @see https://www.reddit.com/r/emacs/comments/55ork0/is_emacs_251_noticeably_slower_than_245_on_windows/
;; Emacs 25 does gc too frequently
;; (setq garbage-collection-messages t) ; for debug
(defun my-cleanup-gc ()
  "Clean up gc."
  (setq gc-cons-threshold  67108864) ; 64M
  (setq gc-cons-percentage 0.1) ; original value
  (garbage-collect))

(run-with-idle-timer 4 nil #'my-cleanup-gc)

(message "*** Emacs loaded in %s with %d garbage collections."
           (format "%.2f seconds"
                   (float-time (time-subtract after-init-time before-init-time)))
           gcs-done)
;;; Local Variables:
;;; no-byte-compile: t
;;; End:
(put 'erase-buffer 'disabled nil)


;;org文件快速添加代码快
(require 'org-tempo)
(add-hook 'c-mode-common-hook 'google-set-c-style)
(add-hook 'c-mode-common-hook 'google-make-newline-indent)

;;多个缓冲区进行gdb，代码在文章最后:http://tuhdo.github.io/c-ide.html
(setq
 gdb-many-windows t  ;; use gdb-many-windows by default
 gdb-show-main t  ;; Non-nil means display source file containing the main routine at startup
)

;; 解决中英文混排的时候折行错误
(global-visual-line-mode 1)
(setq word-wrap-by-category t)

;; 放弃自动备份文件
;(setq make-backup-files nil)

;; 启动自动开启 xclip-mode
(require 'xclip)
(xclip-mode 1)

;;; ================= AUCTeX + latexmk + XeLaTeX + Zathura =================

;; 支持中文 -> xetex
;; 自动项目编译 -> latexmk
;; 正向/反向搜索 -> SyncTeX  + ~/.config/zathura/zathurarc
;; C-c C-a不高亮 -> my-TeX-run-all-no-sync
;; C-c C-v高亮当前行 (-> SyncTeX ?) -> TeX-command-run-all -> TeX-view -> TeX-view-program-list
;; 持续预览(PVS) -> LatexMk-PVC + ~/.latexmkrc
;; org-mode中文文件可以转换成正确的LaTeX文件并通过编译 -> org-latex-classes

;; ----------------- 使用建议 -----------------
;; 编译: C-c C-c -> LatexMk
;; 自动实时预览: C-c C-c → LatexMk-PVC
;; 正向搜索(PDF): C-c C-v
;; 反向搜索：在 Zathura 中按中键或 Ctrl+左键 (依 Zathura 配置)

;; --- 自动 UTF-8 编码 ---
(prefer-coding-system 'utf-8)
(set-default-coding-systems 'utf-8)
(setq default-buffer-file-coding-system 'utf-8)

;; --- AUCTeX 配置 ---
(require 'tex)                   ;; 确保 AUCTeX 加载
(setq TeX-auto-save t)           ;; 自动保存 TeX 辅助信息, AUCTeX 会自动生成.el 文件缓存一些解析信息, 加快解析速度.
(setq TeX-parse-self t)          ;; 在打开 TeX 文件时自动解析文件结构
                                 ;; 可以识别 \usepackage,章节结构等信息,方便智能补全和跳转
(setq-default TeX-master nil)    ;; 默认主文件为 nil, 每次打开 TeX 文件时询问. 避免 AUCTeX 错误地选择主文件


(setq-default TeX-engine 'xetex) ;; 默认使用 XeTeX 支持中文
(setq TeX-PDF-mode t)            ;; 默认生成 PDF. 运行 C-c C-c 编译时直接生成 PDF, 而不是 DVI
(setq TeX-command-default "LatexMk") ;; 默认使用 latexmk 编译

;; --- 启动 Emacs server (反向搜索需要) ---
(require 'server)
(unless (server-running-p)
  (server-start))

;; --- SyncTeX 配置 ---
(setq TeX-source-correlate-method 'synctex)
(setq TeX-source-correlate-mode t)         ;; 打开源代码关联
(setq TeX-source-correlate-start-server t) ;; 允许 PDF 点击跳转, 用于 SyncTeX 功能: 从 PDF 点击可以跳转到 TeX 源码
(add-hook 'LaTeX-mode-hook 'TeX-source-correlate-mode) ;; 自动开启 TeX-source-correlate-mode, 实现 LaTeX ↔ PDF 同步

;; --- PDF 查看器设为 Zathura ---
(setq TeX-view-program-selection '((output-pdf "Zathura"))) ;; 选择 Zathura 作为查看器
(setq TeX-view-program-list
      '(("Zathura-NoSync" "zathura %o")
        ("Zathura-Sync" "zathura --synctex-forward %n:0:%b %o")))
;; 说明：
;; %n → 当前行号
;; %o → 当前列(一般可以忽略)
;; %b → 文件名
;; %p → PDF 文件路径

(setq TeX-view-program-selection
      '((output-pdf "Zathura-NoSync")))  ;; 默认 C-c C-a 不使用同步

;; C-c C-v 使用同步
(defun my-TeX-run-all-no-sync ()
  "Run TeX-command-run-all but without SyncTeX highlighting."
  (interactive)
  (let ((TeX-view-program-selection
         '((output-pdf "Zathura-Sync"))))
    (call-interactively 'TeX-command-run-all)))  ;; 正确调用方式

(define-key TeX-mode-map (kbd "C-c C-v") #'my-TeX-run-all-no-sync)

;; --- latexmk 编译命令 ---
(add-to-list 'TeX-command-list
             '("LatexMk"
               "latexmk -xelatex -interaction=nonstopmode -synctex=1 %s"
               TeX-run-TeX nil t :help "Run latexmk"))

;; 可选：持续预览(PVS)
(add-hook 'LaTeX-mode-hook
          (lambda ()
            (unless (assoc "LatexMk-PVC" TeX-command-list)
              (add-to-list 'TeX-command-list
                           '("LatexMk-PVC"
                             "latexmk -xelatex -interaction=nonstopmode -synctex=1 -pvc %s"
                             TeX-run-TeX nil t :help "Run latexmk continuously")))))

;; 让org-mode中文文件可以转换成正确的LaTeX文件并通过编译
(with-eval-after-load 'ox-latex
  ;; 注册 ctexart 类
  (add-to-list 'org-latex-classes
               '("ctexart"
                 "\\documentclass[11pt]{ctexart}
[DEFAULT-PACKAGES]
[PACKAGES]
[EXTRA]"
                 ("\\section{%s}" . "\\section*{%s}")
                 ("\\subsection{%s}" . "\\subsection*{%s}")
                 ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
                 ("\\paragraph{%s}" . "\\paragraph*{%s}")
                 ("\\subparagraph{%s}" . "\\subparagraph*{%s}")))

  ;; 注册 ctexrep 类
  (add-to-list 'org-latex-classes
               '("ctexrep"
                 "\\documentclass[11pt]{ctexrep}
[DEFAULT-PACKAGES]
[PACKAGES]
[EXTRA]"
                 ("\\part{%s}" . "\\part*{%s}")
                 ("\\chapter{%s}" . "\\chapter*{%s}")
                 ("\\section{%s}" . "\\section*{%s}")
                 ("\\subsection{%s}" . "\\subsection*{%s}")
                 ("\\subsubsection{%s}" . "\\subsubsection*{%s}")))

  ;; 注册 ctexbook 类
  (add-to-list 'org-latex-classes
               '("ctexbook"
                 "\\documentclass[11pt]{ctexbook}
[DEFAULT-PACKAGES]
[PACKAGES]
[EXTRA]"
                 ("\\part{%s}" . "\\part*{%s}")
                 ("\\chapter{%s}" . "\\chapter*{%s}")
                 ("\\section{%s}" . "\\section*{%s}")
                 ("\\subsection{%s}" . "\\subsection*{%s}")
                 ("\\subsubsection{%s}" . "\\subsubsection*{%s}")))

  ;; 设置全局默认导出类为 ctexart
  (setq org-latex-default-class "ctexart")

  ;; 使用 XeLaTeX编译
  (setq org-latex-pdf-process
        '("xelatex -shell-escape -interaction=nonstopmode -output-directory=%o %f"
          "xelatex -shell-escape -interaction=nonstopmode -output-directory=%o %f")))

;; 设置org-mode打开pdf的时候用zathura
(setq org-file-apps
      '(("\\.pdf\\'" . "zathura %s")
        ("\\.x?html?\\'" . default)
        ("\\.\\(?:png\\|jpe?g\\|gif\\)\\'" . default)
        ("\\.mm\\'" . default)
        (auto-mode . emacs)
        (directory . emacs)
        ))

;; ================= 配置结束 =================