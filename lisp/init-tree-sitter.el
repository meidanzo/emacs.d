;; -*- coding: utf-8; lexical-binding: t; -*-

(require 'treesit nil t)
(defvar treesit-extra-load-path nil)
(defvar treesit-language-source-alist nil)

(add-to-list 'treesit-extra-load-path "~/.emacs.d/tree-sitter")

(defcustom my-python-auto-install-treesit-grammar t
  "Whether to install the Python tree-sitter grammar when it is missing.
Installation requires Git and a C/C++ compiler.  It is skipped in
non-interactive Emacs, and only runs when a Python language server is
available."
  :type 'boolean
  :group 'python)

(when (and (fboundp 'treesit-available-p)
           (treesit-available-p)
           (fboundp 'treesit-language-available-p)
           (treesit-language-available-p 'python))
  (setq my/python-treesit-installed t))

(defun my-python-langserver-exist ()
  "Return an installed Python language server executable, or nil."
  (or (executable-find "basedpyright-langserver")
      (executable-find "pyright-langserver")
      (executable-find "pylsp")))

(defun my-test-python-treesit-exist ()
  "Return non-nil when tree-sitter and a Python language server are available."
  (and (fboundp 'treesit-available-p)
       (treesit-available-p)
       (my-python-langserver-exist)))

(when (and (not noninteractive)
           my-python-auto-install-treesit-grammar
           (not (bound-and-true-p my/python-treesit-installed))
           (my-test-python-treesit-exist))
  (condition-case err
      (progn
        ;; Update only Python's recipe; do not replace the whole alist.
        (setf (alist-get 'python treesit-language-source-alist)
              `("https://github.com/tree-sitter/tree-sitter-python"
                ,(if (< (treesit-library-abi-version) 15)
                     "v0.23.6"
                   "master")))
        (treesit-install-language-grammar 'python)
        (unless (treesit-language-available-p 'python)
          (message "Python tree-sitter grammar still unavailable after install.")))
    (error (message "Python tree-sitter grammar install failed: %s" err))))

(provide 'init-tree-sitter)