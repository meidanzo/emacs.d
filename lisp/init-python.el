;; -*- coding: utf-8; lexical-binding: t; -*-

(require 'project)

(with-eval-after-load 'python
  (unless (or (my-buffer-file-temp-p)
              (not buffer-file-name)
              ;; embed python code in org file
              (string= (file-name-extension buffer-file-name) "org"))
  ;; http://emacs.stackexchange.com/questions/3322/python-auto-indent-problem/3338#3338
  ;; emacs 24.4+
  (setq electric-indent-chars (delq ?: electric-indent-chars))))

;; {{ Python virtual environment
;; `pyvenv' activates environments inside Emacs.  Creation prefers `uv'
;; (https://docs.astral.sh/uv/) and falls back to Python's built-in
;; `venv' module.  The third-party `virtualenv' package is not required.
(defvar my-python-venv-directories
  (list (expand-file-name "~/.venv"))
  "Directories searched when selecting a Python virtual environment.")

(defcustom my-python-auto-activate-venv t
  "Whether to activate the project's .venv automatically.
The environment is activated only when it already exists."
  :type 'boolean
  :group 'python)

(defun my-python--project-root ()
  "Return the root directory of the current local project, or nil."
  (when-let* ((project (ignore-errors (project-current))))
    (let ((root (ignore-errors (project-root project))))
      ;; Activating a remote venv would put TRAMP paths into `exec-path'.
      (and root (not (file-remote-p root)) root))))

(defun my-python--project-venv ()
  "Return the current project's .venv directory when it exists."
  (when-let* ((root (my-python--project-root)))
    (let ((venv (expand-file-name ".venv" root)))
      (and (file-directory-p venv) venv))))

(defun my-python--default-venv-directory ()
  "Return the default directory for a new virtual environment."
  (if-let* ((root (my-python--project-root)))
      (expand-file-name ".venv" root)
    (expand-file-name "~/.venv")))

(defun my-python--venv-candidates ()
  "Return the existing Python virtual environment directories."
  (delete-dups
   (seq-filter #'file-directory-p
               (cons (my-python--project-venv)
                     (mapcar #'expand-file-name my-python-venv-directories)))))

(defun my-activate-python-venv (directory)
  "Activate the Python virtual environment in DIRECTORY.
DIRECTORY can be created by `uv venv' or `python -m venv'."
  (interactive
   (list (expand-file-name
          (read-directory-name "Activate Python venv: "
                               (or (my-python--project-venv)
                                   (car (my-python--venv-candidates)))
                               nil t))))
  (my-ensure 'pyvenv)
  (setq directory (expand-file-name directory))
  (if (file-directory-p directory)
      (progn
        (pyvenv-activate directory)
        (message "Activated Python venv: %s" directory))
    (user-error "Python venv does not exist: %s" directory)))

(defun my-python-create-venv (&optional directory)
  "Create a Python virtual environment in DIRECTORY and activate it.
Use `uv venv' when uv is available, otherwise fall back to
`python3 -m venv'.  Interactively, DIRECTORY defaults to the
current project's .venv directory."
  (interactive)
  (my-ensure 'pyvenv)
  (let* ((directory (expand-file-name
                     (or directory
                         (read-directory-name "Create Python venv: "
                                              (my-python--default-venv-directory)
                                              nil nil))))
         (uv (executable-find "uv"))
         (python (or (executable-find "python3")
                     (executable-find "python")))
         (program (or uv python))
         (args (if uv
                   (list "venv" directory)
                 (list "-m" "venv" directory))))
    (unless program
      (user-error "Neither uv nor python3 is available"))
    (unless (file-directory-p directory)
      (message "Creating Python venv in %s with %s..."
               directory (if uv "uv" "python"))
      (let ((buffer "*Python venv*"))
        (unless (eq 0 (apply #'call-process program nil buffer nil args))
          (display-buffer buffer)
          (user-error "Failed to create Python venv in %s" directory))))
    (my-activate-python-venv directory)))

(defun my-select-python-venv (&optional create)
  "Select and activate a Python virtual environment.
With prefix argument CREATE, create a new environment instead."
  (interactive "P")
  (if create
      (my-python-create-venv)
    (let ((directory (completing-read "Python venv (empty to create): "
                                      (my-python--venv-candidates)
                                      nil nil)))
      (cond
       ((string-empty-p directory)
        (my-python-create-venv))
       ((file-directory-p (expand-file-name directory))
        (my-activate-python-venv directory))
       (t
        (my-python-create-venv directory))))))

(defun my-python-auto-activate-venv ()
  "Activate the current project's .venv when it exists."
  (when my-python-auto-activate-venv
    (when-let* ((venv (my-python--project-venv)))
      (unless (and (bound-and-true-p pyvenv-virtual-env)
                   (equal (file-name-as-directory venv)
                          pyvenv-virtual-env))
        (my-activate-python-venv venv)))))
;; }}

(when (and (treesit-available-p)
           (executable-find "basedpyright-langserver")
           (not (treesit-language-available-p 'python)))
  (add-to-list 'treesit-extra-load-path "~/.emacs.d/tree-sitter")
  ;; treesit for smart syntax highlight
  (setq treesit-language-source-alist
        `((python "https://github.com/tree-sitter/tree-sitter-python"
                  ,(if (< (treesit-library-abi-version) 15)
                       "v0.23.6"
                     "master"))))
  (add-to-list 'treesit-language-source-alist
               `(python "https://github.com/tree-sitter/tree-sitter-python"
                        ,(if (< (treesit-library-abi-version) 15)
                             "v0.23.6"
                           "master")))
  (condition-case err
      (treesit-install-language-grammar 'python)
    (error (message "Python tree-sitter grammar install failed: %s" err)))
  (unless (treesit-language-available-p 'python)
    (message "Python tree-sitter grammar still unavailable after install.")))

;; Prepend instead of `setq': replacing the whole alist would discard
;; remappings added by other packages or by the user.
(when (treesit-language-available-p 'python)
  (setq major-mode-remap-alist
        (cons '(python-mode . python-ts-mode)
              (assq-delete-all 'python-mode major-mode-remap-alist))))

;; Activate the project's .venv before starting the language server
(add-hook 'python-mode-hook #'my-python-auto-activate-venv -90)
(add-hook 'python-ts-mode-hook #'my-python-auto-activate-venv -90)

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `((python-mode python-ts-mode)
                 . ,(eglot-alternatives
                     '(("basedpyright-langserver" "--stdio")
                       ("pyright-langserver" "--stdio")
                       "pylsp")))))

(defun my-python-eglot-ensure ()
  "Start Eglot when BasedPyright's language server is installed."
  (when (or (executable-find "basedpyright-langserver")
            (executable-find "pyright-langserver")
            (executable-find "pyright")
            (executable-find "pylsp"))
    (eglot-ensure)))

(add-hook 'python-mode-hook #'my-python-eglot-ensure)
(add-hook 'python-ts-mode-hook #'my-python-eglot-ensure)

(with-eval-after-load 'apheleia
  (setf (alist-get 'python-mode apheleia-mode-alist) 'ruff
        (alist-get 'python-ts-mode apheleia-mode-alist) 'ruff))


(provide 'init-python)
;;; init-python.el ends here
