;;; init-rust.el --- Rust IDE: cargo, rust-analyzer, rustfmt -*- lexical-binding: t; -*-
;;; Commentary:
;; The Rust layer, covering the eight pieces of a beginner-friendly Rust
;; IDE:
;;   1. Completion           company-capf driven by rust-analyzer via Eglot
;;   2. Style / indentation  4-space indent, no tabs (both Rust modes)
;;   3. Navigation           xref definitions/references via Eglot (keys in
;;                           init-evil.el and init-CIDE.el)
;;   4. Project navigation   Cargo.toml roots for project.el and ffip
;;   5. Diagnostics          Eglot + Flymake, clippy lints on every save
;;   6. Formatting           apheleia + rustfmt on save, edition-aware
;;   7. Build                cargo build/run/test/check/clippy/fmt/...
;;   8. Debugging            Emacs GUD + rust-gdb/rust-lldb/GDB/LLDB
;;
;; Loaded by `require-init' from init.el like the other init-* parts;
;; the `t' flag keeps it disabled in light weight mode.
;;
;; rust-mode vs rust-ts-mode: rust-ts-mode (built into Emacs 29+) is the
;; recommended mode.  init-tree-sitter.el installs its grammar and
;; treesit-auto remaps rust-mode to rust-ts-mode once the grammar exists;
;; until then buffers stay in rust-mode (MELPA).  Both modes are
;; configured identically here.
;;
;; Dependencies (all loaded earlier by init.el):
;; - `my-buffer-file-temp-p' from init-utils.el
;; - `my-comma-leader-def' from init-evil.el (requires evil)
;; - `my-rust-langserver-exist' from init-tree-sitter.el
;; - company, flycheck, apheleia (from init-elpa.el); Eglot is built in
;;
;; Section overview:
;;   1. Modes
;;   2. Style / indentation
;;   3. Project detection
;;   4. Completion
;;   5. LSP                   Eglot + rust-analyzer
;;   6. Diagnostics
;;   7. Formatting            apheleia + rustfmt
;;   8. Build                 cargo commands
;;   9. Debugging             Emacs GUD + rust-gdb/rust-lldb/GDB/LLDB
;;  10. Keybindings           "," leader keys under the "R" prefix
;;; Code:

(require 'project)
(require 'subr-x)

;;; Modes

(defconst my-rust-modes '(rust-ts-mode rust-mode)
  "Major modes treated as Rust by this configuration.
The order matches the key newer Emacs versions use for rust-analyzer
in `eglot-server-programs', so `alist-get' with `equal' replaces the
default entry instead of adding a duplicate.")

(defconst my-rust-mode-hooks '(rust-ts-mode-hook rust-mode-hook)
  "Mode hooks matching `my-rust-modes'.")

(defcustom my-rust-debugger 'rust-gdb
  "Debugger used by `my-rust-debug'.
The `rust-gdb' and `rust-lldb' wrappers configure Rust pretty-printers.
The plain `gdb' and `lldb' choices use the system debuggers directly."
  :type '(choice (const :tag "rust-gdb with Rust pretty-printers" rust-gdb)
                 (const :tag "rust-lldb with Rust pretty-printers" rust-lldb)
                 (const :tag "GDB" gdb)
                 (const :tag "LLDB" lldb))
  :group 'tools)

