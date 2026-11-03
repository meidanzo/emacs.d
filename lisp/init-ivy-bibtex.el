;;; init-ivy-bibtex.el --- Emacs文献子系统 -*- lexical-binding: t; -*-
;;; Commentary:

;; my-ivy-bibtex-setup, my-ivy-insert-latex-citation 改编自 https://gitee.com/mickey991/emacs-config.git
;; Original source:
;;   https://gitee.com/mickey991/emacs-config.git
;; Copyright (c) 2023 金色飞贼 (小米)
;; Licensed under the MIT License

;;; Code

;; (defun my-ivy-insert-latex-citation (keys)
;;   (insert (format "\\cite{%s}" keys)))

;; (defun my-ivy-insert-latex-citation (keys)
;;   "Format KEYS as a comma-separated string for LaTeX citation."
;;   (format "\\cite{%s}" (string-join keys ",")))

;; (defvar my-latex-cite-command "\\cite")

;; (defun my-ivy-insert-latex-citation (keys)
;;   (insert (format "%s{%s}"
;;                   my-latex-cite-command
;;                   (string-join keys ","))))

(defun my-ivy-insert-latex-citation (keys)
  "Insert a LaTeX \\cite{} command for KEYS."
  (insert (format "\\cite{%s}" (string-join keys ","))))

(defun bibtex-completion-open-pdf-external (keys &optional fallback-action)
  "setup pdf view."
  (let ((bibtex-completion-pdf-open-function
         (lambda (fpath)
           (start-process "zathura" "*ivy-bibtex-zathura*"
                          (or (executable-find "zathura") "zathura") fpath))))
    (bibtex-completion-open-pdf keys fallback-action)))

(defun my-ivy-bibtex-setup ()
  ;; ivy-bibtex requires ivy's `ivy--regex-ignore-order` regex builder, which
  ;; ignores the order of regexp tokens when searching for matching candidates.
  ;; Add something like this to your init file:
  (setf (alist-get 'ivy-bibtex ivy-re-builders-alist)
        #'ivy--regex-ignore-order)

  ;; Paths with validation
  (let ((zot-bib "~/Documents/math/LaTeX/Zotero-Library/Ref-setting/Main.bib") ; Zotero .bib 文件
        (zot-pdf "~/Documents/math/LaTeX/Zotero-Library") ; Zotero 同步文件夹
        (org-notes "~/repos/notes/ref/")) ; org-roam 文献笔记目录

    (when (file-exists-p (expand-file-name zot-bib))
      (setq bibtex-completion-bibliography (list zot-bib)))

    (when (file-exists-p (expand-file-name zot-pdf))
      (setq bibtex-completion-library-path (list zot-pdf)))

    (when (file-exists-p (expand-file-name org-notes))
      (setq bibtex-completion-notes-path org-notes)))

  (setq bibtex-completion-pdf-symbol "⌘"
        bibtex-completion-notes-symbol "✎"

        bibtex-completion-cite-prompt-for-optional-arguments nil
        bibtex-completion-find-additional-pdfs t
        bibtex-completion-pdf-extension '(".pdf" ".djvu" ".jpg")
        bibtex-completion-browser-function
        (lambda (url _) (start-process "firefox" "*firefox*" "firefox" url))
        ivy-bibtex-default-action 'ivy-bibtex-insert-citation))


(with-eval-after-load 'ivy-bibtex

  (my-ivy-bibtex-setup)

  (ivy-bibtex-ivify-action
   bibtex-completion-open-pdf-external ivy-bibtex-open-pdf-external)

  (ivy-add-actions
   'ivy-bibtex
   '(("P" ivy-bibtex-open-pdf-external "Open PDF file in external viewer (if present)")))

  (add-to-list 'bibtex-completion-format-citation-functions
               '(LaTeX-mode . my-ivy-insert-latex-citation)
               '(latex-mode . my-ivy-insert-latex-citation)))

(provide 'init-ivy-bibtex)
;;; init-ivy-bibtex.el ends here