;;; init-rime.el --- Emacs-rime 配置 -*- lexical-binding: t; -*-
;;; Commentary:
;;; 依赖插件: evil, evil-escape, popup, posframe
;;; 依赖软件包: librime-dev


;; - 主要功能
;; 模块加载和激活输入法分离并自动编译模块  -> my-rime--ensure-module-loaded
;; insert 模式自动激活输入法    -> my-evil-auto-enable-rime + my-evil-insert-state-notify
;; evil 和手动激活输入法整合    -> my-toggle-input-method
;; evil-escape 和 rime 整合     -> rime-evil-escape-advice
;; GUI 和 TTY 模式 UI 设置      -> my-posframe-style-setup + my-popup-style-setup + +rime--posframe-display-content-a
;; 多环境中英文混合输入         -> rime-disable-predicates + rime-inline-predicates
;; 根据输入类型自动更换光标颜色 -> im-cursor-chg
;; 根据 rime 是否可用在 modeline 显示彩色指示标志 -> my-rime-ui-modeline-setup
;; 多个自定义键


;; - 使用方法
;; 进入 insert mode 自动激活输入法
;; C-\ 开启/关闭输入法
;; enter 键上屏编码而非字符
;; escape 键清空候选框并进入 normal mode
;; GUI 模式 "C-`" 切换输入法
;; 断言生效情况下 "M-p" 强制输入中文
;; 有编码的状态下使用 "M-u" 切换状态
;; 输入法激活, 且没有输入内容:
;;             按下 evil-escape 键返回 normal mode, 且evil-escape 键在所有 buffer 中可用.
;;             中文输入状态下按下 "`" 键关闭输入法

