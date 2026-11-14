;;; init-python.el --- Python IDE: venv, LSP, pytest, pdb -*- lexical-binding: t; -*-
;;; Commentary:
;; Python layer:
;;   1. Project detection   non-git project markers for project.el
;;   2. Indentation         4-space, no tabs, disable `:' electric indent
;;   3. Virtual envs        uv/python venv creation, selection, activation
;;   4. Tree-sitter mode    python-mode -> python-ts-mode remap
;;   5. LSP                 Eglot with basedpyright/pyrefly/pyright/pylsp
;;   6. Formatting          apheleia + ruff on save
;;   7. Build & project     run/check/pytest/lint/update/add/clean/pydoc
;;   8. Debugging           Emacs GUD + pdb
;;   9. Shared operations   registrations for init-ide.el's keys
;;  10. Keybindings         language-specific "," leader keys under "t"
;;
;; The keys shared with every language layer (build/test/debug/lint/
;; format and the LSP rename/actions/references/reconnect keys) live
;; in init-ide.el; this file registers its implementations with
;; `my-ide-register' and keeps only Python-specific keys here.
;;
;; Language-specific "," + "t" keys (the prefix is shared with
;; init-CIDE.el and init-rust.el; the buffer's mode decides which
;; function fires):
;;   ,tr 运行  ,tc 语法检查  ,tu 更新依赖
;;   ,ta 加依赖  ,td pydoc  ,tx 清理缓存
;;   ,tb 任意项目命令
;;
;; Loaded by `require-init' from init.el before init-ide.el, so the
;; shared registrations wait for init-ide with `with-eval-after-load'.
;;
;; Dependencies (all loaded earlier by init.el or built in):
;; - `my-buffer-file-temp-p' from init-utils.el
;; - `my-ide-register' from init-ide.el (loaded after this file)
;; - `my-comma-leader-def' from init-evil.el (requires evil)
;; - company, apheleia (from init-elpa.el); Eglot is built in
;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)
(require 'cl-lib)

(defconst my-python-modes '(python-mode python-ts-mode)
  "Major modes treated as Python by this configuration.")

(defconst my-python-mode-hooks '(python-mode-hook python-ts-mode-hook)
  "Mode hooks for the two Python major modes.")

;; User-installed tools such as Ruff and basedpyright commonly live in
;; ~/.local/bin, which desktop Emacs may not inherit from the shell.
(defun my-python-add-local-bin-to-path ()
  "Add the user's ~/.local/bin to `exec-path' and PATH when it exists."
  (let* ((directory (expand-file-name "~/.local/bin"))
         (separator (if (characterp path-separator)
                        (char-to-string path-separator)
                      path-separator))
         (path (or (getenv "PATH") "")))
    (when (file-directory-p directory)
      ;; Append so an activated project venv remains ahead of user tools.
      (add-to-list 'exec-path directory t)
      (unless (member directory (split-string path (regexp-quote separator) t))
        (setenv "PATH" (if (string-empty-p path)
                           directory
                         (concat path separator directory)))))))

