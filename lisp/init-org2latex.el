;;; package --- Summary init-org2latex.el --- ort-mode to LaTeX -*- lexical-binding: t; -*-
;;; Commentary:
;; org-mode中文文件可以转换成正确的LaTeX文件并通过编译 -> org-latex-classes
;; 如果嫌麻烦, 那么只需要在 org-mode 前面加上 `lisp/init-org2latex.el' 即可.
;; @see https://github.com/redguardtoo/emacs.d/issues/563
;;; Code:

(with-eval-after-load 'ox-latex

  ;; 如果使用 ctex* 那么下面三行不生效.
  (setf org-latex-default-packages-alist
        (remove '("AUTO" "inputenc" t) org-latex-default-packages-alist))
  (setf org-latex-default-packages-alist
        (remove '("T1" "fontenc" t) org-latex-default-packages-alist))
  (add-to-list 'org-latex-packages-alist
               '("" "fontspec" t))

  "修改默认类"
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
  (setq org-latex-default-class "ctexart"))

;; 设置org-mode打开pdf的时候用zathura
(setq org-file-apps
      '(("\\.pdf\\'" . "zathura %s")
        ("\\.x?html?\\'" . default)
        ("\\.\\(?:png\\|jpe?g\\|gif\\)\\'" . default)
        ("\\.mm\\'" . default)
        (auto-mode . emacs)
        (directory . emacs)
        ))

(provide 'init-org2latex)
;;; init-org2latex.el ends here