;;; Code:
(dolist (package '(evil evil-escape))
  (my-ensure package))

;; {{ 模块加载与输入法激活彻底解耦
(defun my-rime--ensure-module-loaded ()
  "让 rime 动态模块预先加载."
  (when (and (require 'rime nil t)
             (not (rime--rime-lib-module-ready-p)))
    (unless noninteractive
      (message "[Rime] Loading native module..."))
    (unless (file-exists-p (expand-file-name rime--module-path))
      (message "[Rime] Compiling native module...")
      (unless (rime-compile-module)
        (error "[Rime] Native module compilation failed")))
    (rime--load-dynamic-module)))

(add-hook 'emacs-startup-hook #'my-rime--ensure-module-loaded t)

;; Debugger buffer 中evil-escape-mode 会失效的补丁. 关闭
;; (add-hook 'emacs-startup-hook #'my-rime--ensure-module-loaded t)
;; 却又正常
(dolist (hook '(comint-mode-hook gud-mode-hook gdb-mode-hook))
  (add-hook hook #'evil-escape-mode t))
;; (add-hook 'window-setup-hook #'my-rime--ensure-module-loaded t)
;; }}

(defvar my-toggle-ime-init-function
  (lambda () (my-ensure 'rime))
  "Function to execute at the beginning of `my-toggle-input-method'.")

;; {{ make IME compatible with evil-mode
(defun my-toggle-input-method ()
  "When input method is on, goto `evil-insert-state'.  针对 C-\ 手动调用."
  (interactive)

  ;; load IME when needed, less memory footprint
  (when my-toggle-ime-init-function
    (funcall my-toggle-ime-init-function))

  ;; some guys don't use evil-mode at all
  (cond
   ((and (boundp 'evil-mode) evil-mode)
    ;; evil-mode
    (cond
     (;; (eq evil-state 'insert)
      (evil-insert-state-p)
      (toggle-input-method))
     (t
      (evil-insert-state)
      (unless current-input-method
        (toggle-input-method))))
    (cond
     (current-input-method
      ;; evil-escape and rime may conflict
      ;; @see https://github.com/redguardtoo/emacs.d/issues/629
      (evil-escape-mode -1)
      (message "Rime IME on!  🚀"))
     (t
      (evil-escape-mode 1)
      (message "Rime IME off! 🌙"))))
   (t
    ;; NOT evil-mode
    (toggle-input-method))))

(global-set-key (kbd "C-\\") 'my-toggle-input-method)

(defun my-evil-insert-state-notify (&rest _args)
  "Notify user IME status."
  (when (and current-input-method
             ;; (eq evil-state 'insert)
             (evil-insert-state-p)
             )
    (message "Rime IME on! 🚀")))

(with-eval-after-load 'evil
  "通知用户输入法状态"
  (when (fboundp 'evil-insert-state)
    (advice-add 'evil-insert-state
                :after
                #'my-evil-insert-state-notify)))

(defun my-evil-auto-enable-rime ()
  "Enable rime automatically when entering evil insert state."
  (when (and (evil-insert-state-p)
             (not current-input-method)
             (fboundp 'rime--rime-lib-module-ready-p))
    (evil-escape-mode -1)
    (activate-input-method "rime")))

(with-eval-after-load 'evil
  "进入insert mode自动激活输入法"
  (add-hook 'evil-insert-state-entry-hook
            #'my-evil-auto-enable-rime t))

;; 在当前没有输入内容的情况下
;; 用evil-escape的按键回到 normal 模式
(defun rime-evil-escape-advice (orig-fun key)
  "Advice for `rime-input-method' to work with `evil-escape'.

ORIG-FUN is the original function being advised.
KEY is the input event passed to ORIG-FUN.

This advice modifies the behavior when `rime--preedit-overlay' is active,
so that Rime preedit is not aborted by `evil-escape' key sequences.
Mainly adapted from `evil-escape-pre-command-hook'."

  (if rime--preedit-overlay
      ;; if `rime--preedit-overlay' is non-nil, then we are editing something, do not abort
      (apply orig-fun (list key))
    (when (featurep 'evil-escape)
      (let ((fkey (elt evil-escape-key-sequence 0))
            (skey (elt evil-escape-key-sequence 1)))
        (if (or (char-equal key fkey)
                (and evil-escape-unordered-key-sequence
                     (char-equal key skey)))
            (let ((evt (read-event nil nil evil-escape-delay)))
              (cond
               ((and (characterp evt)
                     (or (and (char-equal key fkey) (char-equal evt skey))
                         (and evil-escape-unordered-key-sequence
                              (char-equal key skey) (char-equal evt fkey))))
                (evil-repeat-stop)
                (evil-normal-state)
                (evil-escape-mode 1))        ;; 用于 C-\ 开启输入法的情况
               ((null evt) (apply orig-fun (list key)))
               (t
                (apply orig-fun (list key))
                (if (numberp evt)
                    (apply orig-fun (list evt))
                  (setq unread-command-events (append unread-command-events (list evt)))))))
          (apply orig-fun (list key)))))))

;; }}

;; {{ rime

;;  配置 rime 参数(必须在 require 之前)
(setq rime-librime-root nil)  ; 使用系统标准路径

;; 不能和fcitx5-rime一个目录, 否则会有锁及同步等问题.
(when (my-dir-check-p "~/.local/share/emacs-rime" t)
  (setq rime-share-data-dir "~/.local/share/emacs-rime" )
  (setq rime-user-data-dir "~/.local/share/emacs-rime"))

;; {{ UI 控制层
(defun my-rime--available-p ()
  "Return non-nil if emacs-rime is available and usable."
  (and (featurep 'rime)
       (fboundp 'rime--rime-lib-module-ready-p)
       (rime--rime-lib-module-ready-p)
       (boundp 'rime-user-data-dir)
       (my-dir-check-p rime-user-data-dir t)))

(defun my-rime--active-p ()
  "Return non-nil if rime is currently enabled."
  (or (bound-and-true-p rime-mode)
      ;; (rime-mode)
      (equal current-input-method "rime")))

(defun my-rime--other-im-active-p ()
  "Return non-nil if another input method is active."
  (or current-input-method
      current-input-method-title))

;; core
(defun my-rime-context ()
  (cond
   ((and (featurep 'evil) (evil-insert-state-p)) :insert)
   ((and (featurep 'evil) (evil-emacs-state-p))  :emacs)
   ((buffer-modified-p)                         :dirty)
   (t                                           :default)))

(defun my-rime-state ()
  "Return an immutable snapshot of Rime logical state.
This function must be side-effect free and UI-agnostic."
  (list
   ;; capability
   :available (my-rime--available-p)

   ;; runtime
   :active    (my-rime--active-p)
   :blocked   (my-rime--other-im-active-p)

   ;; context
   :context   (my-rime-context)))

;; }}

;; {{ disable-predicates
;; @see https://sunyour.org/post/%E6%88%91%E7%9A%84-emacs-%E5%86%85%E7%BD%AE%E8%BE%93%E5%85%A5%E6%B3%95%E6%AD%A3%E5%BC%8F%E6%94%B9%E7%94%A8-emacs-rime/
(defun +rime--beancount-p ()
  "当前为`beancount-mode',且光标不在注释或字符串当中."
  (when (derived-mode-p 'beancount-mode)
    (not (or (nth 3 (syntax-ppss))
             (nth 4 (syntax-ppss))))))

(defun +rime-latex-noncomment-p ()
  "判断当前光标是否在 LaTeX/TeX 模式的非注释区域.
返回 t 表示应使用英文输入,nil 表示不干预."
  (and (derived-mode-p 'tex-mode
                       'latex-mode
                       'LaTeX-mode
                       'plain-tex-mode)
       (not (nth 4 (syntax-ppss)))))

(defun +rime-english-prober ()
  "仅在beancount, 或 TeX / LaTeX 非注释区域启用英文输入."
  (or
   ;; beancount 文件
   (+rime--beancount-p)

   ;; LaTeX / TeX / plain TeX：只要不是注释
   (+rime-latex-noncomment-p)))
;; }}

(defun my-rime-commit1-and-evil-normal ()
  "Commit the 1st item if exists, then go to evil normal state."
  (interactive)
  ;; (rime-commit1)  ;；不上屏, 清空候选框
  (when (featurep 'evil)
    (evil-repeat-stop)
    (evil-normal-state))
  (when (featurep 'evil-escape)
    (evil-escape-mode 1)))

(with-eval-after-load 'rime

  ;; 不要启动时初始化 Rime, 否则发生段错误.
  (setq default-input-method "rime")

  (my-ensure 'init-rime-ui)
  (my-ui-setup)

  ;; 清空并返回 normal mode
  (define-key rime-active-mode-map (kbd "<escape>") #'my-rime-commit1-and-evil-normal)

  ;; press "/" to turn off rime
  ;; (define-key rime-mode-map (kbd "/") #'my-toggle-input-method)
  ;; C/C++ 代码中使用"/" 不方便, 改为"`"
  (define-key rime-mode-map (kbd "`") #'my-toggle-input-method)

  ;; Enter 键行为, t: 提交原始输入
  (setq rime-return-insert-raw t)

  ;; 组合键默认值
  (setq rime-translate-keybindings
        '("C-f" "C-b" "C-n" "C-p" "C-g" "<left>" "<right>" "<up>" "<down>" "<prior>" "<next>" "<delete>"))

  ;; C-` 只能在GUI 环境下使用. 两个快捷键都只能在启用输入法状态下使用.
  ;; Emacs不会转发F5按键, 不要将F5绑定到rime-send-keybinding.
  (define-key rime-mode-map (kbd "C-`") #'rime-send-keybinding)
  (define-key rime-mode-map (kbd "<f5>") #'rime-select-schema)

  (setq rime-disable-predicates
        '(rime-predicate-evil-mode-p                     ;; 在 evil-mode 的非编辑状态下
          rime-predicate-prog-in-code-p                  ;; 在 prog-mode 和 conf-mode 中除了注释和引号内字符串之外的区域
          rime-predicate-after-ascii-char-p              ;; 任意英文字符后
          rime-predicate-in-code-string-p                ;; 在代码的字符串中，不含注释的字符串。
          rime-predicate-after-alphabet-char-p           ;; 在英文字符串之后（必须为以字母开头的英文字符串）
          rime-predicate-ace-window-p                    ;; 激活 ace-window-mode(一个窗口切换插件)
          rime-predicate-hydra-p                         ;; 如果激活了一个 hydra keymap
          rime-predicate-current-input-punctuation-p     ;; 当要输入的是符号时
          rime-predicate-punctuation-after-space-cc-p    ;; 当要在中文字符且有空格之后输入符号时
          rime-predicate-punctuation-after-ascii-p       ;; 当要在任意英文字符之后输入符号时
          rime-predicate-punctuation-line-begin-p        ;; 在行首要输入符号时
          ;; rime-predicate-space-after-ascii-p          ;; 在任意英文字符且有空格之后 ??
          ;; rime-predicate-space-after-cc-p             ;; 在中文字符且有空格之后
          ;; rime-predicate-current-uppercase-letter-p   ;; 将要输入的为大写字母时
          rime-predicate-tex-math-or-command-p           ;; 在 (La)TeX 数学环境中或者输入 (La)TeX 命令时
          ;; rime-predicate-auto-english-p               ;; 英文上下文(如URL,路径,标识符),已有英文字符且属于英文词汇环境
          ;; rime-predicate-in-code-string-after-ascii-p ;;  在编程语言字符串内,并且光标前是 ASCII 字符,
                                                         ;;  代码中字符串里输入英文(如路径,JSON,正则)时
          rime-predicate-org-in-src-block-p
          rime-predicate-org-latex-mode-p
          rime-predicate-punctuation-after-space-en-p    ;; 你在空格之后输入标点符号,并且应该使用英文标点
          +rime-english-prober                           ;; 仅在beancount, 或 TeX / LaTeX 非注释区域启用英文输入
          ))

  ;; 断言生效情况下强制中文, 临时切换
  (define-key rime-mode-map (kbd "M-p") #'rime-force-enable)

  ;; Rime inline ascii 模式的临时英文
  ;; 需要和 rime-user-data-dir 配置中的一致, 回车上屏
  ;;; support shift-l, shift-r, control-l, control-r
  (setq rime-inline-ascii-trigger 'shift-r)

  ;; 有编码的状态下使用 rime-inline-ascii 命令可以切换状态
  (define-key rime-active-mode-map (kbd "M-u") #'rime-inline-ascii)

  (setq rime-inline-predicates '(rime-predicate-space-after-cc-p
                                 rime-predicate-current-uppercase-letter-p))

  ;; 临时英文中阻止标点直接上屏
  ;; (setq rime-inline-ascii-holder ?x)

  ;; evil-escape
  (when (fboundp 'rime-input-method)
    (advice-add 'rime-input-method
                :around
                #'rime-evil-escape-advice)))

;; Emacs 关闭时正确清理 Rime 资源
;; 不能放在 with-eval-after-load 里面, 否则第一次安装报错
(add-hook 'kill-emacs-hook
          (lambda ()
            (when (fboundp 'rime-lib-finalize)
              (rime-lib-finalize))))

(my-ensure 'rime)
;; }}

(provide 'init-rime)
;;; init-rime.el ends here
