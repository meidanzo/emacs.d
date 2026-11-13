;;; init-tree-sitter.el --- tree-sitter grammars, auto-install, ts modes -*- lexical-binding: t; -*-
;;; Commentary:
;; Three jobs, in one place:
;;   1. Tell Emacs where grammar shared libraries live.
;;   2. Maintain grammar recipes and auto-install missing ones at startup
;;      (interactive sessions only; C/C++ and Python grammars require
;;      their matching language server, while CMake grammar is independent).
;;   3. Switch c/c++/python buffers to their tree-sitter modes via
;;      treesit-auto when the grammars are available.
;;; Code:

(require 'treesit)

;; Grammar shared libraries (.so) are installed into this directory.
(add-to-list 'treesit-extra-load-path "~/.emacs.d/tree-sitter")

;;; Language spec table.
;; Each entry: (LANG URL ABI14-REVISION GUARD)
;;   URL            grammar repository (grammar.js + generated parser.c)
;;   ABI14-REVISION tag compatible with tree-sitter ABI < 15; newer
;;                  runtimes use "master" instead
;;   GUARD          function deciding whether auto-install is allowed
;;                  (only install when a matching language server exists)
(defvar my-treesit-language-specs
  `((c      "https://github.com/tree-sitter/tree-sitter-c"      "v0.23.6" my-cpp-langserver-exist)
    (cpp    "https://github.com/tree-sitter/tree-sitter-cpp"    "v0.23.4" my-cpp-langserver-exist)
    ;; tree-sitter-cmake's master branch still vendors an old parser.h, so
    ;; it compiles against both ABI 14 and newer runtimes.
    (cmake  "https://github.com/uyha/tree-sitter-cmake"         "master"  my-cmake-langserver-exist)
    (python "https://github.com/tree-sitter/tree-sitter-python" "v0.23.6" my-python-langserver-exist))
  "Grammar specs for the languages this configuration uses.
See `my-treesit-auto-install-grammars'.")

(defun my-treesit-grammar-revision (abi14 latest)
  "Return the grammar revision compatible with the tree-sitter runtime.
Use LATEST when the runtime supports ABI 15, ABI14 otherwise.
`treesit-library-abi-version' was added after Emacs 29, whose bundled
runtime is ABI 14, so a missing function means ABI 14, not LATEST:
grammar revisions on master require ABI 15 and would fail to load."
  (if (and (fboundp 'treesit-library-abi-version)
           (>= (treesit-library-abi-version) 15))
      latest
    abi14))

(defun my-treesit-register-recipes ()
  "Fill `treesit-language-source-alist' from `my-treesit-language-specs'.
Emacs 30.1 ships this alist empty, so `treesit-install-language-grammar'
cannot work until these recipes are registered."
  (dolist (spec my-treesit-language-specs)
    (setf (alist-get (nth 0 spec) treesit-language-source-alist)
          (list (nth 1 spec)
                (my-treesit-grammar-revision (nth 2 spec) "master")))))

;;; Language server guards.
(defun my-cpp-langserver-exist ()
  "Return an installed C/C++ language server executable, or nil."
  (executable-find "clangd"))

(defun my-python-langserver-exist ()
  "Return an installed Python language server executable, or nil.
Also used by `my-python-eglot-ensure' in init-python.el."
  (or (executable-find "basedpyright-langserver")
      (executable-find "pyrefly")
      (executable-find "pyright-langserver")
      (executable-find "pylsp")))

(defun my-cmake-langserver-exist ()
  "Return an installed CMake language server executable, or nil."
  (or (executable-find "neocmakelsp")
      (executable-find "cmake-language-server")))

;;; Grammar installation.
(defcustom my-treesit-auto-install-grammars t
  "Whether to auto-install missing grammars at interactive startup.
Installation requires Git and a C compiler.  Each grammar is only
installed when its GUARD in `my-treesit-language-specs' succeeds."
  :type 'boolean
  :group 'tools)

(defun my-treesit-grammar-available-p (lang)
  "Return non-nil when LANG's grammar can be loaded."
  (and (fboundp 'treesit-available-p)
       (treesit-available-p)
       (fboundp 'treesit-language-available-p)
       (treesit-language-available-p lang)))

(defun my-treesit-ensure-grammar (lang)
  "Install LANG's grammar from `my-treesit-language-specs' when missing."
  (unless (my-treesit-grammar-available-p lang)
    (condition-case err
        (progn
          (treesit-install-language-grammar lang)
          (unless (my-treesit-grammar-available-p lang)
            (message "%s tree-sitter grammar still unavailable after install."
                     lang)))
      (error (message "%s tree-sitter grammar install failed: %s"
                      lang err)))))

(defun my-treesit-ensure-grammars ()
  "Install missing grammars whose language-server guard succeeds.
Interactive counterpart of the startup auto-install."
  (interactive)
  (if (not (and (fboundp 'treesit-available-p) (treesit-available-p)))
      (message "This Emacs build has no tree-sitter support.")
    (dolist (spec my-treesit-language-specs)
      (when (funcall (nth 3 spec))
        (my-treesit-ensure-grammar (nth 0 spec))))))

(my-treesit-register-recipes)

;; Startup auto-install: interactive sessions only.  The per-language
;; availability check in `my-treesit-ensure-grammar' keeps this idempotent,
;; so a missing cmake grammar is installed even when c and cpp are present.
(when (and (not noninteractive)
           (fboundp 'treesit-available-p)
           (treesit-available-p)
           my-treesit-auto-install-grammars)
  (my-treesit-ensure-grammars))

;;; Tree-sitter modes via treesit-auto.
;; `treesit-auto-langs' defaults to all known recipes, so any grammar that
;; appears on disk gets its ts mode automatically; `treesit-auto-install'
;; stays nil so opening a file never triggers a download.
(when (require 'treesit-auto nil t)
  (setq treesit-auto-install nil)
  (global-treesit-auto-mode 1))

(provide 'init-tree-sitter)
;;; init-tree-sitter.el ends here
