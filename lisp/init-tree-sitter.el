;;; init-tree-sitter.el --- tree-sitter grammars, auto-install, ts modes -*- lexical-binding: t; -*-
;; Copyright (C) 2026 meidanzo <meidanzo@foxmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Three jobs, in one place:
;;   1. Tell Emacs where grammar shared libraries live.
;;   2. Maintain grammar recipes and auto-install missing ones once Emacs
;;      has started and gone idle (interactive sessions only; C/C++,
;;      Python, and Rust grammars require their matching language server,
;;      while the CMake grammar is independent).  Building a grammar
;;      clones a repository and compiles C, so it runs in a background
;;      Emacs process and never freezes the session.
;;   3. Switch c/c++/python/rust buffers to their tree-sitter modes via
;;      treesit-auto when the grammars are available.
;;
;; The `my-*-langserver-exist' guards live here because the grammar
;; guards use them; the language layers call them too.
;;; Code:

(require 'treesit)
(require 'seq)

(defcustom my-treesit-grammar-directory
  (expand-file-name "tree-sitter" user-emacs-directory)
  "Directory grammar shared libraries are installed into and loaded from.
This is also where `treesit-install-language-grammar' installs by default
and where Emacs always looks, so grammars installed by hand land here too."
  :type 'directory
  :group 'tools)

