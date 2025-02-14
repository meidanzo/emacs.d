;;; init-LaTeX-mode.el --- Emacs LaTeX 环境搭建 -*- lexical-binding: t; -*-
;;; Commentary:
;;; 配置插件: AUCTeX + RefTeX + CDLaTeX + amsreftex + auctex-cont-latexmk + auctex-label-numbers + evil-tex


;; - 主要功能
;; 支持中文 -> xetex
;; 自动项目编译 -> LaTeXMk
;; 反向搜索 -> SyncTeX  + ~/.config/zathura/zathurarc
;; 正向搜索(高亮当前行) -> SyncTeX + zathura --synctex-forward + TeX-view
;; 持续编译和预览 -> auctex-cont-latexmk + ~/.latexmkrc
;; 折叠标记 -> TeX-fold-mode
;; 显示折叠的编号 -> auctex-label-numbers-mode


;; - 使用方法
;; 编译: C-c C-c -> LaTeXMk
;; 自动实时预览: C-c k -> auctex-cont-latexmk-toggle
;; 正向搜索(PDF): C-c C-v -> Zathura-with-highlighting
;; 反向搜索：在 Zathura 中按中键或 Ctrl+左键 (依 Zathura 配置)

;; - evil中
;; leader(,) + "cm" / "lv": 打开命令选择列表
;; leader(,) + "ca": 编译并查看
;; leader(,) + "cn": 打开zathura并高亮光标所在行
;; leader(,) + "ch": 打开zathura并高亮光标所在行
;; leader(,) + "ce": 插入环境
;; leader(,) + "ck": 持续编译
;; leader(,) + "cd": 打开zathura预览
;; leader(,) + "lk": 关闭编译进程
;; leader(,) + "le": 居中显示输出缓冲区
;; leader(,) + "lt": 显示 RefTeX 的 Table of Contents
;; leader(,) + "lk": 清理临时文件


;;; Code:

