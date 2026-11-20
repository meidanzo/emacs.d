;;; init-rust.el --- Rust IDE: cargo, rust-analyzer, rustfmt -*- lexical-binding: t; -*-
;; Copyright (C) 2026 meidanzo <meidanzo@foxmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The Rust layer, covering the eight pieces of a beginner-friendly Rust
;; IDE:
;;   1. Completion           company-capf driven by rust-analyzer via Eglot
;;   2. Style / indentation  4-space indent, no tabs (both Rust modes)
;;   3. Navigation           xref definitions/references via Eglot (keys in
;;                           init-evil.el and init-ide.el)
;;   4. Project navigation   Cargo.toml roots for project.el and ffip
;;   5. Diagnostics          Eglot + Flymake, clippy lints on every save
;;   6. Formatting           apheleia + rustfmt on save, edition-aware
;;   7. Build                cargo build/run/test/check/clippy/fmt/...
;;   8. Debugging            Emacs GUD + rust-gdb/rust-lldb/GDB/LLDB
;;
;; The keys shared with every language layer (build/test/debug/lint/
;; format and the LSP rename/actions/references/reconnect keys) live
;; in init-ide.el; this file registers its implementations with
;; `my-ide-register' and keeps only cargo-specific keys here.
;;
;; Cargo-specific "," + "t" keys (the prefix is shared with
;; init-CIDE.el; the buffer's mode decides which function fires):
;;   ,tr 运行  ,tc 检查  ,tu 更新依赖
;;   ,ta 加依赖  ,td 文档  ,tx 清理  ,tb 任意cargo命令
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
;; - `my-ide-register', `my-ide-register-company-backends',
;;   `my-ide-flycheck-exclude' and the Apheleia idle-auto-save advice
;;   (`my-apheleia-skip-auto-save') from init-ide.el
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
;;  10. Shared operations     registrations for init-ide.el's keys
;;  11. Keybindings           cargo-specific "," leader keys under "t"
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

(defcustom my-rust-analyzer-options
  '(:check (:command "clippy")
    :cargo (:targetDir t))
  "Options sent to rust-analyzer as Eglot's :initializationOptions.
A plist in rust-analyzer's own (nested) configuration layout.

`:check (:command \"clippy\")' runs clippy instead of plain `cargo check'
on save, so every save reports both compiler errors and clippy lints.

`:cargo (:targetDir t)' makes rust-analyzer build into its own
target/rust-analyzer directory.  Without it, the check that runs on every
save holds cargo's lock on target/, so a `cargo run' or `cargo test'
started from Emacs (which itself saves the buffers first) waits for it.
The price is some duplicated build output; remove the entry to share
target/ again.

