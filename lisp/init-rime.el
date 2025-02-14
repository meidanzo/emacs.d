;; -*- coding: utf-8; lexical-binding: t; -*-

(defvar my-toggle-ime-init-function
  (lambda () (my-ensure 'rime))
  "Function to execute at the beginning of `my-toggle-input-method'.")

;; {{ make IME compatible with evil-mode
(defun my-toggle-input-method ()
  "When input method is on, goto `evil-insert-state'."
  (interactive)

  ;; load IME when needed, less memory footprint
  (when my-toggle-ime-init-function
    (funcall my-toggle-ime-init-function))

  ;; some guys don't use evil-mode at all
  (cond
   ((and (boundp 'evil-mode) evil-mode)
    ;; evil-mode
    (cond
     ((eq evil-state 'insert)
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

(defun my-evil-insert-state-hack (orig-func &rest args)
  "Notify user IME status."
  (apply orig-func args)
  (if current-input-method (message "Rime IME on! 🚀")))

(global-set-key (kbd "C-\\") 'my-toggle-input-method)
;; }}

;; {{ rime

;; 另设目录, 防止污染rime配置
;; 不能和fcitx5-rime一个配置, 否则会有锁及同步等问题.
(defvar rime-user-data-dir "~/.config/emacs-rime"
  "The directory containing rime dictionaries.")


;; 候选框最后一项不显示
(defun +rime--posframe-display-content-a (args)
  "给 `rime--posframe-display-content' 传入的字符串加一个全角空
格,以解决 `posframe' 偶尔吃字的问题."
  (cl-destructuring-bind (content) args
    (let ((newresult (if (string-blank-p content)
                         content
                       (concat content "　"))))
      (list newresult))))

(defun my-posframe-style-setup ()
  (my-ensure 'posframe)
  (setq rime-show-candidate 'posframe)
  (setq rime-posframe-style 'vertical)

  ;; 嵌入文本的UI设置
  (set-face-attribute 'rime-preedit-face nil
                      ;; :background "#4169E1"
                      ;; :background "#008B8B"
                      ;; :background "#008B8B"
                      :background "#268BD2"
                      :foreground "#ffffff"
                      :inherit 'default
                      :weight 'bold)
  ;; 软光标颜色
  (set-face-attribute 'rime-cursor-face nil
                      :foreground "red")

  (setq rime-posframe-properties
        (list :widths 40
              :height 6
              ;; :border-color "#3f4551"  ;;这个用于自定义样式
              :border-color "#dcdccc"
              :border-width 5
              :font "TsangerJinKai04 W03 18"
              :internal-border-color "#3f4551" ;;这个好像没起作用.
              :internal-border-width 10))

  ;; 仿照fcitx5-rime设置的样式, 但GUI下还是明亮一点好. 也容易区分
  ;; (custom-set-faces
  ;;  ;; 整体候选框文字
  ;;  '(rime-default-face ((t (:foreground "#ffffff" :background "#3f4551"))))

  ;;  ;; 编码颜色
  ;;  '(rime-code-face ((t (:foreground "#ffffff" :background "#363a46"))))


  ;;  ;; 高亮候选词
  ;;  '(rime-highlight-candidate-face
  ;;    ((t (:foreground "#ffffff" :background "#5d95d7" :weight bold))))

  ;;  ;; 候选序号颜色
  ;;  '(rime-candidate-num-face
  ;;    ((t (:foreground "#89a4c7" :weight bold))))

  ;;  ;; 编码提示颜色
  ;;  ;; '(rime-comment-face
  ;;  ;;   ((())))

  ;;  ;; ;; tooltip（非 posframe 时会用到）
  ;;  ;; '(rime-tooltip-face
  ;;  ;;   ((t (:foreground "#cccccc" :background "#222222"))))

  ;;  ;; ;; 输入法状态文字（中/英）
  ;;  ;; '(rime-indicator-face
  ;;  ;;   ((t (:foreground "#ffaf00" :weight bold))))
  ;;  )
  )


(defun my-popup-style-setup ()
  (my-ensure 'popup)
  (setq rime-show-candidate 'popup)
  (setq rime-popup-style 'vertical)

  ;; 嵌入文本的UI设置
  (set-face-attribute 'rime-preedit-face nil
                      ;; :background "#4169E1"
                      ;; :background "#008B8B"
                      ;; :background "#008B8B"
                      :background "cyan"
                      :foreground "#002b36"
                      :inherit 'default
                      :weight 'bold)

  ;; 仿照fcitx5-rime设置的样式
  (defface my-custom-face
    '((t (:foreground "#ffffff"             ; 前景色（文本颜色）
                      :background "#3f4551" ; 背景色
                      :weight normal        ; 粗体
                      :slant normal         ; 斜体
                      :underline nil        ; 下划线
                      :width regular)))
    "Description of my custom face for popup menus.")

  (setq rime-popup-properties
        (list :margin-left 1
              :margin-right 2
              :min-height 1             ; 最小高度
              :height 6
              :truncate nil             ; 候选词不截断
              ;; :around t                    ; 在光标周围显示
              ;; :nostrip nil ; 保留原有的文本属性
              :nostrip nil ; 关键: 如果设置为t, 保留字符串的 text properties, 包括 faces
              :face 'my-custom-face)))

;; 在当前没有输入内容(没有 preedit overlay)的情况 下, 用evil-escape的按键回到 normal 模式.
;; 用evil-escape的按键回到 normal 模式, 结合 evil-escape 一起使用
(defun rime-evil-escape-advice (orig-fun key)
  "advice for `rime-input-method' to make it work together with `evil-escape'.
        Mainly modified from `evil-escape-pre-command-hook'"
  (if rime--preedit-overlay
      ;; if `rime--preedit-overlay' is non-nil, then we are editing something, do not abort
      (apply orig-fun (list key))
    (when (featurep 'evil-escape)
      (let (
            (fkey (elt evil-escape-key-sequence 0))
            (skey (elt evil-escape-key-sequence 1))
            )
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
                (evil-normal-state))
               ((null evt) (apply orig-fun (list key)))
               (t
                (apply orig-fun (list key))
                (if (numberp evt)
                    (apply orig-fun (list evt))
                  (setq unread-command-events (append unread-command-events (list evt))))))
              )
          (apply orig-fun (list key)))))))




(with-eval-after-load 'rime

  (defun my-rime-clear-and-off ()
    "Clear and off."
    (interactive)
    (when (rime-active-p)
      (rime--clear-state)
      (message "RIME input cleared."))
    (my-toggle-input-method))

  ;; (defun my-rime-clear-and-off ()
  ;; (when current-input-method
  ;;   (toggle-input-method)))  ;; 关闭输入法

  ;; ;; select second word
  ;; (define-key pyim-mode-map ";" (lambda ()
  ;;                                 (interactive)
  ;;                                 (pyim-page-select-word-by-number 2)))

  ;; press "C+/" to turn off rime
  ;; rime中好像有一样的快捷键
  (define-key rime-mode-map (kbd "C-,") #'my-rime-clear-and-off)

  ;; 不要启动时初始化 Rime, 否则发生段错误.
  (setq default-input-method "rime")


  ;; 设置候选窗口
  (if (display-graphic-p)

      ;; 候选框最后一项不显示
      (when (fboundp 'rime--posframe-display-content)
        (advice-add 'rime--posframe-display-content
                    :filter-args
                    #'+rime--posframe-display-content-a)
        (error "Function `rime--posframe-display-content' is not available."))

      ;; GUI环境：使用posframe
      (my-posframe-style-setup)
    ;; 终端环境：使用popup
    (my-popup-style-setup))

  ;; 组合键默认值
  (setq rime-translate-keybindings
        '("C-f" "C-b" "C-n" "C-p" "C-g" "<left>" "<right>" "<up>" "<down>" "<prior>" "<next>" "<delete>"))

  ;; ;; 使用西文标点符号（非中文标点）
  ;; (setq rime-inline-ascii-holder "|")


  (setq rime-disable-predicates
        '(rime-predicate-after-alphabet-char-p ;; 在英文字符串之后（必须为以字母开头的英文字符串）
          rime-predicate-after-ascii-char-p ;; 任意英文字符后
          rime-predicate-prog-in-code-p ;; 在 prog-mode 和 conf-mode 中除了注释和引号内字符串之外的区域
          rime-predicate-in-code-string-p ;; 在代码的字符串中，不含注释的字符串。
          rime-predicate-evil-mode-p ;; 在 evil-mode 的非编辑状态下
          rime-predicate-ace-window-p ;; 激活 ace-window-mode(一个窗口切换插件)
          ;; rime-predicate-hydra-p ;; 如果激活了一个 hydra keymap
          rime-predicate-current-input-punctuation-p ;; 当要输入的是符号时
          ;; rime-predicate-punctuation-after-space-cc-p ;; 当要在中文字符且有空格之后输入符号时
          ;; ;; rime-predicate-punctuation-after-ascii-p ;; 当要在任意英文字符之后输入符号时
          ;; ;; rime-predicate-punctuation-line-begin-p ;; 在行首要输入符号时
          ;; rime-predicate-space-after-ascii-p ;; 在任意英文字符且有空格之后 ??
          ;; rime-predicate-space-after-cc-p ;; 在中文字符且有空格之后
          ;; rime-predicate-current-uppercase-letter-p ;; 将要输入的为大写字母时
          rime-predicate-tex-math-or-command-p ;; 在 (La)TeX 数学环境中或者输入 (La)TeX 命令时
          ;; rime-predicate-auto-english-p ;; 英文上下文(如URL,路径,标识符),已有英文字符且属于英文词汇环境
          ;; rime-predicate-in-code-string-after-ascii-p ;;  在编程语言字符串内,并且光标前是 ASCII 字符,
                                                         ;;  代码中字符串里输入英文(如路径,JSON,正则)时
          ;; rime-predicate-org-in-src-block-p
          rime-predicate-org-latex-mode-p
          rime-predicate-punctuation-after-space-en-p ;; 你在空格之后输入标点符号,并且应该使用英文标点
          ))


  ;; ㄓ: 提示临时英文状态的提示符, modeline状态栏显示
  (setq mode-line-mule-info '((:eval (rime-lighter))))


  ;; Rime inline ascii 模式的临时英文
  ;; 需要和 rime-user-data-dir 配置中的一致, 回车上屏
  ;;; support shift-l, shift-r, control-l, control-r
  (setq rime-inline-ascii-trigger 'shift-r)

  ;; 有编码的状态下使用 rime-inline-ascii 命令可以切换状态
  (define-key rime-active-mode-map (kbd "C-k") 'rime-inline-ascii)

  (setq rime-inline-predicates '(rime-predicate-space-after-cc-p
                                 rime-predicate-current-uppercase-letter-p))

  ;; 临时英文中阻止标点直接上屏
  ;; (setq rime-inline-ascii-holder ?x)

  ;; 强制中文.
  (define-key rime-mode-map (kbd "C-l") 'rime-force-enable)

  ;; evil-escape
  (when (fboundp 'rime-input-method)
    (advice-add 'rime-input-method
                :around
                #'rime-evil-escape-advice))

  ;; (define-key rime-mode-map (kbd "C-`") #'rime-send-keybinding)
  (define-key rime-mode-map (kbd "<F4>") #'rime-send-keybinding))
;; Emacs 关闭时正确清理 Rime 资源
;; 不能放在 with-eval-after-load 里面, 否则第一次安装报错
(add-hook 'kill-emacs-hook
          (lambda ()
            (when (fboundp 'rime-lib-finalize)
              (rime-lib-finalize))))


(with-eval-after-load 'evil
  ;; 这是用于通知用户输入法状态
  (when (fboundp 'evil-insert-state)
    (advice-add 'evil-insert-state
                :around
                #'my-evil-insert-state-hack)))


;; }}

(provide 'init-rime)

;;; init-rime.el ends here
