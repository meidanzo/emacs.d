;;; init-LaTeX-mode.el --- AUCTeX + latexmk + XeLaTeX + RefTeX + CDLaTeX + amsreftex + Zathura -*- lexical-binding: t; -*-
;;; Commentary:
;;; ================= AUCTeX + latexmk + XeLaTeX + RefTeX + CDLaTeX + amsreftex + Zathura =================

;; - 主要功能
;; 支持中文 -> xetex
;; 自动项目编译 -> latexmk
;; 正向/反向搜索 -> SyncTeX  + ~/.config/zathura/zathurarc
;; C-c C-a不高亮 -> my-TeX-run-all-no-sync
;; C-c C-v高亮当前行 (-> SyncTeX ?) -> TeX-command-run-all -> TeX-view -> TeX-view-program-list
;; 持续预览(PVS) -> LatexMk-PVC + ~/.latexmkrc
;; org-mode中文文件可以转换成正确的LaTeX文件并通过编译 -> org-latex-classes

;; - 使用方法
;; 编译: C-c C-c -> LatexMk
;; 自动实时预览: C-c C-c → LatexMk-PVC
;; 正向搜索(PDF): C-c C-v
;; 反向搜索：在 Zathura 中按中键或 Ctrl+左键 (依 Zathura 配置)

;; - 问题
;; yasnippet和AUCTeX, CDLaTeX 快捷键<TAB>快捷键只有一个. 
;; 我记得, 没有用函数进行模块化的时候两个都是可以用的(init-old.el)
;; 这到底是为什么? 头疼

;;; Code:

