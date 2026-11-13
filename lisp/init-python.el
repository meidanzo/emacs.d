;;; init-python.el --- Python editing, venv, LSP, formatting -*- lexical-binding: t; -*-
;;; Commentary:
;; Python layer:
;;   1. Project detection   non-git project markers for project.el
;;   2. Indentation         disable `:' electric indent
;;   3. Virtual envs        uv/python venv creation, selection, activation
;;   4. Tree-sitter mode    python-mode -> python-ts-mode remap
;;   5. LSP                 Eglot with basedpyright/pyrefly/pyright/pylsp
;;   6. Formatting          apheleia + ruff
;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)

(defconst my-python-mode-hooks '(python-mode-hook python-ts-mode-hook)
  "Mode hooks for the two Python major modes.")

;;; Project detection

;; Make project.el recognize Python projects that are not under version
;; control.  `my-python-auto-activate-venv' finds the project's .venv
;; through `project-current', which returns nil in such directories
;; without these markers.
(with-eval-after-load 'project
  (dolist (marker '("pyproject.toml" "setup.py" "setup.cfg"
                    "requirements.txt" "Pipfile"))
    (add-to-list 'project-vc-extra-root-markers marker)))

;;; Indentation

;; `python-mode' adds `:' to `electric-indent-chars' buffer-locally, so a
;; global `setq' cannot remove it.  Do it in a hook instead.
(defun my-python-disable-colon-electric-indent ()
  "Remove `:' from `electric-indent-chars' in this Python buffer."
  (unless (or (and (fboundp 'my-buffer-file-temp-p)
                   (my-buffer-file-temp-p))
              (not buffer-file-name)
              ;; embed python code in org file
              (string= (file-name-extension buffer-file-name) "org"))
    (setq-local electric-indent-chars (delq ?: electric-indent-chars))))

(dolist (hook my-python-mode-hooks)
  (add-hook hook #'my-python-disable-colon-electric-indent))

;;; Virtual environments

;; `pyvenv' activates environments inside Emacs.  Creation prefers `uv'
;; (https://docs.astral.sh/uv/) and falls back to Python's built-in
;; `venv' module.  The third-party `virtualenv' package is not required.
(defvar my-python-venv-directories
  (list (expand-file-name "~/.venv"))
  "Virtual environment directories offered for selection.")

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

(defun my-python--venv-p (directory)
  "Return non-nil when DIRECTORY is a Python virtual environment."
  (and (stringp directory)
       (file-directory-p directory)
       (file-exists-p (expand-file-name "pyvenv.cfg" directory))
       (or (file-exists-p (expand-file-name "bin/python" directory))
           (file-exists-p (expand-file-name "bin/python3" directory))
           (file-exists-p (expand-file-name "Scripts/python.exe" directory)))))

(defun my-python--project-venv ()
  "Return the current project's valid .venv directory, or nil."
  (when-let* ((root (my-python--project-root)))
    (let ((venv (expand-file-name ".venv" root)))
      (and (my-python--venv-p venv) venv))))

(defun my-python--default-venv-directory ()
  "Return the default directory for a new virtual environment."
  (if-let* ((root (my-python--project-root)))
      (expand-file-name ".venv" root)
    (expand-file-name "~/.venv")))

(defun my-python--venv-candidates ()
  "Return the existing valid Python virtual environment directories."
  (delete-dups
   (seq-filter #'my-python--venv-p
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
  (unless (stringp directory)
    (user-error "No Python venv directory specified"))
  (setq directory (expand-file-name directory))
  (if (my-python--venv-p directory)
      (progn
        (pyvenv-activate directory)
        (message "Activated Python venv: %s" directory))
    (user-error "Python venv does not exist or is not a virtual environment: %s" directory)))

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
    (when (and (file-directory-p directory)
               (not (my-python--venv-p directory))
               (directory-files directory nil "\\`[^.]"))
      (user-error "Directory exists but is not a virtual environment: %s" directory))
    (unless (my-python--venv-p directory)
      (unless program
        (user-error "Neither uv nor python3 is available"))
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
       ((my-python--venv-p (expand-file-name directory))
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

;;; Tree-sitter mode

;; Prepend instead of `setq': replacing the whole alist would discard
;; remappings added by other packages or by the user.
(when (and (fboundp 'treesit-available-p)
           (treesit-available-p)
           (treesit-language-available-p 'python))
  (setq major-mode-remap-alist
        (cons '(python-mode . python-ts-mode)
              (assq-delete-all 'python-mode major-mode-remap-alist))))

;;; LSP

;; Activate the project's .venv before starting the language server; the
;; -90 depth keeps it ahead of `my-python-eglot-ensure'.
(dolist (hook my-python-mode-hooks)
  (add-hook hook #'my-python-auto-activate-venv -90))

(with-eval-after-load 'eglot
  ;; Replace Emacs' own `(python-mode python-ts-mode)' entry instead of
  ;; `add-to-list', which would add a second key with the modes in a
  ;; different order and leave the choice up to alist order.  `equal' is
  ;; required because `alist-get' compares with `eq' by default and can
  ;; never match a quoted literal list.
  (setf (alist-get '(python-mode python-ts-mode)
                   eglot-server-programs nil nil 'equal)
        (eglot-alternatives
         '(("basedpyright-langserver" "--stdio")
           ("pyrefly" "lsp")
           ("pyright-langserver" "--stdio")
           "pylsp"))))

(defun my-python-eglot-ensure ()
  "Start Eglot when a Python language server is installed."
  (when (my-python-langserver-exist)
    (eglot-ensure)))

(dolist (hook my-python-mode-hooks)
  (add-hook hook #'my-python-eglot-ensure))

;;; Formatting

(defun my-python-enable-apheleia ()
  "Enable Apheleia formatting in the current Python buffer."
  ;; apheleia's autoload file inlines `apheleia-mode', but the rest of the
  ;; package (formatters, mode-alist) only exists after `require'.
  (when (and (fboundp 'apheleia-mode)
             (ignore-errors (require 'apheleia)))
    (apheleia-mode 1)))

(dolist (hook my-python-mode-hooks)
  (add-hook hook #'my-python-enable-apheleia))

(with-eval-after-load 'apheleia
  (setf (alist-get 'python-mode apheleia-mode-alist) 'ruff
        (alist-get 'python-ts-mode apheleia-mode-alist) 'ruff))

(provide 'init-python)
;;; init-python.el ends here