(put 'my-rust-debugger 'safe-local-variable
     (lambda (value) (memq value '(rust-gdb rust-lldb gdb lldb))))

;;; Style / indentation

;; rust-ts-mode and rust-mode both default to four-space indentation;
;; set it explicitly anyway, like the C/C++ layer does.  rustfmt (wired
;; up below) uses four spaces too, and its style rules are the de facto
;; Rust style.
(defun my-rust-style-setup ()
  "Four-space indentation and no tabs in the current Rust buffer."
  (cond
   ((derived-mode-p 'rust-ts-mode)
    (setq-local rust-ts-mode-indent-offset 4
                indent-tabs-mode nil))
   ((derived-mode-p 'rust-mode)
    ;; Align chained method calls the way rustfmt does:
    ;;     foo.bar()
    ;;        .baz()
    (setq-local rust-indent-offset 4
                rust-indent-method-chain t
                indent-tabs-mode nil))))

(defun my-rust-mode-setup ()
  "Rust style setup, skipping temporary buffers."
  (unless (and (fboundp 'my-buffer-file-temp-p)
               (my-buffer-file-temp-p))
    (my-rust-style-setup)))

(dolist (hook my-rust-mode-hooks)
  (add-hook hook #'my-rust-mode-setup))

;;; Project detection

;; Make project.el (and with it Eglot, ffip, and xref) recognize Rust
;; projects that are not under version control.
(with-eval-after-load 'project
  (dolist (marker '("Cargo.toml" "Cargo.lock"))
    (add-to-list 'project-vc-extra-root-markers marker)))

(defun my-rust-project-root ()
  "Return the current Rust project root directory.
Prefer the nearest Cargo.toml.  In a workspace, a member crate has
its own Cargo.toml, so cargo commands run from that member's
directory act on that member only (for example `cargo test' tests
only that crate)."
  (file-name-as-directory
   (or (locate-dominating-file default-directory "Cargo.toml")
       (when-let* ((project (project-current)))
         (project-root project))
       default-directory)))

;;; Completion

;; Company is the completion UI; `company-capf' presents rust-analyzer's
;; completion-at-point results.  `company-dabbrev-code' only kicks in
;; when the language server is unavailable, so editing still works
;; without rust-analyzer.
(defun my-rust-company-setup ()
  "Prefer rust-analyzer's semantic completion in the current Rust buffer."
  (setq-local company-backends
              '(company-capf company-dabbrev-code company-files)))

(dolist (hook my-rust-mode-hooks)
  (add-hook hook #'my-rust-company-setup))

;;; LSP: Eglot + rust-analyzer

(with-eval-after-load 'eglot
  ;; `setf' + `alist-get' with `equal' replaces an entry when one exists
  ;; (newer Emacs versions ship a rust-analyzer entry) and adds it
  ;; otherwise, so this never duplicates.
  ;; `check.command' runs clippy instead of plain `cargo check' on save,
  ;; so every save reports both compiler errors and clippy lints.
  (setf (alist-get my-rust-modes eglot-server-programs nil nil 'equal)
        '("rust-analyzer"
          :initializationOptions (:check (:command "clippy")))))

(defun my-rust-eglot-ensure ()
  "Start Eglot in a Rust buffer, skipping temporary buffers.
Also skipped when rust-analyzer is not installed, so that editing
still works with dabbrev-based completion alone."
  (unless (and (fboundp 'my-buffer-file-temp-p)
               (my-buffer-file-temp-p))
    (when (my-rust-langserver-exist)
      (eglot-ensure))))

(dolist (hook my-rust-mode-hooks)
  (add-hook hook #'my-rust-eglot-ensure))

;; Putting `eglot-completion-at-point' first in
;; `completion-at-point-functions' is done globally by
;; `my-cpp-eglot-capf-first' in init-CIDE.el, and inlay hints
;; (parameter names, deduced types) are enabled for all Eglot buffers
;; there too; toggle them with M-x eglot-inlay-hints-mode.

;;; Diagnostics

;; Eglot reports rust-analyzer diagnostics through Flymake; disable
;; Flycheck in Rust buffers so each diagnostic is not reported twice.
(defun my-rust-disable-flycheck ()
  (when (bound-and-true-p flycheck-mode)
    (flycheck-mode -1)))
(add-hook 'eglot-managed-mode-hook #'my-rust-disable-flycheck)

(with-eval-after-load 'flycheck
  ;; init-CIDE.el turns `flycheck-global-modes' into a `(not ...)'
  ;; blocklist; extend it.  With the default value t, convert it.  Any
  ;; other shape (an allowlist) does not enable Rust modes, so leave it.
  (setq flycheck-global-modes
        (cond
         ((eq flycheck-global-modes t)
          (cons 'not my-rust-modes))
         ((and (listp flycheck-global-modes)
               (eq (car flycheck-global-modes) 'not))
          (cons 'not (append (cdr flycheck-global-modes) my-rust-modes)))
         (t flycheck-global-modes))))

;;; Formatting: apheleia + rustfmt

(defun my-rust-enable-apheleia ()
  "Enable Apheleia formatting in the current Rust buffer."
  ;; apheleia's autoload file inlines `apheleia-mode', but the rest of the
  ;; package (formatters, mode-alist) only exists after `require'.
  (when (and (fboundp 'apheleia-mode)
             (ignore-errors (require 'apheleia)))
    (apheleia-mode 1)))

(dolist (hook my-rust-mode-hooks)
  (add-hook hook #'my-rust-enable-apheleia))

;; apheleia already maps rust-mode and rust-ts-mode to its `rustfmt'
;; formatter, but that formatter feeds the buffer through stdin, where
;; rustfmt defaults to edition 2015 and rejects modern syntax (`async
;; fn', ...).  Pass the edition declared by the project's Cargo.toml.
(defun my-rust-cargo-edition ()
  "Return the Rust edition declared near the current buffer, or nil.
Searches the nearest Cargo.toml first, then parent directories, so
`edition.workspace = true' in a workspace member resolves through the
workspace root."
  (when-let* ((dir (locate-dominating-file default-directory "Cargo.toml")))
    (let ((directory dir)
          edition)
      (while (and directory (not edition))
        (with-temp-buffer
          (insert-file-contents (expand-file-name "Cargo.toml" directory))
          (goto-char (point-min))
          ;; Anchor to a line start so a commented-out `# edition = ...'
          ;; line is not matched, and accept TOML literal single quotes.
          (when (re-search-forward
                 "^edition\\s-*=\\s-*[\"']\\([0-9]+\\)[\"']" nil t)
            (setq edition (match-string 1))))
        (let ((parent (file-name-directory
                       (directory-file-name directory))))
          (setq directory (unless (equal parent directory)
                            (locate-dominating-file
                             parent "Cargo.toml")))))
      edition)))

(with-eval-after-load 'apheleia
  (setf (alist-get 'rustfmt apheleia-formatters)
        '("rustfmt" "--quiet" "--emit" "stdout" "--edition"
          ;; Evaluated in the buffer being formatted; fall back to 2024
          ;; (the edition `cargo new' picks) for files without a project.
          (or (my-rust-cargo-edition) "2024"))))

;;; Build: cargo

;; Cargo commands run in compilation buffers in Comint mode (like the
;; C/C++ layer's `my-cpp-compile-at'): rustc errors are clickable and
;; `next-error' (C-x `) jumps between them, and the buffer accepts
;; stdin, so `cargo run' can drive interactive programs.
(defun my-rust-cargo-compile (directory args)
  "Run `cargo ARGS' asynchronously in DIRECTORY."
  (let ((default-directory (file-name-as-directory directory)))
    (compile (concat "cargo " args) t)))

(defun my-rust-cargo-build (&optional release)
  "Build the current crate with `cargo build'.
With prefix argument RELEASE, pass `--release'."
  (interactive "P")
  (my-rust-cargo-compile
   (my-rust-project-root)
   (concat "build" (when release " --release"))))

(defun my-rust-cargo-run ()
  "Run the current crate with `cargo run'.
The compilation buffer accepts stdin, so programs that read input
work; compiler errors stay clickable."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "run"))

(defun my-rust-cargo-test (&optional nocapture)
  "Run the crate's tests with `cargo test'.
With prefix argument NOCAPTURE, add `-- --nocapture' so `println!'
output in tests is shown."
  (interactive "P")
  (my-rust-cargo-compile
   (my-rust-project-root)
   (concat "test" (when nocapture " -- --nocapture"))))

(defun my-rust-cargo-check ()
  "Type-check only, with `cargo check' (faster than a full build)."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "check"))

(defun my-rust-cargo-clippy ()
  "Run the official linter with `cargo clippy'."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "clippy"))

(defun my-rust-cargo-fmt ()
  "Format the whole crate with `cargo fmt'."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "fmt"))

(defun my-rust-cargo-update ()
  "Update dependencies with `cargo update'."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "update"))

(defun my-rust-cargo-doc ()
  "Build HTML documentation and open it in the browser.
Rustdoc covers the crate, its dependencies, and the standard library."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "doc --open"))

(defun my-rust-cargo-add (crate dev)
  "Add CRATE as a dependency with `cargo add'.
With prefix argument DEV, add it under [dev-dependencies]."
  (interactive
   (list (read-string "Crate to add: ") current-prefix-arg))
  (when (string-empty-p crate)
    (user-error "Enter a crate name, for example serde"))
  (my-rust-cargo-compile
   (my-rust-project-root)
   (concat "add " (shell-quote-argument crate) (when dev " --dev"))))

(defun my-rust-cargo-clean ()
  "Remove build artifacts with `cargo clean'."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "clean"))

(defun my-rust-cargo-command (command)
  "Run an arbitrary cargo subcommand in the project root.
Prompt is prefilled with \"cargo \", so type only the subcommand and
its arguments, for example \"build --release\"."
  (interactive (list (read-string "Cargo command: " "cargo ")))
  (my-rust-cargo-compile
   (my-rust-project-root)
   (string-remove-prefix "cargo " command)))

;;; Debugging: GUD + Rust-aware GDB/LLDB

(defun my-rust-debug (executable)
  "Debug Rust EXECUTABLE with the configured GDB or LLDB frontend.
Build the binary first with `my-rust-cargo-build'.  The file prompt
starts in target/debug/ when that directory exists."
  (interactive
   (let* ((root (my-rust-project-root))
          (target-directory (expand-file-name "target/debug/" root))
          (prompt-directory (if (file-directory-p target-directory)
                                target-directory
                              root)))
     ;; `read-file-name' returns names relative to `default-directory',
     ;; which is restored after this prompt; resolve against the prompt
     ;; directory so a bare name like "hello" still names
     ;; target/debug/hello once the interactive form has returned.
     (list (expand-file-name
            (read-file-name "Rust executable: " prompt-directory nil t)
            prompt-directory))))
  (let* ((root (my-rust-project-root))
         (executable (expand-file-name executable root))
         (debugger (or (executable-find (symbol-name my-rust-debugger))
                       (user-error "%s is not on PATH"
                                   (symbol-name my-rust-debugger))))
         (default-directory root))
    (unless (file-executable-p executable)
      (user-error "Not an executable file: %s. Build the project first"
                  executable))
    (require 'gud)
    (pcase my-rust-debugger
      ((or 'rust-gdb 'gdb)
       (gdb (format "%s -i=mi --args %s"
                    (shell-quote-argument debugger)
                    (shell-quote-argument executable))))
      ((or 'rust-lldb 'lldb)
       (lldb (format "%s %s"
                     (shell-quote-argument debugger)
                     (shell-quote-argument executable)))))))

;;; Keybindings

;; `,rb' and `,rr' are already taken globally (evilmr-replace-in-buffer,
;; my-recentf), so the cargo commands live under the free "R" prefix.
(with-eval-after-load 'evil
  (my-comma-leader-def
    "Rb" #'my-rust-cargo-build
    "Rr" #'my-rust-cargo-run
    "Rt" #'my-rust-cargo-test
    "Rc" #'my-rust-cargo-check
    "Rl" #'my-rust-cargo-clippy
    "Rf" #'my-rust-cargo-fmt
    "Ru" #'my-rust-cargo-update
    "Ra" #'my-rust-cargo-add
    "Rd" #'my-rust-cargo-doc
    "RC" #'my-rust-cargo-clean
    "RB" #'my-rust-cargo-command
    "Rg" #'my-rust-debug))

;;; Existing buffers

(defun my-rust-configure-existing-buffers ()
  "Apply Rust setup to buffers that already exist when this file loads."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and buffer-file-name
                 (apply #'derived-mode-p my-rust-modes))
        (my-rust-company-setup)
        (when (fboundp 'apheleia-mode)
          (apheleia-mode 1))
        (my-rust-eglot-ensure)))))

(my-rust-configure-existing-buffers)

(provide 'init-rust)
;;; init-rust.el ends here
