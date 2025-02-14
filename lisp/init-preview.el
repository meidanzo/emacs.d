;;; init-preview.el --- org-mode 和 markdown 文件预览  -*- lexical-binding: t; -*-
;;; Commentary:
;;; 配置插件: ox-gfm, grip-mode
;;; 依赖软件包: go-grip, firefox

;; - 使用方法
;; F7 浏览预览
;; F8 停止预览
;; F9 启用/禁用 grip-mode

;; - 缺点
;; 太复杂的 org-mode 文件预览不了.
;; 如https://github.com/DogLooksGood/emacs-rime/blob/master/README.org

;;; Code:
;; (add-hook 'markdown-mode-hook #'grip-mode)
;; (add-hook 'org-mode-hook #'grip-mode)
(with-eval-after-load 'org
  (require 'ox-gfm nil t))

(global-set-key [f7] #'grip-browse-preview)  ;; 浏览预览
(global-set-key [f8] #'grip-stop-preview)    ;; 停止预览
(global-set-key [f9] #'grip-mode)            ;; 启用/禁用 grip-mode

(with-eval-after-load 'grip-mode
  ;; 预览命令：auto、grip、go-grip 或 mdopen
  (setq grip-command 'go-grip)

  ;; 主题选择
  (setq grip-theme 'auto)

  ;; 使用嵌入式 webkit 进行预览
  ;; 需要 GNU Emacs >= 26，并使用 --with-xwidgets 编译
  ;; mdopen 不支持 webkit 预览
  (setq grip-preview-use-webkit t)

  ;; 指定用于加载预览的浏览器
  ;; 默认为 nil，表示使用系统默认浏览器
  ;; 会遵循 grip-preview-use-webkit 设置
  (setq grip-url-browser "firefox")

  ;; 如果需要向自定义浏览器传递参数
  ;; (setq grip-url-args '("arg1" "arg2" "etc"))
  (setq grip-url-args '("--new-window"))

  ;; 其他 GitHub API 的基础 URL
  ;; 仅适用于 grip
  ;; (setq grip-github-api-url "")

  ;; GitHub API 认证用户名
  ;; 仅适用于 grip
  ;; (setq grip-github-user "")

  ;; GitHub API 认证密码或 Token
  ;; 仅适用于 grip
  ;; (setq grip-github-password "")

  ;; 预览服务器主机名
  ;; 仅适用于 grip
  (setq grip-preview-host "localhost")

  ;; 等待服务器启动的秒数
  ;; (setq grip-sleep-time 2)

)

;; 4. 自动清理 grip-mode 进程
(defun my-grip-mode-cleanup ()
  "Stop grip process when exiting grip-mode or closing buffer."
  (when (and (boundp 'grip--process) (process-live-p grip--process))
    (delete-process grip--process)
    (setq grip--process nil)))  ; 防止重复引用

;; 在关闭缓冲区时自动清理（覆盖退出grip-mode的情况）
(add-hook 'kill-buffer-hook #'my-grip-mode-cleanup)

(provide 'init-preview)

;;; init-preview.el ends here