;; Grammar shared libraries (.so) are installed into this directory.  It
;; follows `user-emacs-directory' instead of a hard-coded ~/.emacs.d, so
;; the load path and the install target cannot drift apart.
(add-to-list 'treesit-extra-load-path my-treesit-grammar-directory)

;; The directory this file used to hard-code: keep searching it while it
;; still holds libraries, in case `user-emacs-directory' is elsewhere.
(let ((legacy (expand-file-name "~/.emacs.d/tree-sitter")))
  (when (and (file-directory-p legacy)
             (not (file-equal-p legacy my-treesit-grammar-directory)))
    (add-to-list 'treesit-extra-load-path legacy)))

;;; Language spec table.
;; Each entry: (LANG URL ABI14-REVISION GUARD)
;;   URL            grammar repository (grammar.js + generated parser.c)
;;   ABI14-REVISION tag compatible with tree-sitter ABI < 15; newer
;;                  runtimes use "master" instead
;;   GUARD          function deciding whether auto-install is allowed
;;                  (only install when a matching language server exists);
;;                  nil allows the install unconditionally
(defvar my-treesit-language-specs
  '((c      "https://github.com/tree-sitter/tree-sitter-c"      "v0.23.6" my-cpp-langserver-exist)
    (cpp    "https://github.com/tree-sitter/tree-sitter-cpp"    "v0.23.4" my-cpp-langserver-exist)
    ;; tree-sitter-cmake's master branch still vendors an old parser.h, so
    ;; it compiles against both ABI 14 and newer runtimes.
    (cmake  "https://github.com/uyha/tree-sitter-cmake"         "master"  my-cmake-langserver-exist)
    (python "https://github.com/tree-sitter/tree-sitter-python" "v0.23.6" my-python-langserver-exist)
    (rust   "https://github.com/tree-sitter/tree-sitter-rust"   "v0.23.2" my-rust-langserver-exist))
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
  "Return an installed C/C++ language server executable, or nil.
Looks for the program init-CIDE.el starts (`my-cpp-clangd-program'), so
the grammar guard and the Eglot hook always agree."
  (executable-find (if (boundp 'my-cpp-clangd-program)
                       my-cpp-clangd-program
                     "clangd")))

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

(defun my-rust-langserver-exist ()
  "Return an installed Rust language server executable, or nil.
Also used by `my-rust-eglot-ensure' in init-rust.el."
  (executable-find "rust-analyzer"))

;;; Grammar installation.
(defcustom my-treesit-auto-install-grammars t
  "Whether to auto-install missing grammars once Emacs has started.
Installation requires Git and a C compiler.  Each grammar is only
installed when its GUARD in `my-treesit-language-specs' succeeds."
  :type 'boolean
  :group 'tools)

(defcustom my-treesit-install-asynchronously t
  "Whether grammars are built in a background Emacs process.
Installing a grammar clones its repository and compiles C code, which
takes from seconds to a minute each.  In the foreground that freezes
Emacs; in the background Emacs stays usable, and the grammar takes effect
once the process has finished.  Nil installs in the foreground."
  :type 'boolean
  :group 'tools)

(defvar my-treesit--install-process nil
  "The running background grammar installation, or nil.")

(defun my-treesit-grammar-available-p (lang)
  "Return non-nil when LANG's grammar can be loaded."
  (and (fboundp 'treesit-available-p)
       (treesit-available-p)
       (fboundp 'treesit-language-available-p)
       (treesit-language-available-p lang)))

(defun my-treesit-ensure-grammar (lang &optional force)
  "Install LANG's grammar from `my-treesit-language-specs' when missing.
With FORCE, install it even when a library is already present.  This runs
in the foreground and returns when the build is done; the background path
is `my-treesit-ensure-grammars'."
  (when (or force (not (my-treesit-grammar-available-p lang)))
    (condition-case err
        (progn
          (treesit-install-language-grammar lang my-treesit-grammar-directory)
          (unless (my-treesit-grammar-available-p lang)
            (message "%s tree-sitter grammar still unavailable after install."
                     lang)))
      (error (message "%s tree-sitter grammar install failed: %s"
                      lang (error-message-string err))))))

(defun my-treesit--languages-to-install (&optional force)
  "Return the languages whose guard succeeds and whose grammar is missing.
With FORCE, every language whose guard succeeds, installed or not."
  (let (languages)
    (dolist (spec my-treesit-language-specs)
      (let ((language (nth 0 spec))
            (guard (nth 3 spec)))
        (when (and (or (null guard)
                       (and (fboundp guard) (funcall guard)))
                   (or force (not (my-treesit-grammar-available-p language))))
          (push language languages))))
    (nreverse languages)))

(defun my-treesit--install-form (languages)
  "Return the form a background Emacs evaluates to install LANGUAGES.
The process exits 0 when no error escapes the form.  Do not use the exit
status to decide success: `treesit-install-language-grammar' reports most
failures as warnings instead of signalling them (Emacs 29 and later), so
a failed build usually still exits 0.  `my-treesit--install-finished'
checks whether each grammar actually loads afterwards."
  `(progn
     ;; Load treesit before touching its variables, so they are bound
     ;; dynamically.
     (require 'treesit)
     (setq treesit-language-source-alist ',treesit-language-source-alist)
     (let ((failed nil))
       (dolist (language ',languages)
         (condition-case err
             (treesit-install-language-grammar language
                                               ,my-treesit-grammar-directory)
           (error (push language failed)
                  (message "my-treesit: %s failed: %s"
                           language (error-message-string err)))))
       (kill-emacs (if failed 1 0)))))

(defun my-treesit--refresh-modes ()
  "Let treesit-auto notice grammars installed after it was enabled.
Buffers that are already open switch modes on their next `normal-mode'."
  (when (fboundp 'treesit-auto-add-to-auto-mode-alist)
    (ignore-errors (treesit-auto-add-to-auto-mode-alist))))

(defvar my-treesit-grammars-ready-hook nil
  "Hook run after a grammar installation has made grammars available.
The language layers use it to load built-in tree-sitter mode files that
they deliberately keep unloaded while the matching grammar is missing:
files like `c-ts-mode.el' and `cmake-ts-mode.el' emit a warning when
they load without their grammar.  Loading them only after the grammar
exists keeps a fresh first session warning-free.")

(defun my-treesit--install-finished (process languages)
  "Report the result of the background installation PROCESS of LANGUAGES."
  (when (memq (process-status process) '(exit signal))
    (setq my-treesit--install-process nil)
    (let ((missing (seq-remove #'my-treesit-grammar-available-p languages)))
      (if missing
          (message "tree-sitter grammars still unavailable: %s (see buffer *treesit install*)"
                   (mapconcat #'symbol-name missing ", "))
        (message "tree-sitter grammars installed: %s"
                 (mapconcat #'symbol-name languages ", ")))
      (unless (equal missing languages)
        (my-treesit--refresh-modes)
        (run-hooks 'my-treesit-grammars-ready-hook)))))

(defun my-treesit--install-in-background (languages)
  "Install LANGUAGES in a background Emacs process."
  (let ((buffer (get-buffer-create "*treesit install*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "Installing tree-sitter grammars in the background: %s"
             (mapconcat #'symbol-name languages ", "))
    (setq my-treesit--install-process
          (make-process
           :name "treesit-install"
           :buffer buffer
           :command (list (expand-file-name invocation-name invocation-directory)
                          "-Q" "--batch"
                          "--eval" (prin1-to-string
                                    (my-treesit--install-form languages)))
           :noquery t
           :sentinel (lambda (process _event)
                       (my-treesit--install-finished process languages))))))

(defun my-treesit-ensure-grammars (&optional force)
  "Install missing grammars whose language-server guard succeeds.
Interactive counterpart of the startup auto-install.  With prefix argument
FORCE, rebuild every grammar whose guard succeeds, for example after
changing a revision in `my-treesit-language-specs' or upgrading Emacs.
See `my-treesit-install-asynchronously' for where the build runs."
  (interactive "P")
  (cond
   ((not (and (fboundp 'treesit-available-p) (treesit-available-p)))
    (message "This Emacs build has no tree-sitter support."))
   ((and my-treesit--install-process
         (process-live-p my-treesit--install-process))
    (message "A tree-sitter grammar installation is already running."))
   (t
    (let ((languages (my-treesit--languages-to-install force)))
      (cond
       ((null languages)
        (when (called-interactively-p 'interactive)
          (message "No tree-sitter grammar to install.")))
       (my-treesit-install-asynchronously
        (my-treesit--install-in-background languages))
       (t
        (dolist (language languages)
          (my-treesit-ensure-grammar language force))
        (run-hooks 'my-treesit-grammars-ready-hook)))))))

(defun my-treesit-auto-install ()
  "Install missing grammars when `my-treesit-auto-install-grammars' is set."
  (when (and my-treesit-auto-install-grammars
             (not noninteractive))
    (my-treesit-ensure-grammars)))

(defun my-treesit-schedule-auto-install ()
  "Run `my-treesit-auto-install' once Emacs has been idle for a moment.
Goes through `my-run-with-idle-timer' (init-utils.el), which runs the
function immediately when `my-disable-idle-timer' is set, that is when
Emacs starts as a daemon or in batch runs: a daemon has no idle moment
before a frame connects, and in batch sessions `my-treesit-auto-install'
does nothing anyway.  Falls back to a plain idle timer when init-utils
is not loaded."
  (if (fboundp 'my-run-with-idle-timer)
      (my-run-with-idle-timer 1 #'my-treesit-auto-install)
    (run-with-idle-timer 1 nil #'my-treesit-auto-install)))

(my-treesit-register-recipes)

;; Startup auto-install: interactive sessions only.  The per-language
;; availability check keeps this idempotent, so a missing cmake grammar is
;; installed even when c and cpp are present.  It waits until init has
;; finished: the language-server guards need the final `exec-path' (other
;; layers add ~/.local/bin and friends).  In an interactive session
;; `my-treesit-schedule-auto-install' also waits for an idle moment, so
;; nothing here delays the first window; a daemon starts the background
;; install right away.
(if after-init-time
    (my-treesit-schedule-auto-install)
  (add-hook 'emacs-startup-hook #'my-treesit-schedule-auto-install))

;;; Tree-sitter modes via treesit-auto.
;; `treesit-auto-langs' defaults to all known recipes, so any grammar that
;; appears on disk gets its ts mode automatically; `treesit-auto-install'
;; stays nil so opening a file never triggers a download.
(when (require 'treesit-auto nil t)
  (setq treesit-auto-install nil)
  (global-treesit-auto-mode 1))

(provide 'init-tree-sitter)
;;; init-tree-sitter.el ends here
