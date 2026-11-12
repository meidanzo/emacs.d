;;; init-CIDE.el --- personal C/C++ IDE setup  -*- lexical-binding: t; -*-
;;; Commentary:
;; Personal customization, loaded by `require-init' from init.el exactly
;; like the other init-* parts.  The `t' flag passed to `require-init'
;; keeps it disabled in light weight mode (`my-lightweight-mode-p').
;;
;; Dependencies (all loaded earlier by init.el):
;; - `my-run-with-idle-timer', `my-buffer-file-temp-p' from init-utils.el
;; - `my-comma-leader-def' from init-evil.el (requires evil)
;; - company, flycheck, apheleia, eglot (declared in init-elpa.el)
;;
;; This file used to live at ~/.custom.el.  The old copy is NOT loaded
;; anymore; keep edits here or the old file will drift.
;;; Code:

;; C/C++ IDE setup: CMake/Bear + clangd + Eglot + clang-format.

(require 'json)
(require 'cl-lib)
(require 'subr-x)

(defgroup my-cpp nil
  "C/C++ project commands based on clangd and the project's build tools."
  :group 'tools)

(defcustom my-cpp-clangd-query-drivers nil
  "Compiler executable globs clangd may query for target and system headers.
Set this to the actual compiler paths emitted by compile_commands.json,
for example: (\"/usr/bin/arm-none-eabi-*\" \"/opt/toolchain/bin/*-g++\")."
  :type '(repeat string)
  :group 'my-cpp)

(defcustom my-cpp-cmake-build-config "Debug"
  "Configuration used by multi-configuration CMake generators."
  :type 'string
  :group 'my-cpp)

(defcustom my-cpp-cmake-configure-options nil
  "Extra CMake configure arguments, such as a toolchain file or generator.
Each list element is passed as one shell-quoted argument."
  :type '(repeat string)
  :group 'my-cpp)

(defun my-cpp-project-root ()
  "Return the current C/C++ project root."
  (or (when-let* ((project (project-current)))
        (project-root project))
      (locate-dominating-file default-directory "compile_commands.json")
      (locate-dominating-file default-directory "CMakeLists.txt")
      default-directory))

(defun my-cpp-cmake-root ()
  "Return the nearest CMake project root, or the generic project root."
  (or (locate-dominating-file default-directory "CMakeLists.txt")
      (my-cpp-project-root)))

(defvar-local my-cpp-after-compilation-success nil
  "Callback and arguments to run after this compilation buffer succeeds.")

(defun my-cpp-compilation-finished (buffer status)
  "Run BUFFER's success callback when STATUS reports a successful build."
  (when (and (buffer-live-p buffer)
             (string-match-p "\\`finished" status))
    (with-current-buffer buffer
      (when my-cpp-after-compilation-success
        (let ((callback my-cpp-after-compilation-success))
          (setq my-cpp-after-compilation-success nil)
          (apply (car callback) (cdr callback)))))))

(add-hook 'compilation-finish-functions #'my-cpp-compilation-finished)

(defun my-cpp-compile-at (directory command &optional after-success)
  "Run shell COMMAND asynchronously in DIRECTORY.
AFTER-SUCCESS is a callback list: (FUNCTION ARG...)."
  (let* ((default-directory (file-name-as-directory directory))
         (buffer (compile command t)))
    (when after-success
      (with-current-buffer buffer
        (setq-local my-cpp-after-compilation-success after-success)))
    buffer))

(defun my-cpp-cmake-build-candidates (root)
  "Return likely CMake build directories directly below ROOT."
  (delete-dups
   (delq nil
         (append
          (when (file-exists-p (expand-file-name "CMakeCache.txt" root))
            (list (file-name-as-directory root)))
          (mapcar #'file-name-directory
                  (file-expand-wildcards
                   (expand-file-name "*/CMakeCache.txt" root)))))))

(defun my-cpp-cmake-build-directory (&optional choose)
  "Find a CMake build directory, prompting when it is ambiguous or absent.
When CHOOSE is non-nil, prompt even if one cached build directory exists."
  (let* ((root (file-name-as-directory (my-cpp-cmake-root)))
         (candidates (my-cpp-cmake-build-candidates root)))
    (cond
     ((and (= (length candidates) 1) (not choose))
      (car candidates))
     ((> (length candidates) 1)
      (expand-file-name
       (completing-read "CMake build directory: " candidates nil t)
       root))
     (t
      (read-directory-name
       "CMake build directory: " root
       (or (car candidates) (expand-file-name "build" root)) nil)))))