(defun my-auctex-setup ()
  "AUCTeX 配置."
  (my-ensure 'tex)
  (setq-default TeX-master nil
                TeX-engine 'xetex)
  (setq TeX-auto-save t
        TeX-parse-self t
        TeX-auto-untabify t ;; 保存时自动将 tab 转为空格
        TeX-command-default "LaTeXMk"
        TeX-PDF-mode t
        TeX-output-dir "build" ;; latexmk自动使用 build/ 而不需要额外指定 -outdir
        TeX-save-query nil     ;; 编译时自动保存文件
        TeX-show-compilation nil ;; 编译在后台进行
        TeX-command-extra-options "-interaction=nonstopmode -synctex=1")) ;; 设置LaTeXMk编译选项

(defun my-synctex-setup ()
  "SyncTeX 配置."
  ;; --- 启动 Emacs server (反向搜索需要) ---
  (require 'server)
  (unless (server-running-p)
    (server-start))

  (setq TeX-source-correlate-method 'synctex
        TeX-source-correlate-start-server t) ;; 允许 PDF 点击跳转, 用于 SyncTeX 功能: 从 PDF 点击可以跳转到 TeX 源码
  (TeX-source-correlate-mode)                ;; 打开源代码关联

  ;; --- PDF 查看器设为 Zathura ---
  (setq TeX-view-program-list
        '(("Zathura" "zathura %o")
          ("Zathura-with-highlighting" "zathura --synctex-forward %n:0:%b %o")))

  (setq TeX-view-program-selection
        '((output-pdf "Zathura"))) ;; 默认 C-c C-a 不使用同步

  (define-key TeX-mode-map (kbd "C-c C-v") #'my-TeX-view-with-SyncTeX-highlighting))

(defun my-TeX-view-with-SyncTeX-highlighting ()
  "Run zathura with SyncTeX highlighting."
  (interactive)
  (let ((TeX-view-program-selection
         '((output-pdf "Zathura-with-highlighting"))))
    (call-interactively 'TeX-view))) ;; 正确调用方式

(defun my-reftex-setup ()
  "启用RefTeX(Emacs内置)."
  (my-ensure 'reftex)
  (reftex-mode 1)
  (when (locate-library "amsreftex")
    (my-ensure 'amsreftex)
    (amsreftex-turn-on))

  ;; 启用 RefTeX, 并集成到 AucTeX 中, 在 LaTeX 模式中自动启用 RefTeX
  (setq reftex-parse-all t
        reftex-enable-partial-scans t             ;; RefTeX 只扫描正在编辑的部分(或最近修改的部分),提高性能
        reftex-save-parse-info t
        reftex-use-multiple-selection-buffers t
        reftex-plug-into-AUCTeX t                 ;; 让 RefTeX 与 AUCTeX 配合更紧密, 这是关键配置
        reftex-ref-macro-prompt nil               ;; ~ref<tab>~ 后不提示类型
        reftex-trust-label-prefix t
        reftex-label-menu-flags '(t t nil nil t nil t t)))

(defun my-preview-setup ()
  "预览与美化."
  ;; 光标移动到一个被替换成符号的地方时, 暂时显示原始文本
  (setq prettify-symbols-unprettify-at-point t)
  ;; (set-fontset-font "fontset-default" '(#x10000 . #x1FFFF) "Cambria Math" nil 'prepend)
  (set-fontset-font "fontset-default" 'mathematical "Cambria Math")
  (prettify-symbols-mode)) ;; 预览tex文件, 把某些字符自动用 Unicode 符号显示

(defun my-refresh-auctex-label-numbers (&rest _)
  "手动编译时更新标记和号码, 在TeX-command-buffer 中运行, 保留光标位置."
  (declare (ignore _))
  (when (and (boundp 'TeX-command-buffer)
             TeX-command-buffer
             (bound-and-true-p auctex-label-numbers-mode)
             (buffer-live-p TeX-command-buffer))
    (with-current-buffer TeX-command-buffer       ;; 获取 LaTeX 源文件 buffer
      (condition-case err
          (let ((current-point (point)))
            ;; 注意: 顺序不能错!
            (auctex-label-numbers-mode -1)        ;; 清除旧的标签号缓存
            (redisplay)                           ;; 非阻塞刷新, 或者 (force-window-update nil)
            (auctex-label-numbers-mode 1)         ;; 从更新的 .aux 文件重新读取标签号
            (when (and (fboundp 'TeX-fold-buffer)
                       (bound-and-true-p TeX-fold-mode))
              (TeX-fold-buffer))                  ;; 使用新缓存进行折叠显示
            (goto-char current-point))            ;; 恢复光标位置
        (error
         (message "刷新 auctex label numbers 时出错: %s" err))))))



(defun my-refresh-auctex-label-numbers-in-flymake ()
  "持续编译时, 在 Flymake 诊断报告后刷新标签号."
  (when (and (derived-mode-p 'LaTeX-mode)
             (bound-and-true-p auctex-label-numbers-mode)
             (not (buffer-modified-p)))
    (condition-case err
        (let ((current-point (point)))
          (auctex-label-numbers-mode -1)
          (sit-for 0.1)
          (redisplay)
          (auctex-label-numbers-mode 1)
          (sit-for 0.2)
          (when (and (fboundp 'TeX-fold-buffer)
                     (bound-and-true-p TeX-fold-mode))
            (TeX-fold-buffer))
          (goto-char current-point))
      (error
       (message "刷新 auctex label numbers 时出错:  %s" err)))))

(defun my-auctex-cont-latexmk-setup ()
  "持续编译."
  (my-ensure 'auctex-cont-latexmk)
  (setq auctex-cont-latexmk-command
        '("latexmk -xelatex -pvc -e "
          ("$xelatex=q/xelatex %O -synctex=1 -interaction=nonstopmode %S/")))

  ;; 在 Flymake 报告后刷新标签号
  (advice-add 'auctex-cont-latexmk-send-report
              :after
              (lambda ()
                (when auctex-cont-latexmk-mode
                  (run-with-timer 0.5 nil
                                 #'my-refresh-auctex-label-numbers-in-flymake))))

  ;; 首次启用持续编译时刷新一次标签号, 为大文件大项目设计
  (advice-add 'auctex-cont-latexmk-turn-on
              :after
              (lambda ()
                  (run-with-timer 1.0 nil
                                  #'my-refresh-auctex-label-numbers-in-flymake)))

  (define-key TeX-mode-map (kbd "C-c k") #'auctex-cont-latexmk-toggle))


;; {{
;; 以下函数改编自 https://gitee.com/mickey991/emacs-config/tree/master/demo-emacs-config/ELatex
;; 并使用MIT许可
;; - my-TeX-fold-config
;; - my-LaTeX-fonts-config
;; - my-more-prettified-symbols
;; - my-set-cdlatex-command-alist
;; - my-set-cdlatex-env-alist
;; - my-set-cdlatex-math-modify-alist
;; - my-set-cdlatex-math-symbol-alist
(defun my-TeX-fold-config ()
  ;; (setq TeX-fold-type-list '(env macro comment math)
  (setq TeX-fold-type-list '(env macro comment)
        TeX-fold-env-spec-list '(("[comment]" ("comment")) ("[proof]" ("proof")))
        LaTeX-fold-env-spec-list '(("frame" ("frame")))
        TeX-fold-macro-spec-list
        (append
         '(("[c]" ("cite"))
           ("[l]" ("label"))
           ("[r]" ("ref" "pageref" "eqref" "footref")))
         TeX-fold-macro-spec-list)))

(defun my-LaTeX-fonts-config ()
  (setq LaTeX-font-list
        (append
        '((?m "\\textmc{" "}" "\\mathmc{" "}")
          (?g "\\textgt{" "}" "\\mathgt{" "}")
          (?e "\\en{" "}")
          (?c "\\cn{" "}")
          (?4 "$" "$"))
          LaTeX-font-list)))

(defun my-more-prettified-symbols ()
  (my-ensure 'tex-mode) ; 载入 tex--prettify-symbols-alist 变量
  (mapc (lambda (pair) (delete pair tex--prettify-symbols-alist))
        '(("\\supset" . 8835)))
  (mapc (lambda (pair) (cl-pushnew pair tex--prettify-symbols-alist))
        '(;; brackets
          ("\\big(" . ?\N{Z notation left image bracket}) ; ⦇, #x2987
          ("\\bigl(" . ?\N{Z notation left image bracket}) ; ⦇, #x2987
          ("\\big)" . ?\N{Z notation right image bracket}) ; ⦈ #x2988
          ("\\bigr)" . ?\N{Z notation right image bracket}) ; ⦈ #x2988
          ("\\Big(" . ?\N{left white parenthesis}); ⦅ #x2985
          ("\\Bigl(" . ?\N{left white parenthesis}); ⦅ #x2985
          ("\\Big)" . ?\N{right white parenthesis}) ; ⦆ #x2986
          ("\\Bigr)" . ?\N{right white parenthesis}) ; ⦆ #x2986
          ("\\bigg(" . ?\N{left double parenthesis}) ; ⸨
          ("\\biggl(" . ?\N{left double parenthesis}) ; ⸨
          ("\\bigg)" . ?\N{right double parenthesis}) ; ⸩
          ("\\biggr)" . ?\N{right double parenthesis}) ; ⸩
          ("\\big[" . ?\N{mathematical left white tortoise shell bracket}) ; ⟬
          ("\\bigl[" . ?\N{mathematical left white tortoise shell bracket}) ; ⟬
          ("\\big]" . ?\N{mathematical right white tortoise shell bracket}) ; ⟭
          ("\\bigr]" . ?\N{mathematical right white tortoise shell bracket}) ; ⟭
          ("\\Big[" . ?\N{mathematical left white square bracket}) ; ⟦ #x27E6
          ("\\Bigl[" . ?\N{mathematical left white square bracket}) ; ⟦ #x27E6
          ("\\Big]" . ?\N{mathematical right white square bracket}) ; ⟧ #x27E7
          ("\\Bigr]" . ?\N{mathematical right white square bracket}) ; ⟧ #x27E7
          ("\\bigg[" . ?\N{left white lenticular bracket}) ; 〖
          ("\\biggl[" . ?\N{left white lenticular bracket}) ; 〖
          ("\\bigg]" . ?\N{right white lenticular bracket}) ; 〗
          ("\\biggr]" . ?\N{right white lenticular bracket}) ; 〗
          ("\\{" . ?\N{medium left curly bracket ornament}) ; ❴
          ("\\}" . ?\N{medium right curly bracket ornament}) ; ❵
          ("\\big\\{" . ?\N{left white curly bracket}) ; ⦃
          ("\\bigl\\{" . ?\N{left white curly bracket}) ; ⦃
          ("\\big\\}" . ?\N{right white curly bracket}) ; ⦄
          ("\\bigr\\}" . ?\N{right white curly bracket}) ; ⦄
          ("\\Big\\{" . ?\N{left arc less-than bracket}) ; ⦓
          ("\\Bigl\\{" . ?\N{left arc less-than bracket}) ; ⦓
          ("\\Big\\}" . ?\N{right arc greater-than bracket}) ; ⦔
          ("\\Bigr\\}" . ?\N{right arc greater-than bracket}) ; ⦔
          ("\\bigg\\{" . ?\N{double left arc greater-than bracket}) ; ⦕
          ("\\biggl\\{" . ?\N{double left arc greater-than bracket}) ; ⦕
          ("\\bigg\\}" . ?\N{double right arc less-than bracket}) ; ⦖
          ("\\biggr\\}" . ?\N{double right arc less-than bracket}) ; ⦖
          ("\\big|" .?\N{left wiggly fence}) ; ⧘
          ("\\bigl|" .?\N{left wiggly fence}) ; ⧘
          ("\\bigr|" .?\N{left wiggly fence}) ; ⧘
          ("\\lvert" .?\N{left wiggly fence}) ; ⧘
          ("\\rvert" .?\N{left wiggly fence}) ; ⧚
          ("\\Big|" .?\N{left double wiggly fence}) ; ⧚
          ("\\Bigl|" .?\N{left double wiggly fence}) ; ⧚
          ("\\Bigr|" .?\N{left double wiggly fence}) ; ⧚
          ("\\lVert" .?\N{DOUBLE VERTICAL LINE}) ; ‖
          ("\\rVert" .?\N{DOUBLE VERTICAL LINE}) ; ‖
          ("\\coloneq" .?\N{colon equal}); ≔
          ("\\eqcolon" .?\N{equal colon}); ≕
          ;; blackboard bold/double-struck
          ("\\Z" . ?\N{double-struck capital Z}) ; ℤ 8484
          ("\\Q" . ?\N{double-struck capital Q}) ; ℚ 8474
          ("\\N" . ?\N{double-struck capital N}) ; ℕ 8469
          ("\\R" . ?\N{double-struck capital R}) ; ℝ 8477
          ("\\PP" . ?\N{double-struck capital P}) ; ℙ #x2119
          ("\\HH" . ?\N{double-struck capital H}) ; ℍ
          ("\\EE" . ?\N{mathematical double-struck capital E}) ; 𝔼 #x1D53C
          ("\\mathbb{S}" . ?\N{mathematical double-struck capital S}) ; 𝕊 #x1D54A
          ("\\ONE" . ?\N{mathematical double-struck digit ONE}) ; 𝟙 #x1D7D9
          ;; bold face
          ("\\Pp" . ?\N{mathematical bold capital P}) ; 𝐏 #x1D40F
          ("\\Qq" . ?\N{mathematical bold capital Q}) ; 𝐐
          ("\\Ee" . ?\N{mathematical bold capital E}) ; 𝐄 #x1D404
          ("\\bb" . ?\N{mathematical bold small b}) ; 𝐛
          ("\\mm" . ?\N{mathematical bold small m}) ; 𝐦
          ;; calligraphy
          ("\\Fc" . ?\N{script capital F}) ; ℱ #x2131
          ("\\Nc" . ?\N{mathematical script capital N}) ; 𝒩 #x1D4A9
          ("\\Zc" . ?\N{mathematical script capital Z}) ; 𝒵
          ("\\Pc" . ?\N{mathematical script capital P}) ; 𝒫
          ("\\Qc" . ?\N{mathematical script capital Q}) ; 𝒫
          ;; san-serif
          ("\\P" . ?\N{mathematical sans-serif capital P}) ; 𝖯 #x1D5AF
          ("\\E" . ?\N{mathematical sans-serif capital E}) ; 𝖤 #x1D5A4
          ;; others
          ("\\supset" . ?\N{superset of}) ; ⊃
          ("\\temp" . ?\N{mathematical italic kappa symbol}) ; 𝜘, varkappa
          ("\\varnothing" . ?\N{empty set}) ; ∅
          ("\\dotsb" . 8943)
          ("\\dotsc" . 8230)
          ("\\eps" . 949))))


(defun my-set-cdlatex-command-alist ()
  "为了避免和 yasnippet 发生冲突, 只能修改键."
  (setq cdlatex-command-alist
        '(("lr|" "insert \\lvert ? \\rvert" "\\lvert ? \\rvert" cdlatex-position-cursor nil nil t)
          ("lv" "insert \\lVert ? \\rVert" "\\lVert ? \\rVert" cdlatex-position-cursor nil nil t)
          ("sq" "insert pairs of \\[ \\]" "\\[ ? \\]" cdlatex-position-cursor nil t t)
          ("ce" "insert :=" "\\coloneq " nil nil nil t)
          ("ec" "insert =:" "\\eqcolon " nil nil nil t)
          ("Big(" "insert \\Bigl( \\Bigr)" "\\Bigl( ? \\Bigr" cdlatex-position-cursor nil nil t)
          ("Big[" "insert \\Bigl[ \\Bigr]" "\\Bigl[ ? \\Bigr" cdlatex-position-cursor nil nil t)
          ("Big\\|" "insert \\Big\\lVert \\Big\\rVert" "\\Big\\lVert ? \\Big\\rVert" cdlatex-position-cursor nil nil t)
          ("Big{" "insert \\Bigl\\{ \\Bigr\\}" "\\Bigl\\{ ? \\Bigr\\" cdlatex-position-cursor nil nil t)
          ("Big|" "insert \\Big\\lvert \\Bigr\rvert" "\\Big\\lvert ? \\Big\\rvert" cdlatex-position-cursor nil nil t)
          ("aali" "insert equation" "\\left\\{\n\\begin{aligned}\n? \n\\end{aligned}\\right." cdlatex-position-cursor nil nil t)
          ("alb" "Insert beamer alert block with overlay" "\\begin{alertblock}<+->{ ? } \n\n\\end{alertblock}" cdlatex-position-cursor nil t nil)
          ("alb*" "Insert beamer alert block without overlay" "\\begin{alertblock}{ ? } \n\n\\end{alertblock}" cdlatex-position-cursor nil t nil)
          ("big(" "insert \\bigl( \\bigr)" "\\bigl( ? \\bigr" cdlatex-position-cursor nil nil t)
          ("big[" "insert \\bigl[ \\bigr]" "\\bigl[ ? \\bigr" cdlatex-position-cursor nil nil t)
          ("big\\|" "insert \\big\\lvert \\big\\rvert" "\\big\\lvert ? \\big\\rvert" cdlatex-position-cursor nil nil t)
          ("big{" "insert \\bigl\\{ \\bigr\\}" "\\bigl\\{ ? \\bigr\\" cdlatex-position-cursor nil nil t)
          ("big|" "insert \\big\\lvert \\big\\rvert" "\\big\\lvert ? \\big\\rvert" cdlatex-position-cursor nil nil t)
          ("bigg(" "insert \\biggl( \\biggr)" "\\biggl( ? \\biggr" cdlatex-position-cursor nil nil t)
          ("bigg[" "insert \\biggl[ \\biggr]" "\\biggl[ ? \\biggr" cdlatex-position-cursor nil nil t)
          ("bigg\\|" "insert \\bigg\\lvert \\bigg\\rvert" "\\bigg\\lvert ? \\bigg\\rvert" cdlatex-position-cursor nil nil t)
          ("bigg{" "insert \\biggl\\{ \\biggr\\}" "\\biggl\\{ ? \\biggr\\" cdlatex-position-cursor nil nil t)
          ("bigg|" "insert \\bigg\\lvert \\bigg\\rvert" "\\bigg\\lvert ? \\bigg\\rvert" cdlatex-position-cursor nil nil t)
          ("Bigg(" "insert \\Biggl( \\Biggr)" "\\Biggl( ? \\Biggr" cdlatex-position-cursor nil nil t)
          ("Bigg[" "insert \\Biggl[ \\Biggr]" "\\Biggl[ ? \\Biggr" cdlatex-position-cursor nil nil t)
          ("Bigg\\|" "insert \\Bigg\\lvert \\Bigg\\rvert" "\\Bigg\\lvert ? \\Bigg\\rvert" cdlatex-position-cursor nil nil t)
          ("Bigg{" "insert \\Biggl\\{ \\Biggr\\}" "\\Biggl\\{ ? \\Biggr\\" cdlatex-position-cursor nil nil t)
          ("Bigg|" "insert \\Bigg\\lvert \\Bigg\\rvert" "\\Bigg\\lvert ? \\Bigg\\rvert" cdlatex-position-cursor nil nil t)
          ("fa" "Insert \\frac{}{}" "\\frac{?}{}" cdlatex-position-cursor nil nil t)           ; 不能是 fr
          ("fc" "Insert \\frac{}{}" "\\frac{?}{}" cdlatex-position-cursor nil nil t)
          ("an" "Insert an ALIGN environment template" "" cdlatex-environment ("align") t nil) ; 不能是 ali
          ("ag" "Insert an ALIGN environment template" "" cdlatex-environment ("align") t nil) ; 不能是 ali
          ("align" "Insert an ALIGN environment template" "" cdlatex-environment ("align") t nil)
          ("ie" "New item in current environment" "" cdlatex-item nil t t)   ; 不能是 it
          ("blo" "Insert beamer block with overlay" "\\begin{block}<+->{ ? } \n\n\\end{block}" cdlatex-position-cursor nil t nil)
          ("blo*" "Insert beamer block WITHOUT overlay" "\\begin{block}{ ? } \n\n\\end{block}" cdlatex-position-cursor nil t nil)
          ("bn" "binomial" "\\binom{?}{}" cdlatex-position-cursor nil nil t)
          ("capl" "insert \\bigcap\\limits_{}^{}" "\\bigcap\\limits_{?}^{}" cdlatex-position-cursor nil nil t)
          ("case" "insert cases" "\\begin{cases}\n? & \\\\\n &\n\\end{cases}" cdlatex-position-cursor nil nil t)
          ("cd" "insert dotsb" "\\dotsb" nil nil t t)
          ("cupl" "insert \\bigcup\\limits_{}^{}" "\\bigcup\\limits_{?}^{}" cdlatex-position-cursor nil nil t)
          ("ds" "insert ddots" "\\ddots" nil nil t t)
          ("def" "insert definition env" "" cdlatex-environment ("definition") t nil)
          ("des" "insert description" "" cdlatex-environment ("description") t nil)
          ("enu*" "insert enu" "\\begin{enumerate}\n\\item ?\n\\end{enumerate}" cdlatex-position-cursor nil t nil)
          ("equ*" "insert unlabel equation" "" cdlatex-environment ("equation*") t nil)
          ("exb" "Insert beamer example block with overlay" "\\begin{exampleblock}<+->{ ? } \n\n\\end{exampleblock}" cdlatex-position-cursor nil t nil)
          ("exb*" "Insert beamer example block without overlay" "\\begin{exampleblock}{ ? } \n\n\\end{exampleblock}" cdlatex-position-cursor nil t nil)
          ("exe" "Insert exercise" "\\begin{exercise}\n? \n\\end{exercise}" cdlatex-position-cursor nil t nil)
          ("fra" "insert frame (for beamer)" "" cdlatex-environment ("frame") t nil)
          ("hhl" "insert \\ \\hline" "\\\\ \\hline" ignore nil t nil)
          ("hl" "insert \\hline" "\\hline" ignore nil t nil)
          ("ipenu" "insert in paragraph enumerate" "" cdlatex-environment ("inparaenum") t nil)
          ("ipite" "insert in paragraph itemize" "" cdlatex-environment ("inparaitem") t nil)
          ("im" "insert \\item" "\\item?" cdlatex-position-cursor nil t nil)
          ("ld" "insert dotsc" "\\dotsc" nil nil t t)
          ("lma" "insert lemma env" "" cdlatex-environment ("lemma") t nil)
          ("liml" "insert \\lim\\limits_{}" "\\lim\\limits_{?}" cdlatex-position-cursor nil nil t)
          ("lr<" "insert bra-ket" "\\langle ? \\rangle" cdlatex-position-cursor nil nil t)
          ("myenu" "insert in my enumerate for beamer" "" cdlatex-environment ("myenumerate") t nil)
          ("myite" "insert in my itemize for beamer" "" cdlatex-environment ("myitemize") t nil)
          ("ons" "" "\\onslide<?>{ }" cdlatex-position-cursor nil t t)
          ("pa" "insert pause" "\\pause" ignore nil t nil)
          ("pro" "insert proof env" "" cdlatex-environment ("proof") t nil)
          ("prodl" "insert \\prod\\limits_{}^{}" " \\prod\\limits_{?}^{}" cdlatex-position-cursor nil nil t)
          ("prop" "insert proposition" "" cdlatex-environment ("proposition") t nil)
          ("se" "insert \\{\\}" "\\{ ? \\}" cdlatex-position-cursor nil nil t)
          ("spl" "insert split" "" cdlatex-environment ("split") nil t)
          ("st" "stackrel" "\\stackrel{?}{}" cdlatex-position-cursor nil nil t)
          ("te" "insert text" "\\text{?}" cdlatex-position-cursor nil nil t)
          ("the" "insert theorem env" "" cdlatex-environment ("theorem") t nil)
          ("cte" "insert citation using helm-bibtex" "" helm-bibtex-with-local-bibliography nil t nil)
          ("vd" "insert vdots" "\\vdots" nil nil t t))))

(defun my-set-cdlatex-env-alist ()
  (setq cdlatex-env-alist
        '(("definition" "\\begin{definition}\n\\label{def:?}\n\n\\end{definition}" nil)
          ("enumerate" "\\begin{enumerate}[?]\n\\item \n\\end{enumerate}" "\\item ?")
          ("equation*" "\\begin{equation*}\n? \n\\end{equation*}" nil)
          ("exercise" "\\begin{exercise}[?]\n\n\\end{exercise}" nil)
          ("frame" "\\begin{frame}{ ? }\n\n\\end{frame}" nil)
          ("inparaenum" "\\begin{inparaenum}\n\\item ? \n\\end{inparaenum}" "\\item ?")
          ("inparaitem" "\\begin{inparaitem}\n\\item ?\n\\end{inparaitem}" "\\item ?")
          ("lemma" "\\begin{lemma}\n\\label{lem:?}\n\n\\end{lemma}" nil)
          ("myenumerate" "\\begin{myenumerate}\n\\item ?\n\\end{myenumerate}" "\\item ?")
          ("myitemize" "\\begin{myitemize}\n\\item ?\n\\end{myitemize}" "\\item ?")
          ("proof" "\\begin{proof}?\n\n\\end{proof}" nil)
          ("proposition" "\\begin{proposition}\n\n\\end{proposition}" nil)
          ("theorem" "\\begin{theorem}\n\\label{thm:?}\n\n\\end{theorem}" nil))))

(defun my-set-cdlatex-math-modify-alist ()
  (setq cdlatex-math-modify-alist
        '((?k "\\mathfrak" "" t nil nil)
          (?t "\\mathbb" "" t nil nil))))

(defun my-set-cdlatex-math-symbol-alist ()
  (setq cdlatex-math-symbol-alist
        '((?0 ("\\varnothing" "\\emptyset"))
          (?1 ("\\ONE" "\\one"))
          (?. ("\\cdot" "\\circ"))
          (?v ("\\vee" "\\bigvee"))
          (?& ("\\wedge" "\\bigwedge"))
          (?9 ("\\cap" "\\bigcap" "\\bigoplus"))
          (?+ ("\\cup" "\\bigcup" "\\oplus"))
          (?- ("\\rightharpoonup" "\\hookrightarrow" "\\circlearrowleft"))
          (?= ("\\equiv" "\\Leftrightarrow" "\\Longleftrightarrow"))
          (?~ ("\\sim" "\\approx" "\\propto"))
          (?L ("\\Lambda" "\\limits"))
          (?* ("\\times" "\\otimes" "\\bigotimes"))
          (?e ("\\eps" "\\epsilon" "\\exp\\Big( ? \\Big)"))
          (?> ("\\mapsto" "\\longrightarrow" "\\rightrightarrows"))
          (?< ("\\preceq" "\\leftarrow" "\\longleftarrow"))
          (?| ("\\parallel" "\\mid" "\\perp"))
          (?S ("\\Sigma" "\\sum_{?}^{}"))
          (?{ ("\\subset" "\\prec" "\\subseteq"))
          (?} ("\\supset" "\\succ" "\\supseteq")))))
;; }}

(defun my-latex-tab-dispatch ()
  "Smart TAB for LaTeX: yasnippet > cdlatex > indent."
  (interactive)
  (cond
   ;; 1. 如果正在 snippet field 中，优先跳转
   ((and (bound-and-true-p yas-minor-mode)
         (yas--snippets-at-point))
    (yas-next-field-or-maybe-expand))

   ;; 2. 尝试展开 yasnippet（不要预判）
   ((and (bound-and-true-p yas-minor-mode)
         (yas-expand))
    t)

   ;; 3. CDLaTeX
   ((bound-and-true-p cdlatex-mode)
    (cdlatex-tab)
    t)

   ;; 4. fallback
   (t
    (indent-for-tab-command))))


(with-eval-after-load 'tex
  (my-auctex-setup)

  (my-more-prettified-symbols) ;; LaTeX 命令与 Unicode 符号的映射, 输入'\+符号'

  ;; 在编译完成后刷新 pdf 文件
  (add-hook 'TeX-after-compilation-finished-functions
            #'TeX-revert-document-buffer)

  ;; 在编译完成后刷新标签号和折叠
  (add-hook 'TeX-after-compilation-finished-functions
            #'my-refresh-auctex-label-numbers)

  (my-ensure 'evil-tex)
  ;; 不要全局，只在 LaTeX buffer
  (add-hook 'LaTeX-mode-hook #'evil-tex-mode t))

;; 确保 AUCTeX 已经加载
(with-eval-after-load 'latex
  ;; 加载 CDLaTeX
  (my-ensure 'cdlatex)
  (add-hook 'LaTeX-mode-hook #'turn-on-cdlatex t)
  (add-hook 'latex-mode-hook #'turn-on-cdlatex t)

  (my-LaTeX-fonts-config)             ;;  LaTeX 字体映射, 字体美化, 插入快捷键C-c C-f + key

  (setq cdlatex-paired-parens "$([{") ;; 默认推荐无 "()" 补全.

  ;; cdlatex
  (my-set-cdlatex-command-alist)      ;; 快捷插入的 LaTeX 宏和符号, key+<TAB>
  (my-set-cdlatex-env-alist)          ;; 定义快捷插入的 LaTeX 环境, C-c { <env-name> evil: leader+c+name
  (my-set-cdlatex-math-modify-alist)  ;; 定义数学模式下的字体修饰
  (my-set-cdlatex-math-symbol-alist)  ;; 定义数学符号 ` + key

  ;; 必须在auctex后面
  (my-auctex-cont-latexmk-setup))

(with-eval-after-load 'tex-fold
  (my-TeX-fold-config)         ;; 折叠 LaTeX 文档中的环境, 宏和注释
  )

(with-eval-after-load 'evil
  (add-hook 'LaTeX-mode-hook
            (lambda ()
              (define-key evil-insert-state-local-map
                          (kbd "TAB") #'my-latex-tab-dispatch))))


(setq my-latex-function-list
      '(my-synctex-setup
        my-reftex-setup
        my-preview-setup
        turn-on-auto-fill))   ;; 自动换行, 自动进行缩进
        ;; flymake-mode ))    ;; auctex查找风格错误, 如果使用持续编译更新标签号需要禁止,
                              ;; 否则可能会和auctex-cont-latexmk的flymake-mode产生冲突

;; LaTeX（无论是 AUCTeX 或内置）共同 hook
(dolist (my-latex-function my-latex-function-list)
  (add-hook 'LaTeX-mode-hook my-latex-function t)
  (add-hook 'latex-mode-hook my-latex-function t))


;; TeX-mode 的基础设置
(add-hook 'TeX-mode-hook
          (lambda ()
            (TeX-fold-mode 1)))  ;; 启用折叠功能

;; LaTeX-mode 的完整设置
(add-hook 'LaTeX-mode-hook
          (lambda ()
            (my-ensure 'auctex-label-numbers)
            ;; 显示折叠的标签的编号.如果修改需要重新编译*TeX文件
            ;; 需要启用TeX-fold-mode
            ;; auctex-label-numbers-mode需编译之后读取.aux 文件才能生效
            ;; 更新这些编号, 需要重新编译文档, 重新生成预览, k并刷新折叠
            (auctex-label-numbers-mode 1)
            ;; 确保 font-lock 完成后折叠
            (font-lock-ensure)
            ;; run TeX-fold-buffer *after* font-lock is ready
            ;; TeX-fold-type-list提供折叠内容
            (TeX-fold-buffer))) ;; 自动折叠所有可折叠内容(注释,标签等)



(provide 'init-LaTeX-mode)
;;; init-LaTeX-mode.el ends here