The value is read each time a server starts, so it can be set per project
in .dir-locals.el, for example to pass `:cargo (:features \"all\")' or a
cross-compilation `:cargo (:target \"thumbv7em-none-eabihf\")'."
  :type 'sexp
  :group 'tools)

(defcustom my-rust-eglot-skip-regexp
  "/\\.cargo/\\(?:registry\\|git\\)/\\|/\\.rustup/"
  "Rust files whose name matches this never start an Eglot server of their own.
Downloaded crate sources and the toolchain's sources are Cargo projects,
so opening one would start another rust-analyzer for every crate visited,
for instance via go-to-definition.  They are served by the server of the
project you came from instead (`eglot-extend-to-xref', set in
init-ide.el).  Nil disables the check."
  :type '(choice (const :tag "Never skip" nil) regexp)
  :group 'tools)

(defcustom my-rust-cargo-markers-override-vc t
  "Non-nil: a Cargo.toml nearer than the VC root defines the project root.
This registers Cargo.toml and Cargo.lock in `project-vc-extra-root-markers'.
It also makes every member crate of a Cargo workspace a project of its own,
because the nearest marker wins over the VC root, and Eglot starts one
rust-analyzer per project, so a large workspace costs one server per
member crate you visit.

Nil: Cargo.toml only matters in directories without a VC root, where
`my-rust-project-try-local' picks the workspace root.  A workspace in a
repository is then one project with one server.  rust-analyzer finds
manifests in the project root, its parents and its direct subdirectories,
so a crate nested deeper than that is not found by itself.

Set this before init-rust.el loads (for example with `setq' in init.el);
it is read once, when `project' loads."
  :type 'boolean
  :group 'tools)

(defcustom my-rust-cargo-jobs 4
  "Maximum jobs for cargo processes started from Emacs, or nil.
The value is exported as the CARGO_BUILD_JOBS environment variable, which
cargo honors for every build (build, check, clippy, test, install) and
which rust-analyzer's check-on-save and shells started from Emacs
inherit.  With 4, a cold release build of a workspace the size of yazi
peaked at ~3.4 GiB on this machine (measured); cargo's default (one job
per CPU core) can stack several multi-GiB rustc processes at once.  The
cap limits build jobs only: `cargo test' still runs test binaries with
cargo's usual per-core parallelism.  An explicit `cargo build -j N'
overrides it for that one command.

nil keeps cargo's default.  The variable is exported when this file
loads; after changing it, re-evaluate it (or restart), and reconnect
Eglot so a running rust-analyzer inherits the new value.  Cargo run
outside Emacs (for example from a terminal) does not see this setting;
for a machine-wide cap use `[build] jobs' in ~/.cargo/config.toml."
  :type '(choice (const :tag "cargo default (one job per CPU core)" nil)
                 (integer :tag "Explicit job count"))
  :group 'tools)

(when my-rust-cargo-jobs
  (setenv "CARGO_BUILD_JOBS" (number-to-string my-rust-cargo-jobs)))

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

;; Rust-aware operator prettification (->, =>, &&, ...).  Both Rust
;; modes already set their own `prettify-symbols-alist' (rust-ts-mode
;; and rust-mode via rust-prog-mode, with the same entries and a
;; compose predicate that tells `&&' the double reference from the
;; logical and), so just turn the minor mode on.
(defun my-rust-prettify ()
  "Show Rust operators as Unicode symbols (->, =>, &&, ...)."
  (prettify-symbols-mode 1))
(dolist (hook my-rust-mode-hooks)
  (add-hook hook #'my-rust-prettify))

;;; Project detection

;; Make project.el (and with it Eglot, ffip, and xref) recognize Rust
;; projects that are not under version control.  See
;; `my-rust-cargo-markers-override-vc' for the two ways of doing it.

;; Manifest helpers.  Paths are expanded first: `locate-dominating-file'
;; abbreviates $HOME to ~, and `file-name-directory' of "~" is nil, which
;; would break the climb for a Cargo.toml in the home directory.
(defun my-rust--parent-manifest-directory (directory)
  "Return the nearest ancestor of DIRECTORY holding a Cargo.toml, or nil.
DIRECTORY itself is not considered."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (parent (file-name-directory (directory-file-name directory))))
    (when (and parent (not (equal parent directory)))
      (when-let* ((found (locate-dominating-file parent "Cargo.toml")))
        (expand-file-name found)))))

(defun my-rust--manifest-declares-workspace-p (directory)
  "Return non-nil when DIRECTORY's Cargo.toml has a [workspace] table."
  (let ((file (expand-file-name "Cargo.toml" directory)))
    (and (file-readable-p file)
         (with-temp-buffer
           (insert-file-contents file)
           (re-search-forward "^\\[workspace[].]" nil t)))))

(defun my-rust-workspace-root (directory)
  "Return the Cargo project root for DIRECTORY, or nil outside any crate.
That is the outermost ancestor whose Cargo.toml declares a [workspace];
without one, the directory of the nearest Cargo.toml."
  (let* ((nearest (when-let* ((found (locate-dominating-file
                                      directory "Cargo.toml")))
                    (expand-file-name found)))
         (current nearest)
         workspace)
    (while current
      (when (my-rust--manifest-declares-workspace-p current)
        (setq workspace current))
      (setq current (my-rust--parent-manifest-directory current)))
    (or workspace nearest)))

(defun my-rust-project-try-local (directory)
  "Recognize a Cargo project in DIRECTORY when no VC root exists.
Return a transient project rooted at the Cargo workspace root, or nil when
DIRECTORY is under version control, on a remote host, or outside a crate.
Remote directories are skipped because this runs on every
`project-current' call."
  (unless (or (file-remote-p directory)
              (ignore-errors (vc-responsible-backend directory)))
    (when-let* ((root (my-rust-workspace-root directory)))
      (cons 'transient root))))

(with-eval-after-load 'project
  (if my-rust-cargo-markers-override-vc
      (dolist (marker '("Cargo.toml" "Cargo.lock"))
        (add-to-list 'project-vc-extra-root-markers marker))
    ;; Move it before the built-in `project-try-vc': when its ancestor
    ;; walk signals (an unreadable parent directory, say) Emacs 30
    ;; aborts the whole `project-find-functions' chain and every find
    ;; function after it would never run.  This function self-skips
    ;; version-controlled directories, so the VC root still wins there.
    ;; Inserting just before `project-try-vc' keeps the load-order of
    ;; the three language find functions (python, C/C++, Rust), so
    ;; overlapping markers keep their old winner.
    ;; A plain `setq', not `add-hook': its third argument has meant
    ;; DEPTH since Emacs 28, and the legacy APPEND value t would
    ;; reorder the list against add-hook's depth bookkeeping.
    (let* ((functions project-find-functions)
           (rest (memq 'project-try-vc functions))
           (head (if rest (take (- (length functions) (length rest))
                                functions)
                   functions)))
      ;; A config reload re-runs this block; a previous run already put
      ;; the function in place.
      (unless (memq 'my-rust-project-try-local head)
        (let* ((base (delq 'my-rust-project-try-local functions))
               (tail (memq 'project-try-vc base))
               (n (if tail (- (length base) (length tail))
                    (length base))))
          (setq project-find-functions
                (append (take n base)
                        (list 'my-rust-project-try-local)
                        (nthcdr n base))))))))

(defun my-rust-project-root ()
  "Return the current Rust project root directory.
Prefer the nearest Cargo.toml.  In a workspace, a member crate has
its own Cargo.toml, so cargo commands run from that member's
directory act on that member only (for example `cargo test' tests
only that crate)."
  (file-name-as-directory
   (expand-file-name
    (or (locate-dominating-file default-directory "Cargo.toml")
        (when-let* ((project (project-current)))
          (project-root project))
        default-directory))))

;;; Completion

;; Company is the completion UI; `company-capf' presents rust-analyzer's
;; completion-at-point results.  `company-dabbrev-code' only kicks in
;; when the language server is unavailable, so editing still works
;; without rust-analyzer.  The list is also registered with
;; `my-ide-register-company-backends' so init-ide.el restores it after
;; Eglot's managed mode narrows `company-backends' to company-capf
;; (Emacs 30 behavior).
(defconst my-rust-company-backends
  '(company-capf company-dabbrev-code company-files)
  "Company backend list for Rust buffers.")

(defun my-rust-company-setup ()
  "Prefer rust-analyzer's semantic completion in the current Rust buffer."
  (setq-local company-backends my-rust-company-backends))

(my-ide-register-company-backends my-rust-modes my-rust-company-backends)

(dolist (hook my-rust-mode-hooks)
  (add-hook hook #'my-rust-company-setup))

;;; LSP: Eglot + rust-analyzer

(defun my-rust-analyzer-contact (&rest _)
  "Return the rust-analyzer command line for Eglot.
Eglot calls this each time it starts a server (the extra arguments it may
pass are ignored), so changes to `my-rust-analyzer-options' -- including
directory-local values -- apply to the next server."
  (list "rust-analyzer" :initializationOptions my-rust-analyzer-options))

;; Defined by eglot.el; the declaration silences the byte compiler.
(defvar eglot-server-programs)

(with-eval-after-load 'eglot
  ;; `setf' + `alist-get' with `equal' replaces an entry when one exists
  ;; (newer Emacs versions ship a rust-analyzer entry) and adds it
  ;; otherwise, so this never duplicates.  The contact is a function so it
  ;; is evaluated when a server starts, not once when Eglot loads.
  (setf (alist-get my-rust-modes eglot-server-programs nil nil 'equal)
        #'my-rust-analyzer-contact))

(defun my-rust-eglot-ensure ()
  "Start Eglot in a Rust buffer, skipping temporary buffers.
Also skipped when rust-analyzer is not installed, so that editing
still works with dabbrev-based completion alone, and for downloaded
crate and toolchain sources (see `my-rust-eglot-skip-regexp')."
  (unless (or (and (fboundp 'my-buffer-file-temp-p)
                   (my-buffer-file-temp-p))
              (and my-rust-eglot-skip-regexp
                   buffer-file-name
                   (string-match-p my-rust-eglot-skip-regexp buffer-file-name)))
    (when (if (fboundp 'my-rust-langserver-exist)
              (my-rust-langserver-exist)
            (executable-find "rust-analyzer"))
      (eglot-ensure))))

(dolist (hook my-rust-mode-hooks)
  (add-hook hook #'my-rust-eglot-ensure))

;; Putting `eglot-completion-at-point' first in
;; `completion-at-point-functions', inlay hints (parameter names,
;; deduced types), Flymake-only diagnostics, and the xref identifier
;; fix are the language-neutral Eglot setup in init-ide.el; toggle
;; hints with M-x eglot-inlay-hints-mode.

;;; Diagnostics

;; Additive exclusion via init-ide.el's helper: a plain `setq' of
;; `flycheck-global-modes' here would be overwritten by, or overwrite,
;; the C/C++ layer's exclusion (which shape the final value gets would
;; depend on the load order).
(my-ide-flycheck-exclude my-rust-modes)

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
(defun my-rust--manifest-edition (directory)
  "Return the edition declared in DIRECTORY's Cargo.toml, or nil.
`edition.workspace = true' does not match: it has no value to read."
  (let ((file (expand-file-name "Cargo.toml" directory)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        ;; Anchor to a line start so a commented-out `# edition = ...'
        ;; line is not matched, and accept TOML literal single quotes.
        (when (re-search-forward
               "^edition\\s-*=\\s-*[\"']\\([0-9]+\\)[\"']" nil t)
          (match-string 1))))))

(defun my-rust-cargo-edition ()
  "Return the Rust edition declared near the current buffer, or nil.
Searches the nearest Cargo.toml first, then parent directories, so
`edition.workspace = true' in a workspace member resolves through the
workspace root."
  (let ((directory (when-let* ((found (locate-dominating-file
                                       default-directory "Cargo.toml")))
                     (expand-file-name found)))
        edition)
    (while (and directory (not edition))
      (setq edition (my-rust--manifest-edition directory))
      (unless edition
        (setq directory (my-rust--parent-manifest-directory directory))))
    edition))

;; Defined by apheleia.el; the declarations silence the byte compiler.
(defvar apheleia-formatters)
(defvar apheleia-mode-alist)

(with-eval-after-load 'apheleia
  (setf (alist-get 'rustfmt apheleia-formatters)
        '("rustfmt" "--quiet" "--emit" "stdout" "--edition"
          ;; Evaluated in the buffer being formatted; fall back to 2024
          ;; (the edition `cargo new' picks) for files without a project.
          (or (my-rust-cargo-edition) "2024")))
  ;; Spell the mode mapping out too, so formatting does not depend on the
  ;; installed Apheleia version already mapping both Rust modes.
  (dolist (mode my-rust-modes)
    (setf (alist-get mode apheleia-mode-alist) 'rustfmt)))

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
  "Run the crate's test suite with `cargo test'.
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
  "Format the whole crate with `cargo fmt'.
This rewrites files on disk, so buffers visiting them go stale; for the
file you are editing prefer `my-rust-format'."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "fmt"))

(defun my-rust-format (&optional whole-crate)
  "Format the current Rust buffer with apheleia (rustfmt).
With prefix argument WHOLE-CRATE, run `cargo fmt' on the whole crate
instead.  This is the Rust implementation behind the shared `,nf' key.
Apheleia formats the buffer in place and keeps point, whereas `cargo fmt'
rewrites the files on disk under the open buffers."
  (interactive "P")
  (cond
   (whole-crate (my-rust-cargo-fmt))
   ((fboundp 'apheleia-format-buffer)
    (call-interactively #'apheleia-format-buffer))
   (t (user-error "Apheleia is not available; use a prefix argument for `cargo fmt'"))))

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
CRATE may carry further `cargo add' arguments, for example
\"serde --features derive\" or \"tokio@1 -F full\".
With prefix argument DEV, add it under [dev-dependencies]."
  (interactive
   (list (read-string "Crate to add (and options): ") current-prefix-arg))
  (when (string-empty-p (string-trim crate))
    (user-error "Enter a crate name, for example serde"))
  (my-rust-cargo-compile
   (my-rust-project-root)
   (concat "add "
           (mapconcat #'shell-quote-argument (split-string-and-unquote crate) " ")
           (when dev " --dev"))))

(defun my-rust-cargo-clean ()
  "Remove build artifacts with `cargo clean'."
  (interactive)
  (my-rust-cargo-compile (my-rust-project-root) "clean"))

(defun my-rust-cargo-command (command)
  "Run COMMAND as a cargo subcommand in the project root.
COMMAND may include the \"cargo \" prefix.  The prompt is prefilled
with it, so type only the subcommand and its arguments, for example
\"build --release\"."
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
    ;; `gdb' and `lldb' split their command line with
    ;; `split-string-and-unquote', which understands double quotes but not
    ;; shell backslash escapes; `combine-and-quote-strings' is its inverse,
    ;; so a path containing spaces survives the round trip.
    (pcase my-rust-debugger
      ((or 'rust-gdb 'gdb)
       (gdb (combine-and-quote-strings
             (list debugger "-i=mi" "--args" executable))))
      ((or 'rust-lldb 'lldb)
       (lldb (combine-and-quote-strings (list debugger executable)))))))

;;; Shared operations

;; Register the Rust implementations behind init-ide.el's shared ","
;; "n" keys: ,nb build, ,nt test, ,nd debug, ,nl lint, ,nf format.
(my-ide-register 'build my-rust-modes #'my-rust-cargo-build)
(my-ide-register 'test my-rust-modes #'my-rust-cargo-test)
(my-ide-register 'debug my-rust-modes #'my-rust-debug)
(my-ide-register 'lint my-rust-modes #'my-rust-cargo-clippy)
(my-ide-register 'format my-rust-modes #'my-rust-format)

;;; Keybindings

;; The language layers share one prefix, "," "t" (left index): these
;; cargo keys are bound in the Rust mode maps, the C/C++ keys in the
;; C/C++ and CMake mode maps (init-CIDE.el), so the mode decides which
;; function a key fires.  The shared operations (build/test/debug/
;; lint/format) are bound under "," "n" by init-ide.el.  The former
;; ",tr" cleanup-buffer-safe key moved to ",br" in init-evil.el to
;; free this prefix.
;;
;; The mode scoping keeps this language layer out of unrelated
;; buffers; the global "," keys stay available in Rust buffers
;; through keymap fallback.
(defconst my-rust-keymaps '(rust-ts-mode-map rust-mode-map)
  "Mode maps where the cargo-specific ,t keys are active.")

;; The mode maps exist only after their libraries load.  rust-ts-mode
;; (built into Emacs) warns when it loads while the grammar is missing,
;; so it loads only once the grammar exists; on a fresh install the
;; background install (init-tree-sitter.el) runs the loader again from
;; `my-treesit-grammars-ready-hook'.
;; rust-mode (MELPA) is not required here: loading it at startup just for
;; its map costs time in every session, so its keys are bound from
;; `with-eval-after-load' below, when the first buffer loads it.

(defun my-rust-load-ts-mode ()
  "Load the built-in `rust-ts-mode' once the grammar is installed.
Does nothing when init-tree-sitter.el has not been loaded."
  (when (and (fboundp 'my-treesit-grammar-available-p)
             (my-treesit-grammar-available-p 'rust))
    (ignore-errors (require 'rust-ts-mode))))

(my-rust-load-ts-mode)
(add-hook 'my-treesit-grammars-ready-hook #'my-rust-load-ts-mode)

(defmacro my-rust-bind-t-keys ()
  "Bind the cargo ,t keys in every Rust mode map that exists yet.
A mode map exists only after its file loads, which happens once the
grammar is installed or the first Rust buffer opens, so the keys are
bound again from each mode file's `with-eval-after-load' hook.  Does
nothing while no mode map exists: an empty `:keymaps' would make
`general-def' bind into the global evil map."
  '(let ((maps (seq-filter #'boundp my-rust-keymaps)))
     (when maps
       ;; Expand at run time: `my-comma-leader-def' is a macro without
       ;; a function cell, so a file compiled without init-evil loaded
       ;; would turn a direct call into a broken function call.
       (eval (macroexpand
              `(my-comma-leader-def
                :keymaps ',maps
                "tr" #'my-rust-cargo-run
                "tc" #'my-rust-cargo-check
                "tu" #'my-rust-cargo-update
                "ta" #'my-rust-cargo-add
                "td" #'my-rust-cargo-doc
                "tx" #'my-rust-cargo-clean
                "tb" #'my-rust-cargo-command))))))

;; Wait for init-evil rather than for evil itself (like init-python.el):
;; `my-comma-leader-def' is defined in init-evil.el, and evil finishes
;; loading inside it, before the definer exists.
(with-eval-after-load 'init-evil (my-rust-bind-t-keys))
;; A mode file may load before init-evil has defined the definer, so each
;; of these waits for it as well.
(with-eval-after-load 'rust-mode
  (with-eval-after-load 'init-evil (my-rust-bind-t-keys)))
(with-eval-after-load 'rust-ts-mode
  (with-eval-after-load 'init-evil (my-rust-bind-t-keys)))

;;; Existing buffers

(defun my-rust-configure-existing-buffers ()
  "Apply Rust setup to buffers that already exist when this file is loaded."
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