(defun my-cpp-link-compilation-database (root build-directory)
  "Expose BUILD-DIRECTORY's compilation database at ROOT for clangd."
  (let ((database (expand-file-name "compile_commands.json" build-directory))
        (link (expand-file-name "compile_commands.json" root)))
    (cond
     ((not (file-exists-p database))
      (message "CMake did not produce %s; check the selected generator" database))
     ;; An in-source build (for example `cmake -B .') puts the database at
     ;; ROOT itself.  Do not delete it and then create a symlink to itself.
     ((file-equal-p database link)
      (message "Compilation database is already at %s" link))
     (t
      (when (and (file-exists-p link) (not (file-symlink-p link)))
        (unless (yes-or-no-p
                 (format "Replace existing %s with the selected CMake database? " link))
          (user-error "Kept existing compilation database at %s" link))
        (delete-file link))
      (when (file-symlink-p link)
        (delete-file link))
      (condition-case nil
          (make-symbolic-link (file-relative-name database root) link)
        (file-error
         ;; On systems where creating symlinks is unavailable, copy the generated DB.
         (copy-file database link nil)))
      (message "clangd will read %s" link)))))

(defun my-cpp-after-cmake-configure (root build-directory)
  "Link and inspect the compilation database after CMake succeeds."
  (my-cpp-link-compilation-database root build-directory)
  (my-cpp-check-compilation-database root))

(defun my-cpp-cmake-configure ()
  "Configure CMake in a selected build directory and export compile commands."
  (interactive)
  (let* ((root (file-name-as-directory (my-cpp-cmake-root)))
         (build-directory (my-cpp-cmake-build-directory t))
         (arguments (mapconcat #'shell-quote-argument
                               my-cpp-cmake-configure-options " "))
         (command
          (string-join
           (delq nil
                 (list "cmake"
                       "-S" (shell-quote-argument root)
                       "-B" (shell-quote-argument build-directory)
                       "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
                       (shell-quote-argument
                        (concat "-DCMAKE_BUILD_TYPE=" my-cpp-cmake-build-config))
                       (unless (string-empty-p arguments) arguments)))
           " ")))
    (my-cpp-compile-at root command
                       (list #'my-cpp-after-cmake-configure root build-directory))))

(defun my-cpp-cmake-build ()
  "Build the selected CMake build directory."
  (interactive)
  (let ((build-directory (my-cpp-cmake-build-directory)))
    (my-cpp-compile-at
     build-directory
     (format "cmake --build %s --config %s --parallel"
             (shell-quote-argument build-directory)
             (shell-quote-argument my-cpp-cmake-build-config)))))

(defun my-cpp-cmake-test ()
  "Run CTest in the selected CMake build directory."
  (interactive)
  (let ((build-directory (my-cpp-cmake-build-directory)))
    (my-cpp-compile-at
     build-directory
     (format "ctest --test-dir %s --build-config %s --output-on-failure"
             (shell-quote-argument build-directory)
             (shell-quote-argument my-cpp-cmake-build-config)))))

(defun my-cpp-cmake-debug-test ()
  "Run one named CTest under GDB, following CTest's test process."
  (interactive)
  (let* ((build-directory (my-cpp-cmake-build-directory))
         (pattern (read-string "CTest test name/regex to debug: ")))
    (when (string-empty-p pattern)
      (user-error "Enter a CTest test name or regular expression"))
    ;; `gdb' parses its command line with `split-string-and-unquote', so use
    ;; Lisp quoting here, not shell quoting.  `-i=mi' keeps the gdb-mi/MI
    ;; interface.  `-ex=COMMAND' keeps each command in one argv, which also
    ;; prevents gud from mistaking the command text for the executable name.
    (gdb (format
          "gdb -i=mi %s %s --args ctest --test-dir %s --build-config %s --output-on-failure --parallel 1 -R %s"
          (prin1-to-string "-ex=set follow-fork-mode child")
          (prin1-to-string "-ex=set detach-on-fork on")
          (prin1-to-string build-directory)
          (prin1-to-string my-cpp-cmake-build-config)
          (prin1-to-string pattern)))))

(defun my-cpp-capture-compilation-database (command)
  "Run COMMAND from the project root to generate compile_commands.json.
For Make, Bear's `bear -- make -B` forces a fresh capture. For other build
systems, enter the corresponding Bear or compiledb command.
Bear replaces an existing compile_commands.json symlink with a regular file;
this command asks before that happens."
  (interactive
   (list (read-string "Build command to capture (Bear/compiledb): "
                      "bear -- make -B")))
  (let ((root (my-cpp-project-root)))
    (when (file-symlink-p (expand-file-name "compile_commands.json" root))
      (unless (yes-or-no-p
               (format "Bear will replace the compile_commands.json symlink at %s.  Continue? "
                       root))
        (user-error "Kept existing compilation database")))
    (my-cpp-compile-at
     root command
     (list #'my-cpp-check-compilation-database root))))

(defun my-cpp-run-build-command (command)
  "Run a project-specific build command in the project root."
  (interactive (list (read-string "Build command: " compile-command)))
  (my-cpp-compile-at (my-cpp-project-root) command))

(defun my-cpp-run-test-command (command)
  "Run a project-specific test command in the project root."
  (interactive (list (read-string "Test command: ")))
  (my-cpp-compile-at (my-cpp-project-root) command))

(defun my-cpp-check-compilation-database (&optional root)
  "Check the structure and paths in ROOT's compile_commands.json."
  (interactive)
  (let* ((root (or root (my-cpp-project-root)))
         (database (expand-file-name "compile_commands.json" root)))
    (unless (file-readable-p database)
      (user-error "No readable compilation database at %s" database))
    (condition-case error-data
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (json-key-type 'string)
               (entries (json-read-file database))
               (invalid 0)
               (missing 0))
          (dolist (entry entries)
            (let ((directory (cdr (assoc "directory" entry)))
                  (file (cdr (assoc "file" entry)))
                  (command (or (cdr (assoc "command" entry))
                               (cdr (assoc "arguments" entry)))))
              (if (or (not (and directory (file-directory-p directory)))
                      (not (and file (not (string-empty-p file))))
                      (not (and command (not (equal command "")))))
                  (cl-incf invalid)
                (unless (file-exists-p (expand-file-name file directory))
                  (cl-incf missing)))))
          (message "compile_commands.json: %d entries, %d structurally invalid, %d missing source files"
                   (length entries) invalid missing)
          (when (> invalid 0)
            (display-warning 'my-cpp
                             "Some database entries lack a valid working directory, file, or command"))
          (when (> missing 0)
            (display-warning 'my-cpp
                             "Some database entries point to source files that do not exist")))
      (error
       (user-error "Could not parse %s: %s" database
                   (error-message-string error-data))))))

(defun my-cpp-write-clang-format ()
  "Write a 4-space .clang-format at the project root."
  (interactive)
  (let* ((root (my-cpp-project-root))
         (file (expand-file-name ".clang-format" root)))
    (when (or (not (file-exists-p file))
              (y-or-n-p (format "%s exists, overwrite? " file)))
      (with-temp-file file
        (insert "BasedOnStyle: Google\nIndentWidth: 4\n"))
      (message "Wrote %s" file))))

;; Eglot + clangd. Query-driver entries are an explicit allowlist: clangd may
;; execute matching compiler binaries to discover target and system headers.
;; clangd 19 does not accept a YAML fragment via --config on the command line.
;; The Diagnostics/ClangTidy settings live in ~/.config/clangd/config.yaml
;; (or in a project's .clangd file).  --enable-config makes that explicit.
(with-eval-after-load 'eglot
  ;; Replace the default entry instead of `add-to-list': Emacs 30 already
  ;; ships an entry for the same mode list (a clangd/ccls chooser), so
  ;; add-to-list left a stale duplicate behind.  `equal' is needed because
  ;; `alist-get' compares with `eq' by default, which can never match a
  ;; quoted literal list.
  (setf (alist-get '(c-mode c-ts-mode c++-mode c++-ts-mode objc-mode)
                   eglot-server-programs nil nil 'equal)
        (append
         '("clangd"
           "--background-index"
           "--background-index-priority=low"
           "--pch-storage=memory"
           "--clang-tidy"
           "--completion-style=detailed"
           "--header-insertion=iwyu"
           "--enable-config")
         (when my-cpp-clangd-query-drivers
           (list (concat "--query-driver="
                         (string-join my-cpp-clangd-query-drivers ","))))))
  (setq eglot-autoshutdown t))

(defun my-cpp-eglot-ensure ()
  "Start Eglot in a C/C++ buffer, skipping temporary buffers."
  (unless (and (fboundp 'my-buffer-file-temp-p)
               (my-buffer-file-temp-p))
    (eglot-ensure)))

(dolist (hook '(c-mode-hook c++-mode-hook objc-mode-hook
                c-ts-mode-hook c++-ts-mode-hook))
  (add-hook hook #'my-cpp-eglot-ensure))

(defun my-cpp-eglot-capf-first ()
  "Put clangd's completion-at-point function before fallback sources."
  (when (fboundp 'eglot-completion-at-point)
    (setq-local completion-at-point-functions
                (cons #'eglot-completion-at-point
                      (remove #'eglot-completion-at-point
                              completion-at-point-functions)))))
(add-hook 'eglot-managed-mode-hook #'my-cpp-eglot-capf-first)

;; Company: use semantic CAPF first in C/C++ buffers.  Do not use
;; `c-mode-common-hook' here: it also runs in Java, Groovy, AWK, etc.
(defun my-cpp-company-setup ()
  "Prefer clangd's semantic completion in the current C/C++ buffer."
  (setq-local company-backends
              '(company-capf company-dabbrev-code company-files)))

(dolist (hook '(c-mode-hook c++-mode-hook objc-mode-hook
                c-ts-mode-hook c++-ts-mode-hook))
  (add-hook hook #'my-cpp-company-setup))

;; Eglot uses Flymake; avoid duplicate Flycheck diagnostics.
(defun my-cpp-disable-flycheck ()
  (when (bound-and-true-p flycheck-mode)
    (flycheck-mode -1)))
(add-hook 'eglot-managed-mode-hook #'my-cpp-disable-flycheck)

(with-eval-after-load 'flycheck
  (setq flycheck-global-modes
        '(not c-mode c++-mode objc-mode c-ts-mode c++-ts-mode)))

;; clang-format on save for C/C++ only.
(defun my-cpp-enable-apheleia ()
  "Enable Apheleia formatting in the current C/C++ buffer."
  (apheleia-mode 1))

(with-eval-after-load 'apheleia
  (dolist (hook '(c-mode-hook c++-mode-hook objc-mode-hook
                  c-ts-mode-hook c++-ts-mode-hook))
    (add-hook hook #'my-cpp-enable-apheleia)))

(defun my-cpp-configure-existing-buffers ()
  "Apply C/C++ setup to buffers that already exist when this file loads."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and buffer-file-name
                 (derived-mode-p 'c-mode 'c++-mode 'objc-mode
                                 'c-ts-mode 'c++-ts-mode))
        (my-cpp-company-setup)
        (when (fboundp 'apheleia-mode)
          (apheleia-mode 1))
        (my-cpp-eglot-ensure)))))

;; Keybindings under the "," leader.
(with-eval-after-load 'evil
  (my-comma-leader-def
    "oc" #'my-cpp-cmake-configure
    "ob" #'my-cpp-cmake-build
    "oT" #'my-cpp-cmake-test
    "oD" #'my-cpp-cmake-debug-test
    "oB" #'my-cpp-run-build-command
    "oE" #'my-cpp-run-test-command
    "oG" #'my-cpp-capture-compilation-database
    "oV" #'my-cpp-check-compilation-database
    "oh" #'ff-find-other-file
    "od" #'gdb)
  (my-comma-leader-def
    "oF" #'my-cpp-write-clang-format))

(with-eval-after-load 'eglot
  (my-comma-leader-def
    "or" #'eglot-rename
    "oa" #'eglot-code-actions
    "oR" #'eglot-reconnect))

;; Configure C/C++ buffers that were already open when this file was loaded.
(my-cpp-configure-existing-buffers)

(provide 'init-CIDE)
;;; init-CIDE.el ends here