;; --- AUCTeX 配置 ---
(defun my-auctex-setup ()
  (my-ensure 'tex)
  (setq-default TeX-master nil
                TeX-engine 'xetex)
  (setq TeX-auto-save t
        TeX-parse-self t
        TeX-auto-untabify t ;; 保存时自动将 tab 转为空格
        TeX-command-default "LatexMk"
        TeX-PDF-mode t)

  (add-hook 'TeX-after-compilation-finished-functions
            #'TeX-revert-document-buffer) ;; 在完成编译后刷新 pdf 文件

  ;; --- latexmk 编译命令 ---
  (add-to-list 'TeX-command-list
               '("LatexMk"
                 "latexmk -xelatex -interaction=nonstopmode -synctex=1 %s"
                 TeX-run-command nil t
                 :help "Run latexmk"))

  ;; (my-ensure 'auctex-cont-latexmk)
  ;; 可选：持续预览(PVS)
  (unless (assoc "LatexMk-PVC" TeX-command-list)
    (add-to-list 'TeX-command-list
                 '("LatexMk-PVC"
                   "latexmk -xelatex -interaction=nonstopmode -synctex=1 -pvc %s"
                   TeX-run-command nil t
                   :help "Run latexmk continuously"))))



;; --- 启用RefTeX(Emacs内置) ---
(defun my-reftex-setup ()
  (my-ensure 'reftex)
  (my-ensure 'amsreftex)
  (turn-on-reftex)
  (amsreftex-turn-on)

  ;; 启用 RefTeX, 并集成到 AucTeX 中, 在 LaTeX 模式中自动启用 RefTeX
  ;; 让 RefTeX 与 AUCTeX 配合更紧密, 这是关键配置
  (setq reftex-parse-all t
        reftex-enable-partial-scans t             ;; RefTeX 只扫描正在编辑的部分(或最近修改的部分),提高性能
        reftex-save-parse-info t
        reftex-use-multiple-selection-buffers t
        reftex-plug-into-AUCTeX t
        reftex-ref-macro-prompt nil               ;; ~ref<tab>~ 后不提示类型
        reftex-trust-label-prefix t
        reftex-label-menu-flags '(t t nil nil t nil t t)))


;; --- SyncTeX 配置 ---
(defun my-synctex-setup ()
  ;; --- 启动 Emacs server (反向搜索需要) ---
  (require 'server)
  (unless (server-running-p)
    (server-start))

  (setq TeX-source-correlate-method 'synctex
        TeX-source-correlate-start-server t) ;; 允许 PDF 点击跳转, 用于 SyncTeX 功能: 从 PDF 点击可以跳转到 TeX 源码
  (TeX-source-correlate-mode)                ;; 打开源代码关联

  ;; --- PDF 查看器设为 Zathura ---
  (setq TeX-view-program-list
        '(("Zathura-NoSync" "zathura %o")
          ("Zathura-Sync" "zathura --synctex-forward %n:0:%b %o")))

  (setq TeX-view-program-selection
        '((output-pdf "Zathura-NoSync"))) ;; 默认 C-c C-a 不使用同步

  (define-key TeX-mode-map (kbd "C-c C-v") #'my-TeX-run-all-no-sync))

;; C-c C-v 使用同步
(defun my-TeX-run-all-no-sync ()
  "Run TeX-command-run-all but without SyncTeX highlighting."
  (interactive)
  (let ((TeX-view-program-selection
         '((output-pdf "Zathura-Sync"))))
    (call-interactively 'TeX-command-run-all))) ;; 正确调用方式

;; 预览与美化
(defun my-preview-setup ()
  ;; 光标移动到一个被替换成符号的地方时, 暂时显示原始文本
  (setq prettify-symbols-unprettify-at-point t)
  ;; (set-fontset-font "fontset-default" '(#x10000 . #x1FFFF) "Cambria Math" nil 'prepend)
  (set-fontset-font "fontset-default" 'mathematical "Cambria Math")
  (prettify-symbols-mode) ;; 预览tex文件, 把某些字符自动用 Unicode 符号显示
  )

;; - my-TeX-fold-config
;; - my-TeX-fonts-config
;; - my-more-prettified-symbols
;; - my-set-cdlatex-command-alist
;; - my-set-cdlatex-env-alist
;; - my-set-cdlatex-math-modify-alist
;; - my-set-cdlatex-math-symbol-alist
;; 来自 https://gitee.com/mickey991/emacs-config/tree/master/demo-emacs-config/ELatex
(defun my-TeX-fold-config ()
  (setq TeX-fold-type-list '(env macro comment)
        TeX-fold-env-spec-list '(("[comment]" ("comment")) ("[proof]" ("proof")))
        LaTeX-fold-env-spec-list '(("frame" ("frame")))
        TeX-fold-macro-spec-list
        '(("[f]" ("footnote" "marginpar"))
          ("[c]" ("cite"))
          ("[l]" ("label"))
          ("[r]" ("ref" "pageref" "eqref"))
          ("[i]" ("index" "glossary"))
          ("[1]:||*" ("item"))
          ("..." ("dots"))
          ("(C)" ("copyright"))
          ("(R)" ("textregistered"))
          ("TM" ("texttrademark"))
          (1 ("emph" "textit" "textsl" "textmd" "textrm" "textsf" "texttt" "textbf" "textsc" "textup")))))

(defun my-TeX-fonts-config ()
  (setq LaTeX-font-list
        '((?m "\\textmc{" "}" "\\mathmc{" "}")
          (?g "\\textgt{" "}" "\\mathgt{" "}")
          (?e "\\en{" "}")
          (?c "\\cn{" "}")
          (?4 "$" "$")
          (1 "" "" "\\mathcal{" "}")
          (2 "\\textbf{" "}" "\\mathbf{" "}")
          (3 "\\textsc{" "}")
          (5 "\\emph{" "}")
          (6 "\\textsf{" "}" "\\mathsf{" "}")
          (9 "\\textit{" "}" "\\mathit{" "}")
          (12 "\\textulc{" "}")
          (13 "\\textmd{" "}")
          (14 "\\textnormal{" "}" "\\mathnormal{" "}")
          (18 "\\textrm{" "}" "\\mathrm{" "}")
          (19 "\\textsl{" "}" "\\mathbb{" "}")
          (20 "\\texttt{" "}" "\\mathtt{" "}")
          (21 "\\textup{" "}")
          (23 "\\textsw{" "}")
          (4 "" "" t))))

(defun my-more-prettified-symbols ()
  ;; (require 'tex-mode) ; 载入 tex--prettify-symbols-alist 变量
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
  (setq cdlatex-command-alist
        '(("lr|" "insert \\lvert ? \\rvert" "\\lvert ? \\rvert" cdlatex-position-cursor nil nil t)
          ("no" "insert \\lVert ? \\rVert" "\\lVert ? \\rVert" cdlatex-position-cursor nil nil t)
          ("eq" "insert pairs of \\[ \\]" "\\[ ? \\]" cdlatex-position-cursor nil t t)
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
          ("blo" "Insert beamer block with overlay" "\\begin{block}<+->{ ? } \n\n\\end{block}" cdlatex-position-cursor nil t nil)
          ("blo*" "Insert beamer block WITHOUT overlay" "\\begin{block}{ ? } \n\n\\end{block}" cdlatex-position-cursor nil t nil)
          ("bn" "binomial" "\\binom{?}{}" cdlatex-position-cursor nil nil t)
          ("capl" "insert \\bigcap\\limits_{}^{}" "\\bigcap\\limits_{?}^{}" cdlatex-position-cursor nil nil t)
          ("case" "insert cases" "\\begin{cases}\n? & \\\\\n &\n\\end{cases}" cdlatex-position-cursor nil nil t)
          ("cd" "insert dotsb" "\\dotsb" nil nil t t)
          ("cupl" "insert \\bigcup\\limits_{}^{}" "\\bigcup\\limits_{?}^{}" cdlatex-position-cursor nil nil t)
          ("dd" "insert ddots" "\\ddots" nil nil t t)
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
          ("it" "insert \\item" "\\item?" cdlatex-position-cursor nil t nil)
          ("ld" "insert dotsc" "\\dotsc" nil nil t t)
          ("lem" "insert lemma env" "" cdlatex-environment ("lemma") t nil)
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
          ("thm" "insert theorem env" "" cdlatex-environment ("theorem") t nil)
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


(with-eval-after-load 'tex
  (my-auctex-setup)
)

;; 确保 AUCTeX 已经加载
(with-eval-after-load 'latex
  ;; 加载 CDLaTeX
  (my-ensure 'cdlatex)
  ;; 可选：添加钩子到 LaTeX-mode
  (add-hook 'LaTeX-mode-hook #'turn-on-cdlatex)
  (add-hook 'latex-mode-hook #'turn-on-cdlatex)

  (my-ensure 'tex-mode)
  ;; tex
  ;; 折叠 LaTeX 文档中的环境, 宏和注释
  (my-TeX-fold-config)
  ;;  LaTeX 字体映射, 字体美化
  (my-TeX-fonts-config)
  ;; LaTeX 命令与 Unicode 符号的映射
  (my-more-prettified-symbols)
  ;; cdlatex
  ;; 快捷插入的 LaTeX 宏和符号
  (my-set-cdlatex-command-alist)
  ;; 定义快捷插入的 LaTeX 环境
  (my-set-cdlatex-env-alist)
  ;; 定义数学模式下的字体修饰
  (my-set-cdlatex-math-modify-alist)
  ;; 定义数学符号快捷键 `触发
  (my-set-cdlatex-math-symbol-alist))

(setq my-latex-function-list
      '(my-reftex-setup
        my-synctex-setup
        my-preview-setup
        turn-on-auto-fill   ;; 自动换行, 自动进行缩进
        flymake-mode ))     ;; 查找风格错误

;; LaTeX（无论是 AUCTeX 或内置）共同 hook
(dolist (my-latex-function my-latex-function-list)
  (add-hook 'LaTeX-mode-hook my-latex-function t)
  (add-hook 'latex-mode-hook my-latex-function t))

(add-hook 'LaTeX-mode-hook (lambda ()
                             (TeX-fold-mode 1)))  ;; 启用折叠功能

(add-hook 'TeX-mode-hook
          (lambda ()
            ;; run TeX-fold-buffer *after* font-lock is ready
            ;; TeX-fold-type-list提供折叠内容
            (add-hook 'find-file-hook #'TeX-fold-buffer nil t))) ;; 自动折叠所有可折叠内容(注释,标签等)

(provide 'init-LaTeX-mode)
;;; init-LaTeX-mode.el ends here