(my-python-add-local-bin-to-path)
(dolist (hook my-python-mode-hooks)
  ;; Reapply when opening Python after init-essential imports shell PATH.
  (add-hook hook #'my-python-add-local-bin-to-path -100))

;;; Project detection

(defconst my-python-project-markers
  '("pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile")
  "Files that identify a Python project root.")

;; Make project.el recognize Python projects that are not under version
;; control.  `my-python-auto-activate-venv' finds the project's .venv
;; through `project-current', which returns nil in such directories
;; without these markers.
;;
;; The markers are deliberately NOT added to
;; `project-vc-extra-root-markers': Emacs 30's `project-try-vc--search'
;; lets the marker nearest to the buffer win over the version-control
;; root, so a nested `requirements.txt' or `pyproject.toml' would re-root
;; a version-controlled buffer inside its own subdirectory, hiding the
;; repository root and its .venv from `project-current'.  A find function
;; that only fires without a VC backend keeps the original non-VC use
;; case.
(defun my-python-project-try-local (directory)
  "Recognize a Python project by its files when no VC root exists.
Return a transient project rooted at the outermost marker below
DIRECTORY, or nil when DIRECTORY is under version control."
  (unless (ignore-errors (vc-responsible-backend directory))
    (let ((roots (delq nil
                       (mapcar (lambda (marker)
                                 (locate-dominating-file directory marker))
                               my-python-project-markers))))
      (when roots
        (cons 'transient
              (car (sort roots (lambda (left right)
                                 (> (length left) (length right))))))))))

(with-eval-after-load 'project
  (add-hook 'project-find-functions #'my-python-project-try-local t))

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

(defun my-python-style-setup ()
  "Four-space indentation and no tabs in the current Python buffer.
Both python-mode and python-ts-mode default to four spaces already;
set it explicitly, like the C/C++ and Rust layers do."
  (setq-local python-indent-offset 4
              indent-tabs-mode nil))

(dolist (hook my-python-mode-hooks)
  (add-hook hook #'my-python-disable-colon-electric-indent)
  (add-hook hook #'my-python-style-setup))

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

;; Company is the completion UI; `company-capf' presents the language
;; server's completion-at-point results.  `company-dabbrev-code' only
;; kicks in when the server is unavailable, so editing still works
;; without a Python language server.
(defun my-python-company-setup ()
  "Prefer the server's semantic completion in the current Python buffer."
  (setq-local company-backends
              '(company-capf company-dabbrev-code company-files)))

(dolist (hook my-python-mode-hooks)
  (add-hook hook #'my-python-company-setup))

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

;;; Build & project commands

;; Python commands run in compilation buffers in Comint mode (like the
;; C/C++ and Rust layers): errors are clickable and the buffer accepts
;; stdin, so `my-python-run' can drive interactive programs.
(defun my-python-program ()
  "Return the Python interpreter to use for project commands.
Prefer `python3' then `python' through `exec-path', so an activated
venv's interpreter wins; fall back to the name `python3'."
  (or (executable-find "python3")
      (executable-find "python")
      "python3"))

(defun my-python-run (&optional args)
  "Run the current Python script in a compilation (comint) buffer.
With prefix argument ARGS, prompt for extra script arguments."
  (interactive "P")
  (unless (and buffer-file-name
               (string-suffix-p ".py" buffer-file-name t))
    (user-error "Current buffer is not a Python script"))
  (let ((default-directory (or (my-python--project-root) default-directory)))
    (compile (concat (shell-quote-argument (my-python-program))
                     " -B "
                     (shell-quote-argument buffer-file-name)
                     (when args
                       (concat " " (read-string "Script arguments: "))))
             t)))

(defun my-python-check ()
  "Syntax-check every Python file in the project with `compileall'.
The .venv directory is excluded; only files with syntax errors are
reported."
  (interactive)
  (let ((default-directory (or (my-python--project-root) default-directory)))
    (compile (concat (shell-quote-argument (my-python-program))
                     " -m compileall -q -x '\\.venv' .")
             t)))

(defun my-python-lint ()
  "Run `ruff check' on the current project.
This is the Python implementation behind the shared `,nl' lint key
bound by init-ide.el."
  (interactive)
  (unless (executable-find "ruff")
    (user-error "ruff is not installed"))
  (let ((default-directory (or (my-python--project-root) default-directory)))
    (compile "ruff check ." t)))

(defun my-python-format ()
  "Format the current Python buffer with apheleia (ruff).
This is the Python implementation behind the shared `,nf' format key
bound by init-ide.el."
  (interactive)
  (if (fboundp 'apheleia-format-buffer)
      (call-interactively #'apheleia-format-buffer)
    (user-error "apheleia is not available; cannot format the buffer")))

(defun my-python-test (&optional args)
  "Run the project's tests with `python -m pytest'.
With prefix argument ARGS, prompt for extra pytest arguments.
This is the Python implementation behind the shared `,nt' test key
bound by init-ide.el."
  (interactive "P")
  (unless (executable-find "pytest")
    (user-error "pytest is not installed"))
  (let ((default-directory (or (my-python--project-root) default-directory)))
    (compile (concat (shell-quote-argument (my-python-program))
                     " -m pytest"
                     (when args
                       (concat " " (read-string "pytest arguments: "))))
             t)))

(defun my-python-update-deps ()
  "Update the project's dependencies.
Use `uv sync' when the project has a pyproject.toml and uv is
installed, otherwise `python -m pip install -r requirements.txt' or
`python -m pip install -e .'."
  (interactive)
  (let* ((root (or (my-python--project-root) default-directory))
         (pyproject (expand-file-name "pyproject.toml" root))
         (requirements (expand-file-name "requirements.txt" root))
         (default-directory root))
    (cond
     ((and (file-exists-p pyproject) (executable-find "uv"))
      (compile "uv sync" t))
     ((file-exists-p requirements)
      (compile (concat (shell-quote-argument (my-python-program))
                       " -m pip install -r requirements.txt") t))
     ((file-exists-p pyproject)
      (compile (concat (shell-quote-argument (my-python-program))
                       " -m pip install -e .") t))
     (t (user-error "No pyproject.toml or requirements.txt in %s" root)))))

(defun my-python-add-dep (package)
  "Add PACKAGE as a dependency with `uv add' or `python -m pip install'."
  (interactive (list (read-string "Package to add: ")))
  (when (string-empty-p package)
    (user-error "Enter a package name, for example requests"))
  (let* ((root (or (my-python--project-root) default-directory))
         (pyproject (expand-file-name "pyproject.toml" root))
         (default-directory root))
    (compile (concat (if (and (file-exists-p pyproject)
                              (executable-find "uv"))
                         "uv add"
                       (concat (shell-quote-argument (my-python-program))
                               " -m pip install"))
                     " "
                     (shell-quote-argument package))
             t)))

(defun my-python-clean ()
  "Delete __pycache__ directories under the project root.
__pycache__ is Python's build artifact directory; this matches the
build-artifact cleanup of the other language layers (cargo clean)."
  (interactive)
  (let* ((root (or (my-python--project-root) default-directory))
         (count 0))
    (dolist (directory (directory-files-recursively root "__pycache__" t))
      (when (file-directory-p directory)
        (delete-directory directory t)
        (cl-incf count)))
    (message "Deleted %d __pycache__ director%s" count
             (if (= count 1) "y" "ies"))))

(defun my-python-pydoc (symbol)
  "Show SYMBOL's documentation with `python -m pydoc'.
SYMBOL defaults to the symbol at point."
  (interactive
   (list (read-string "pydoc for: " (thing-at-point 'symbol))))
  (when (or (null symbol) (string-empty-p symbol))
    (user-error "Enter a symbol, for example dict"))
  (let ((default-directory (or (my-python--project-root) default-directory)))
    (with-output-to-temp-buffer "*Python pydoc*"
      (unless (eq 0 (call-process (my-python-program) nil standard-output
                                  nil "-m" "pydoc" symbol))
        (princ "pydoc failed\n")))))

(defun my-python-command (command)
  "Run an arbitrary project command in the project root."
  (interactive (list (read-string "Project command: ")))
  (when (string-empty-p command)
    (user-error "Enter a command"))
  (let ((default-directory (or (my-python--project-root) default-directory)))
    (compile command t)))

;;; Debugging: GUD + pdb

(defun my-python-debug (script)
  "Debug Python SCRIPT with `python -m pdb' in Emacs' GUD interface.
The prompt starts in the project root; the current Python script is
the default.  This is the Python implementation behind the shared
`,nd' debug key bound by init-ide.el."
  (interactive
   (let* ((root (or (my-python--project-root) default-directory))
          (default-directory root)
          (current (and buffer-file-name
                        (string-suffix-p ".py" buffer-file-name t)
                        buffer-file-name)))
     (list (expand-file-name
            (read-file-name "Python script: " root nil t current)
            root))))
  (unless (file-exists-p script)
    (user-error "No such script: %s" script))
  (require 'gud)
  (pdb (concat (shell-quote-argument (my-python-program))
               " -m pdb "
               (shell-quote-argument script))))

;;; Shared operations

;; Register the Python implementations behind init-ide.el's shared ","
;; "n" keys: ,nb syntax-check, ,nt test, ,nd debug, ,nl lint, ,nf format.
;; init-ide.el loads after this file, hence `with-eval-after-load'.
(with-eval-after-load 'init-ide
  (my-ide-register 'build my-python-modes #'my-python-check)
  (my-ide-register 'test my-python-modes #'my-python-test)
  (my-ide-register 'debug my-python-modes #'my-python-debug)
  (my-ide-register 'lint my-python-modes #'my-python-lint)
  (my-ide-register 'format my-python-modes #'my-python-format))

;;; Keybindings

;; The language layers share one prefix, "," "t" (left index): these
;; Python keys are bound in the Python mode maps, the C/C++ keys in
;; the C/C++ and CMake mode maps (init-CIDE.el), and the cargo keys in
;; the Rust mode maps (init-rust.el), so the mode decides which
;; function a key fires.
;;
;; The mode scoping keeps this language layer out of unrelated
;; buffers; the global "," keys stay available in Python buffers
;; through keymap fallback.
(defconst my-python-keymaps '(python-mode-map python-ts-mode-map)
  "Mode maps where the Python-specific ',' 't' keys are active.")

;; python.el defines both mode maps; it is built in.
(require 'python)

;; This file loads before init-evil.el, so wait for init-evil (which
;; defines `my-comma-leader-def') rather than for evil itself: evil
;; finishes loading inside init-evil.el, before the definer exists.
(with-eval-after-load 'init-evil
  (my-comma-leader-def
    :keymaps my-python-keymaps
    "tr" #'my-python-run
    "tc" #'my-python-check
    "tu" #'my-python-update-deps
    "ta" #'my-python-add-dep
    "td" #'my-python-pydoc
    "tx" #'my-python-clean
    "tb" #'my-python-command))

(provide 'init-python)
;;; init-python.el ends here
