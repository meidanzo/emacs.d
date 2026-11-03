;;; init-rime-ui.el --- Emacs-rime UI 配置 -*- lexical-binding: t; -*-
;;; Commentary:
;; Rime UI 配置
;; 需要 im-cursor-chg

;;; Code:
;; 候选框最后一项不显示的解决办法
(defun +rime--posframe-display-content-a (args)
  "给 RIMe--posframe-display-content 传入的字符串加一个全角空格.
以解决 `posframe' 偶尔吃字的问题."
  (cl-destructuring-bind (content) args
    (let ((newresult (if (string-blank-p content)
                         content
                       (concat content "　"))))
      (list newresult))))

;; 自定义样式
(defun my-posframe-color-setup ()
  "仿照fcitx5-rime设置的样式, 但GUI下还是明亮一点好, 也容易区分."
  ;; 整体候选框文字
  (set-face-attribute 'rime-default-face nil
                      :foreground "#ffffff"
                      :background "#3f4551")

  ;; 编码颜色
  (set-face-attribute 'rime-code-face nil
                      :foreground "#ffffff"
                      :background "#363a46")


  ;; 高亮候选词
  (set-face-attribute 'rime-highlight-candidate-face nil
                      :foreground "#ffffff"
                      :background "#5d95d7"
                      :weight 'bold)

  ;; 候选序号颜色
  (set-face-attribute 'rime-candidate-num-face nil
                      :foreground "#89a4c7"
                      :weight 'bold)
  ;; 编码提示颜色
  ;; (set-face-attribute 'rime-comment-face nil
  ;;                     :foreground "#cccccc"
  ;;                     :background "#222222")

  ;; ;; tooltip（非 posframe 时会用到）
  ;; (set-face-attribute 'rime-tooltip-face nil
  ;;                     :foreground "#cccccc"
  ;;                     :background "#222222")

  ;; ;; 输入法状态文字（中/英）
  ;; (set-face-attribute 'rime-indicator-face nil
  ;;                     :foreground "#ffaf00"
  ;;                     :weight 'bold)
  )


(defun my-posframe-style-setup ()
  (my-ensure 'posframe)
  (setq rime-show-candidate 'posframe
        rime-posframe-style 'vertical)

  ;; 候选框最后一项不显示的解决办法
  (if (fboundp 'rime--posframe-display-content)
      (advice-add 'rime--posframe-display-content
                  :filter-args
                  #'+rime--posframe-display-content-a)
    (error "Function `rime--posframe-display-content' is not available"))

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
        (list ;; :width 8
              :height 6
              ;; :border-color "#3f4551"  ;;这个用于自定义样式
              :border-color "#dcdccc"
              :border-width 5
              :font "TsangerJinKai04 W03 18"
              :internal-border-color "#3f4551" ;;这个好像没起作用.
              :internal-border-width 10))

  ;; 自定义样式
  ;; (my-posframe-color-setup)
  )


;; 使用popup, 但是当敲击了四个字符并进行删除再键入的时候可能会卡死, 无解
;; 而且使用的时候不太流畅
(defun my-popup-style-setup ()
"popup 样式设置."
  (my-ensure 'popup)
  (setq rime-show-candidate 'popup
        rime-popup-style 'vertical)

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
    "Description of my custom face for popup menus."
    :group 'rime)

  (setq rime-popup-properties
        (list :margin-left 1
              :margin-right 2
              :min-height 1             ; 最小高度
              :height 6
              :truncate nil             ; 候选词不截断
              ;; :around t                 ; 在光标周围显示
              :nostrip nil              ; 关键: 如果设置为t, 保留字符串的 text properties, 包括 faces
              :face 'my-custom-face)))

(defun my-minibuffer-style-setup ()
"minibuffer 样式设置."
  (setq rime-show-candidate 'minibuffer)

  ;; 嵌入文本的UI设置
  (set-face-attribute 'rime-preedit-face nil
                      ;; :background "#4169E1"
                      ;; :background "#008B8B"
                      ;; :background "#008B8B"
                      :background "cyan"
                      :foreground "#002b36"
                      :inherit 'default
                      :weight 'bold))

;; 自定义指示器颜色
(defface my-rime-default-indicator-face
  '((((class color) (background dark))
     (:foreground "#ebcb8b" :bold t))
    (((class color) (background light))
     (:foreground "#ebcb8b" :bold t)))
  "Face for mode-line indicator when input-method is usable ."
  :group 'rime)

(defface my-rime-insert-indicator-face
  '((((class color) (background dark))
     (:foreground "#99ff99" :bold t))
    (((class color) (background light))
     (:foreground "#99ff99" :bold t)))
  "Face for mode-line indicator when input-method is usable ."
  :group 'rime)

(defface my-rime-buffer-modified-indicator-face
  '((((class color) (background dark))
     (:foreground "#66c98c" :bold t))
    (((class color) (background light))
     (:foreground "#66c98c" :bold t)))
  "Face for mode-line indicator when input-method is usable ."
  :group 'rime)

(defface my-rime-emacs-indicator-face
  '((((class color) (background dark))
     (:foreground "#F0E68C" :bold t))
    (((class color) (background light))
     (:foreground "#F0E68C" :bold t)))
  "Face for mode-line indicator when input-method is usable ."
  :group 'rime)

(defun my-rime-lighter ()
  "Mode-line lighter derived from `my-rime-state`."
  (let* ((state     (my-rime-state))
         (available (plist-get state :available))
         (active    (plist-get state :active))
         (blocked   (plist-get state :blocked))
         (context   (plist-get state :context)))

    (when (and available (not active) (not blocked))
      (propertize
       rime-title
       'face
       (pcase context
         (:insert 'my-rime-insert-indicator-face)
         (:emacs  'my-rime-emacs-indicator-face)
         (:dirty  'my-rime-buffer-modified-indicator-face)
         (_       'my-rime-default-indicator-face))))))

(defun my-rime-ui-modeline-setup ()
  "ㄓ: modeline."
  (add-to-list 'global-mode-string
               '(:eval (my-rime-lighter))
               t))

(defun my-rime-ui-candidate-setup ()
  "设置候选窗口."
  (if (display-graphic-p)
      (my-posframe-style-setup) ;; GUI环境：使用posframe
    ;; (my-popup-style-setup)))     ;; 终端环境：使用popup, 但是有的时候会卡死
    (my-minibuffer-style-setup)))   ;; 终端环境：使用minibuffer

(defun my-rime-ui-cursor-setup ()
  "自动更换光标颜色."
  (my-ensure 'im-cursor-chg)
  (cursor-chg-mode 1))

(defun my-ui-setup ()
  "UI 配置."
  (my-rime-ui-modeline-setup)
  (my-rime-ui-candidate-setup)
  (my-rime-ui-cursor-setup))

(provide 'init-rime-ui)
;;; init-rime-ui.el ends here