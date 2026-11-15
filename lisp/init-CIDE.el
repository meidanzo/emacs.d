;;; init-CIDE.el --- personal C/C++ IDE setup  -*- lexical-binding: t; -*-
;;; Commentary:
;; The C/C++ IDE layer: build system commands (CMake/Autotools/Make/
;; Meson/Ninja/xmake/Bear), compile_commands.json management, Eglot +
;; clangd, apheleia + clang-format, cppcheck, and the C/C++-specific
;; "," leader keybindings.
;;
;; The keys shared with every language layer (build/test/debug/lint/
;; format and the LSP rename/actions/references/reconnect keys) live
;; in init-ide.el; this file registers its implementations with
;; `my-ide-register' and keeps only C/C++-specific keys here.
;;
;; Language-specific "," + "t" keys (the prefix is shared with
;; init-rust.el; the buffer's mode decides which function fires):
;;   ,tc 配置        ,tb 自定义构建    ,te 自定义测试
;;   ,td CTest调试   ,tj 捕获编译库    ,tv 检查编译库
;;   ,th 头/源切换   ,tw 写.clang-format
;; (w for write: ,tf would shadow the global ,tff/,tfm frame toggles)
;;
;; Loaded by `require-init' from init.el like the other init-* parts;
;; the `t' flag keeps it disabled in light weight mode.
;;
;; Dependencies (all loaded earlier by init.el):
;; - `my-buffer-file-temp-p' from init-utils.el
;; - `my-comma-leader-def' from init-evil.el (requires evil)
;; - `my-ide-register' from init-ide.el
;; - company, flycheck, apheleia (from init-elpa.el); Eglot is built in
;;
;; Section overview:
;;   1. Customization           defcustoms and per-project overrides
;;   2. Project detection       project root, build system detection
;;   3. Compilation helpers     async compile + success callbacks
;;   4. Build system backends   one subsection per build system
;;   5. Generic commands        configure/build/test dispatch, database
;;   6. Debugging               GDB/LLDB and CTest under GDB
;;   7. LSP                     Eglot + clangd wiring
;;   8. Formatting              apheleia + clang-format
;;   9. Static analysis         cppcheck
;;  10. Shared operations       registrations for init-ide.el's keys
;;  11. Keybindings             C/C++-specific "," leader keys
;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)

(defgroup my-cpp nil
  "C/C++ project commands based on clangd and the project's build tools."
  :group 'tools)

;;; Customization

(defcustom my-cpp-clangd-query-drivers nil
  "Compiler executable globs clangd may query for target and system headers.
Set this to the actual compiler paths emitted by compile_commands.json,
for example: (\"/usr/bin/arm-none-eabi-*\" \"/opt/toolchain/bin/*-g++\")."
  :type '(repeat string)
  :group 'my-cpp)

(defcustom my-cpp-build-system 'auto
  "Build system used by the common C/C++ commands.
With `auto', choose a backend from the project files."
  :type '(choice (const :tag "Detect from project files" auto)
                 (const cmake) (const autotools) (const make) (const meson)
                 (const ninja) (const xmake) (const generic))
  :group 'my-cpp)

(defcustom my-cpp-build-directory "build"
  "Default out-of-source build directory for CMake, Autotools, Meson, and Ninja."
  :type 'string
  :group 'my-cpp)

(defcustom my-cpp-make-command "make"
  "Command used to build Makefile projects."
  :type 'string
  :group 'my-cpp)

(defcustom my-cpp-autotools-configure-options nil
  "Extra arguments passed to an Autotools project's configure script."
  :type '(repeat string)
  :group 'my-cpp)

(defcustom my-cpp-ninja-command "ninja"
  "Command used to build Ninja projects."
  :type 'string
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

(defcustom my-cpp-meson-build-type "debug"
  "Build type passed to Meson when configuring a project."
  :type 'string
  :group 'my-cpp)

(defcustom my-cpp-meson-configure-options nil
  "Extra Meson setup arguments, each passed as one shell-quoted argument."
  :type '(repeat string)
  :group 'my-cpp)

(defcustom my-cpp-xmake-mode "debug"
  "Build mode passed to xmake when configuring a project."
  :type 'string
  :group 'my-cpp)

(defcustom my-cpp-xmake-configure-options nil
  "Extra xmake configuration arguments, each passed as one shell-quoted argument."
  :type '(repeat string)
  :group 'my-cpp)

(defcustom my-cpp-debugger 'gdb
  "Debugger started by `my-cpp-debug'."
  :type '(choice (const :tag "GDB" gdb)
                 (const :tag "LLDB" lldb))
  :group 'my-cpp)

(defcustom my-cpp-project-test-command nil
  "Optional project-specific test command used by `my-cpp-test'."
  :type '(choice (const :tag "Use the build system's default" nil)
                 (string :tag "Project test command"))
  :group 'my-cpp)

(defcustom my-cpp-project-debug-command-line nil
  "Optional debugger command line for the current project.
This is passed to the selected GDB or LLDB command."
  :type '(choice (const :tag "Prompt for the executable" nil)
                 (string :tag "Debugger command line"))
  :group 'my-cpp)

;; Per-project overrides via .dir-locals.el (safe values only).
(put 'my-cpp-build-system 'safe-local-variable
     (lambda (value)
       (memq value '(auto cmake autotools make meson ninja xmake generic))))
(put 'my-cpp-debugger 'safe-local-variable
     (lambda (value) (memq value '(gdb lldb))))

;;; Project detection

(defconst my-cpp-project-markers
  '("compile_commands.json" "CMakeLists.txt" "meson.build" "xmake.lua"
    "configure" "configure.ac" "configure.in" "Makefile.am" "autogen.sh"
    "GNUmakefile" "Makefile" "makefile" "build.ninja" "build/build.ninja")
  "Files that identify a C/C++ project root.")

(defconst my-cpp-modes '(c-mode c-ts-mode c++-mode c++-ts-mode objc-mode)
  "Major modes treated as C/C++ by this configuration.
The order matches Emacs 30.1's default `eglot-server-programs' key for
these modes, so `alist-get' with `equal' replaces the default entry
instead of adding a duplicate.")

(defconst my-cpp-mode-hooks
  '(c-mode-hook c++-mode-hook objc-mode-hook c-ts-mode-hook c++-ts-mode-hook)
  "Mode hooks matching `my-cpp-modes'.")

;; Make project.el recognize C/C++ projects that are not under version
;; control (for example a Bear-captured Make project without .git).
;; `my-cpp-project-root' already finds these markers itself, but Eglot and
;; other project.el users need the same detection: without it,
;; `project-current' returns nil in such directories and Eglot falls back
;; to a transient project rooted at the source file's directory.
;;
;; The markers are deliberately NOT added to
;; `project-vc-extra-root-markers': Emacs 30's `project-try-vc--search'
;; lets the marker nearest to the buffer win over the version-control
;; root, so a subdirectory build file (blanket's `blanket/meson.build',
;; CopyQ's `src/CMakeLists.txt') would re-root a buffer inside that
;; subdirectory, hiding the real project root and the compilation
;; database from Eglot.  A find function that only fires without a VC
;; backend keeps the original non-VC use case.
(defun my-cpp-project-try-local (directory)
  "Recognize a C/C++ project by its build files when no VC root exists.
Return a transient project rooted at the outermost build-file marker
below DIRECTORY, or nil when DIRECTORY is under version control."
  (unless (ignore-errors (vc-responsible-backend directory))
    (let ((roots (delq nil
                       (mapcar (lambda (marker)
                                 (locate-dominating-file directory marker))
                               my-cpp-project-markers))))
      (when roots
        (cons 'transient
              (car (sort roots (lambda (left right)
                                 (> (length left) (length right))))))))))

(with-eval-after-load 'project
  (add-hook 'project-find-functions #'my-cpp-project-try-local t))

(defun my-cpp-vc-root ()
  "Return the version-control root of `default-directory', or nil.
Build files also live in subdirectories (CopyQ's `src/CMakeLists.txt',
for example), so the nearest build-file marker is not always the
project root.  The VC root is a reliable upper bound when one exists."
  (ignore-errors
    (when-let* ((backend (vc-responsible-backend default-directory)))
      (file-name-as-directory
       (vc-call-backend backend 'root default-directory)))))

(defun my-cpp-project-root ()
  "Return the current C/C++ project root.
The result is always expanded: `locate-dominating-file' abbreviates
paths under the home directory with a literal `~', which
`shell-quote-argument' would then escape, breaking the shell commands
that embed the root."
  (file-name-as-directory
   (expand-file-name
    (or (my-cpp-vc-root)
        (let ((roots (delq nil
                           (mapcar (lambda (marker)
                                     (locate-dominating-file default-directory marker))
                                   my-cpp-project-markers))))
          (car (sort roots (lambda (left right)
                             (> (length left) (length right))))))
        (when-let* ((project (project-current)))
          (project-root project))
        default-directory))))

(defun my-cpp-cmake-declares-project-p (directory)
  "Return non-nil when DIRECTORY's CMakeLists.txt declares a project.
Subdirectory CMakeLists.txt files are normally fragments included with
`add_subdirectory' and contain no `project' command."
  (let ((file (expand-file-name "CMakeLists.txt" directory)))
    (and (file-readable-p file)
         (with-temp-buffer
           (insert-file-contents file)
           (re-search-forward
            "^[ \t]*[Pp][Rr][Oo][Jj][Ee][Cc][Tt][ \t]*(" nil t)))))

(defun my-cpp-cmake-root ()
  "Return the CMake project root, or the generic project root.
Starting from the nearest CMakeLists.txt, keep climbing until one that
calls `project' is found, so a subdirectory fragment is not configured
as a standalone project."
  (let ((directory (locate-dominating-file default-directory "CMakeLists.txt"))
        root)
    (while (and directory (not root))
      (if (my-cpp-cmake-declares-project-p directory)
          (setq root directory)
        (let ((parent (file-name-directory
                       (directory-file-name directory))))
          (setq directory (unless (equal parent directory)
                            (locate-dominating-file parent "CMakeLists.txt"))))))
    (or (when root (expand-file-name root))
        (expand-file-name
         (or (locate-dominating-file default-directory "CMakeLists.txt")
             (my-cpp-project-root))))))

(defun my-cpp-detect-build-system (&optional root)
  "Detect a supported build system from project files under ROOT."
  (let ((root (or root (my-cpp-project-root))))
    (cond
     ((file-exists-p (expand-file-name "CMakeLists.txt" root)) 'cmake)
     ((file-exists-p (expand-file-name "meson.build" root)) 'meson)
     ((file-exists-p (expand-file-name "xmake.lua" root)) 'xmake)
     ;; Autotools: a configure script (release tarballs) or the autoconf
     ;; input files plus their bootstrap inputs.  Checked before Make
     ;; because the generated Makefile appears only after ./configure.
     ((or (file-exists-p (expand-file-name "configure" root))
          (and (or (file-exists-p (expand-file-name "configure.ac" root))
                   (file-exists-p (expand-file-name "configure.in" root)))
               (or (file-exists-p (expand-file-name "Makefile.am" root))
                   (file-exists-p (expand-file-name "autogen.sh" root)))))
      'autotools)
     ((or (file-exists-p (expand-file-name "GNUmakefile" root))
          (file-exists-p (expand-file-name "Makefile" root))
          (file-exists-p (expand-file-name "makefile" root)))
      'make)
     ((or (file-exists-p (expand-file-name "build.ninja" root))
          (file-exists-p (expand-file-name "build/build.ninja" root)))
      'ninja)
     (t 'generic))))

(defun my-cpp-current-build-system ()
  "Return the configured build system, or detect it from project files."
  (if (eq my-cpp-build-system 'auto)
      (my-cpp-detect-build-system)
    my-cpp-build-system))

;;; Compilation helpers

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

;;; Build system backends

;;; CMake

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
When CHOOSE is non-nil, prompt even if one cached build directory exists.
The result is always an expanded path (see `my-cpp-project-root')."
  (let* ((root (file-name-as-directory (my-cpp-cmake-root)))
         (candidates (my-cpp-cmake-build-candidates root)))
    (expand-file-name
     (cond
      ((and (= (length candidates) 1) (not choose))
       (car candidates))
      ((> (length candidates) 1)
       (completing-read "CMake build directory: " candidates nil t))
      (t
       (read-directory-name
        "CMake build directory: " root
        (or (car candidates)
            (expand-file-name my-cpp-build-directory root)) nil)))
     root)))

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

;;; Meson

(defun my-cpp-meson-build-candidates (root)
  "Return configured Meson build directories under ROOT."
  (delete-dups
   (delq nil
         (append
          (when (file-exists-p (expand-file-name "meson-private/coredata.dat" root))
            (list (file-name-as-directory root)))
          (mapcar (lambda (file)
                    (file-name-directory
                     (directory-file-name (file-name-directory file))))
                  (file-expand-wildcards
                   (expand-file-name "*/meson-private/coredata.dat" root)))))))

(defun my-cpp-meson-build-directory (&optional choose)
  "Find a configured Meson build directory, prompting if needed.
When CHOOSE is non-nil, prompt even if exactly one build directory exists.
The result is always an expanded path (see `my-cpp-project-root')."
  (let* ((root (file-name-as-directory (my-cpp-project-root)))
         (candidates (my-cpp-meson-build-candidates root)))
    (expand-file-name
     (cond
      ((and (= (length candidates) 1) (not choose))
       (car candidates))
      ((> (length candidates) 1)
       (completing-read "Meson build directory: " candidates nil t))
      (t
       (read-directory-name
        "Meson build directory: " root
        (or (car candidates) (expand-file-name my-cpp-build-directory root)) nil)))
     root)))

(defun my-cpp-after-meson-setup (root build-directory)
  "Expose Meson's compilation database after setup succeeds."
  (my-cpp-link-compilation-database
   root (expand-file-name "compile_commands.json" build-directory))
  (my-cpp-check-compilation-database root))

(defun my-cpp-meson-configure ()
  "Configure Meson in the selected out-of-source build directory."
  (interactive)
  (let* ((root (file-name-as-directory (my-cpp-project-root)))
         (build-directory (my-cpp-meson-build-directory t))
         (configured (file-exists-p
                      (expand-file-name "meson-private/coredata.dat" build-directory)))
         (options (mapconcat #'shell-quote-argument
                             my-cpp-meson-configure-options " "))
         (command
          (string-join
           (delq nil
                 (list "meson" "setup"
                       (when configured "--reconfigure")
                       (shell-quote-argument build-directory)
                       (shell-quote-argument root)
                       (shell-quote-argument
                        (concat "--buildtype=" my-cpp-meson-build-type))
                       (unless (string-empty-p options) options)))
           " ")))
    (my-cpp-compile-at root command
                       (list #'my-cpp-after-meson-setup root build-directory))))

(defun my-cpp-meson-build ()
  "Build the selected Meson build directory."
  (interactive)
  (let ((build-directory (my-cpp-meson-build-directory)))
    (my-cpp-compile-at
     (my-cpp-project-root)
     (format "meson compile -C %s" (shell-quote-argument build-directory)))))

(defun my-cpp-meson-test ()
  "Run Meson's tests in the selected build directory."
  (interactive)
  (let ((build-directory (my-cpp-meson-build-directory)))
    (my-cpp-compile-at
     (my-cpp-project-root)
     (format "meson test -C %s --print-errorlogs"
             (shell-quote-argument build-directory)))))

;;; xmake

(defun my-cpp-after-xmake-project (root)
  "Expose xmake's generated compilation database at ROOT."
  (my-cpp-link-compilation-database
   root (expand-file-name ".vscode/compile_commands.json" root))
  (my-cpp-check-compilation-database root))

(defun my-cpp-after-xmake-configure (root)
  "Generate xmake's compilation database after configuring the project."
  (make-directory (expand-file-name ".vscode" root) t)
  ;; `xmake project' takes the output directory as a positional argument;
  ;; it has no `-o' option (it rejects one with \"Invalid option: -o\").
  (my-cpp-compile-at
   root "xmake project -k compile_commands .vscode"
   (list #'my-cpp-after-xmake-project root)))

(defun my-cpp-xmake-configure ()
  "Configure xmake's build mode and export a compilation database."
  (interactive)
  (let* ((root (my-cpp-project-root))
         (options (mapconcat #'shell-quote-argument
                             my-cpp-xmake-configure-options " "))
         (command
          (string-join
           (delq nil
                 (list "xmake" "f"
                       (shell-quote-argument
                        (concat "--mode=" my-cpp-xmake-mode))
                       (unless (string-empty-p options) options)))
           " ")))
    (my-cpp-compile-at root command
                       (list #'my-cpp-after-xmake-configure root))))

(defun my-cpp-xmake-build ()
  "Build the current xmake project."
  (interactive)
  (my-cpp-compile-at (my-cpp-project-root) "xmake"))

(defun my-cpp-xmake-test ()
  "Run tests defined by the current xmake project."
  (interactive)
  (my-cpp-compile-at (my-cpp-project-root) "xmake test"))

;;; Autotools

(defun my-cpp-autotools-build-directory ()
  "Return the configured out-of-source Autotools build directory."
  (expand-file-name my-cpp-build-directory (my-cpp-project-root)))

(defun my-cpp-autotools-configure ()
  "Run an Autotools project's bootstrap and configure steps.
Use `autogen.sh' when the project has not generated its configure script."
  (interactive)
  (let* ((root (my-cpp-project-root))
         (build-directory (my-cpp-autotools-build-directory))
         (configure (expand-file-name "configure" root))
         (autogen (expand-file-name "autogen.sh" root))
         (options (mapconcat #'shell-quote-argument
                             my-cpp-autotools-configure-options " ")))
    (unless (or (file-executable-p configure)
                (file-executable-p autogen))
      (user-error "No executable configure or autogen.sh found in %s" root))
    (my-cpp-compile-at
     root
     (string-join
      (delq nil
            (list (unless (file-executable-p configure)
                    (concat "cd " (shell-quote-argument root)
                            " && ./autogen.sh"))
                  (concat "mkdir -p " (shell-quote-argument build-directory))
                  (concat "cd " (shell-quote-argument build-directory))
                  (concat (shell-quote-argument configure)
                          (unless (string-empty-p options)
                            (concat " " options)))))
      " && "))))

(defun my-cpp-autotools-build ()
  "Build an Autotools project in its configured out-of-source directory."
  (interactive)
  (my-cpp-compile-at
   (my-cpp-project-root)
   (format "%s -C %s" my-cpp-make-command
           (shell-quote-argument (my-cpp-autotools-build-directory)))))

(defun my-cpp-autotools-test ()
  "Run the standard Autotools test target in its build directory."
  (interactive)
  (my-cpp-compile-at
   (my-cpp-project-root)
   (format "%s -C %s check" my-cpp-make-command
           (shell-quote-argument (my-cpp-autotools-build-directory)))))

;;; Make and Ninja

(defun my-cpp-make-build ()
  "Build the project with its Makefile."
  (interactive)
  (my-cpp-compile-at (my-cpp-project-root) my-cpp-make-command))

(defun my-cpp-ninja-build-directory (&optional choose)
  "Find a Ninja build directory, prompting if it is ambiguous or absent.
The result is always an expanded path (see `my-cpp-project-root')."
  (let* ((root (file-name-as-directory (my-cpp-project-root)))
         (candidates
          (delete-dups
           (delq nil
                 (append
                  (when (file-exists-p (expand-file-name "build.ninja" root))
                    (list root))
                  (mapcar #'file-name-directory
                          (file-expand-wildcards
                           (expand-file-name "*/build.ninja" root))))))))
    (expand-file-name
     (cond
      ((and (= (length candidates) 1) (not choose))
       (car candidates))
      ((> (length candidates) 1)
       (completing-read "Ninja build directory: " candidates nil t))
      (t
       (read-directory-name
        "Ninja build directory: " root
        (expand-file-name my-cpp-build-directory root) nil)))
     root)))

(defun my-cpp-ninja-build ()
  "Build the project with Ninja."
  (interactive)
  (let* ((build-directory (my-cpp-ninja-build-directory))
         (root (my-cpp-project-root))
         (command (if (file-equal-p build-directory root)
                      my-cpp-ninja-command
                    (format "%s -C %s" my-cpp-ninja-command
                            (shell-quote-argument build-directory)))))
    (my-cpp-compile-at root command)))

;;; Generic commands

(defun my-cpp-configure ()
  "Configure the detected C/C++ build system and export compile commands."
  (interactive)
  (pcase (my-cpp-current-build-system)
    ('cmake (my-cpp-cmake-configure))
    ('autotools (my-cpp-autotools-configure))
    ('meson (my-cpp-meson-configure))
    ('xmake (my-cpp-xmake-configure))
    ((or 'make 'ninja)
     (message "This project is configured by its build files; use my-cpp-build."))
    (_ (user-error "No known build files found; use my-cpp-run-build-command"))))

(defun my-cpp-build ()
  "Build the current project using its detected or selected build system."
  (interactive)
  (pcase (my-cpp-current-build-system)
    ('cmake (my-cpp-cmake-build))
    ('autotools (my-cpp-autotools-build))
    ('meson (my-cpp-meson-build))
    ('xmake (my-cpp-xmake-build))
    ('make (my-cpp-make-build))
    ('ninja (my-cpp-ninja-build))
    (_ (my-cpp-run-build-command compile-command))))

(defun my-cpp-test ()
  "Run the project's standard test command or prompt for a custom one."
  (interactive)
  (if my-cpp-project-test-command
      (my-cpp-run-test-command my-cpp-project-test-command)
    (let ((system (my-cpp-current-build-system)))
      (pcase system
        ('cmake (my-cpp-cmake-test))
        ('autotools (my-cpp-autotools-test))
        ('meson (my-cpp-meson-test))
        ('xmake (my-cpp-xmake-test))
        ('make (my-cpp-run-test-command
                (read-string "Make test command: " "make test")))
        ('ninja
         (let* ((root (my-cpp-project-root))
                (build-directory (my-cpp-ninja-build-directory))
                (command (concat my-cpp-ninja-command
                                 (unless (file-equal-p build-directory root)
                                   (concat " -C "
                                           (shell-quote-argument build-directory)))
                                 " test")))
           (my-cpp-run-test-command
            (read-string "Ninja test command: " command))))
        (_ (call-interactively #'my-cpp-run-test-command))))))

(defun my-cpp-run-build-command (command)
  "Run a project-specific build command in the project root."
  (interactive (list (read-string "Build command: " compile-command)))
  (my-cpp-compile-at (my-cpp-project-root) command))

(defun my-cpp-run-test-command (command)
  "Run a project-specific test command in the project root."
  (interactive (list (read-string "Test command: ")))
  (my-cpp-compile-at (my-cpp-project-root) command))

(defun my-cpp-link-compilation-database (root source)
  "Expose SOURCE's compilation database at ROOT for clangd.
SOURCE may be a build directory or a path to compile_commands.json."
  (let ((database (if (file-directory-p source)
                      (expand-file-name "compile_commands.json" source)
                    source))
        (link (expand-file-name "compile_commands.json" root)))
    (cond
     ((not (file-exists-p database))
      (message "No compilation database was produced at %s" database))
     ;; An in-source build (for example `cmake -B .') puts the database at
     ;; ROOT itself.  Do not delete it and then create a symlink to itself.
     ((file-equal-p database link)
      (message "Compilation database is already at %s" link))
     (t
      (when (and (file-exists-p link) (not (file-symlink-p link)))
        (unless (yes-or-no-p
                 (format "Replace existing %s with this compilation database? " link))
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

(defun my-cpp-bear-command-default ()
  "Return a useful Bear command for the detected build system."
  (let ((root (my-cpp-project-root)))
    (pcase (my-cpp-current-build-system)
      ('make (concat "bear -- " my-cpp-make-command " -B"))
      ('autotools
       (format "bear -- %s -B -C %s" my-cpp-make-command
               (shell-quote-argument (my-cpp-autotools-build-directory))))
      ('ninja
       (let ((build-directory (my-cpp-ninja-build-directory)))
         (concat "bear -- " my-cpp-ninja-command
                 (unless (file-equal-p build-directory root)
                   (concat " -C " (shell-quote-argument build-directory))))))
      ('meson (format "bear -- meson compile -C %s"
                      (shell-quote-argument
                       (my-cpp-meson-build-directory))))
      (_ "bear -- make -B"))))

(defun my-cpp-capture-compilation-database (command)
  "Generate or capture compile_commands.json for the current project.
Use native database export for CMake, Meson, and xmake. COMMAND is used with
Bear for Autotools, Make, Ninja, and generic build commands."
  (interactive
   (if (memq (my-cpp-current-build-system) '(cmake meson xmake))
       (list nil)
     (list (read-string "Build command to capture with Bear: "
                        (my-cpp-bear-command-default)))))
  (if (null command)
      (pcase (my-cpp-current-build-system)
        ('cmake (my-cpp-cmake-configure))
        ('meson (my-cpp-meson-configure))
        ('xmake (my-cpp-xmake-configure)))
    (let ((root (my-cpp-project-root)))
      (when (file-symlink-p (expand-file-name "compile_commands.json" root))
        (unless (yes-or-no-p
                 (format "Bear will replace the compile_commands.json symlink at %s.  Continue? "
                         root))
          (user-error "Kept existing compilation database")))
      (my-cpp-compile-at
       root command
       (list #'my-cpp-check-compilation-database root)))))

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
        (insert "BasedOnStyle: Google\n"
                "IndentWidth: 4\n"
                "ContinuationIndentWidth: 4\n"
                "UseTab: Never\n"))
      (message "Wrote %s" file))))

;;; Debugging

;; Multi-window GDB layout by default, showing the source file containing
;; the main routine at startup.
(setq gdb-many-windows t
      gdb-show-main t)

(defun my-cpp-debug ()
  "Start the selected debugger using Emacs' built-in debugger interface."
  (interactive)
  (let ((default-directory (file-name-as-directory (my-cpp-project-root))))
    (pcase my-cpp-debugger
      ('gdb (if my-cpp-project-debug-command-line
                (gdb my-cpp-project-debug-command-line)
              (call-interactively #'gdb)))
      ('lldb
       (unless (executable-find "lldb")
         (user-error "lldb is not on PATH"))
       (require 'gud)
       (unless (commandp 'lldb)
         (user-error "This Emacs does not provide the built-in lldb command"))
       (if my-cpp-project-debug-command-line
           (lldb my-cpp-project-debug-command-line)
         (call-interactively #'lldb))))))

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

;;; LSP: Eglot + clangd

;; Query-driver entries are an explicit allowlist: clangd may execute
;; matching compiler binaries to discover target and system headers.
;; clangd 19 does not accept a YAML fragment via --config on the command
;; line; the Diagnostics/ClangTidy settings live in
;; ~/.config/clangd/config.yaml (or in a project's .clangd file).
(with-eval-after-load 'eglot
  ;; Keep CMake language-server discovery explicit so this also works on
  ;; the declared Emacs 29.1 minimum, which may not ship Emacs 30's default.
  (setf (alist-get '(cmake-mode cmake-ts-mode) eglot-server-programs
                   nil nil 'equal)
        (eglot-alternatives
         '(("neocmakelsp" "stdio")
           ("cmake-language-server"))))

  ;; Replace the default entry instead of `add-to-list': Emacs 30 already
  ;; ships an entry for the same mode list (a clangd/ccls chooser), so
  ;; add-to-list left a stale duplicate behind.  `equal' is needed because
  ;; `alist-get' compares with `eq' by default, which can never match a
  ;; quoted literal list.
  (setf (alist-get my-cpp-modes eglot-server-programs nil nil 'equal)
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
                         (string-join my-cpp-clangd-query-drivers ",")))))))

;; The language-neutral Eglot setup shared by all language layers
;; (`my-ide-eglot-capf-first', inlay hints, Flymake-only diagnostics,
;; the xref identifier fix, autoshutdown) lives in init-ide.el.

(defun my-cpp-eglot-ensure ()
  "Start Eglot in a C/C++ buffer, skipping temporary buffers.
Also skipped when clangd is not installed, so that editing still works
and fastctags (Universal Ctags) remains the completion fallback."
  (unless (and (fboundp 'my-buffer-file-temp-p)
               (my-buffer-file-temp-p))
    (when (executable-find "clangd")
      (eglot-ensure))))

(dolist (hook my-cpp-mode-hooks)
  (add-hook hook #'my-cpp-eglot-ensure))

;; Company is the completion UI; `company-capf' presents Eglot/clangd's
;; completion-at-point results.  Keep `company-clang' out of these buffers to
;; avoid running a second C/C++ completion engine alongside clangd.  Do not use
;; `c-mode-common-hook' here: it also runs in Java, Groovy, AWK, etc.  The
;; list is also registered with `my-ide-register-company-backends' so
;; init-ide.el restores it after Eglot's managed mode narrows
;; `company-backends' to company-capf (Emacs 30 behavior).
(defconst my-cpp-company-backends
  '(company-capf company-dabbrev-code company-files)
  "Company backend list for C/C++ buffers.")

(defun my-cpp-company-setup ()
  "Prefer clangd's semantic completion in the current C/C++ buffer."
  (setq-local company-backends my-cpp-company-backends))

(my-ide-register-company-backends my-cpp-modes my-cpp-company-backends)

(dolist (hook my-cpp-mode-hooks)
  (add-hook hook #'my-cpp-company-setup))

(with-eval-after-load 'flycheck
  (setq flycheck-global-modes (cons 'not my-cpp-modes)))

;; CMake buffers: start Eglot only when a CMake language server is
;; installed.  The mapping is registered explicitly below for Emacs 29.1+
;; compatibility.
(defun my-cmake-eglot-ensure ()
  "Start Eglot in CMake buffers when a CMake language server is installed."
  (when (my-cmake-langserver-exist)
    (eglot-ensure)))
(add-hook 'cmake-mode-hook #'my-cmake-eglot-ensure)
(add-hook 'cmake-ts-mode-hook #'my-cmake-eglot-ensure)

;;; Formatting: apheleia + clang-format

;; The hook is registered at top level so the first C/C++ buffer activates
;; formatting.  apheleia's autoload file inlines `apheleia-mode', but the
;; rest of the package (formatters, mode-alist) only exists after
;; `require', so load it explicitly; the registration below runs from
;; with-eval-after-load.
(defun my-cpp-enable-apheleia ()
  "Enable Apheleia formatting in the current C/C++ buffer."
  (when (and (fboundp 'apheleia-mode)
             (ignore-errors (require 'apheleia)))
    (apheleia-mode 1)))

(dolist (hook my-cpp-mode-hooks)
  (add-hook hook #'my-cpp-enable-apheleia))

;; A command-list formatter (rather than a Lisp function formatter) keeps
;; the work in Apheleia's own asynchronous process machinery.  String
;; elements are passed through as-is; any other element is evaluated in the
;; buffer being formatted and spliced into argv.  Use that to pass
;; `--style=file' when the project has a .clang-format and to fall back to
;; Google with four spaces otherwise.  clang-format 19 rejects inline style
;; dicts in `--fallback-style' (``Invalid fallback style''), hence `--style'.
(defconst my-cpp-clang-format-command
  '("clang-format"
    "--assume-filename"
    (or (apheleia-formatters-local-buffer-file-name)
        (apheleia-formatters-mode-extension)
        ".c")
    (if (and buffer-file-name
             (locate-dominating-file
              (file-name-directory buffer-file-name)
              ".clang-format"))
        "--style=file"
      "--style={BasedOnStyle: Google, IndentWidth: 4, ContinuationIndentWidth: 4, UseTab: Never}"))
  "Apheleia formatter command for C/C++ buffers.
The project's .clang-format wins; without one, fall back to Google style
with four-space indentation, matching `c-basic-offset' and
`c-ts-mode-indent-offset'.")

(with-eval-after-load 'apheleia
  ;; `auto-save-visited-mode' (init-misc.el, 0.5s interval) saves through
  ;; `save-some-buffers', which runs `after-save-hook', so without this
  ;; advice apheleia would reformat the buffer during every idle pause.
  ;; `current-idle-time' is non-nil inside the idle auto-save timer but nil
  ;; while a user save command is running, so skip formatting only for
  ;; auto-saves.  A small threshold guards against edge cases where
  ;; `current-idle-time' returns a zero-length value.
  (defun my-apheleia-skip-auto-save (orig-fun &rest args)
    "Skip apheleia formatting when the save came from idle auto-save."
    (if (and (current-idle-time)
             (> (float-time (current-idle-time)) 0.05))
        nil
      (apply orig-fun args)))
  (advice-add 'apheleia-format-after-save :around #'my-apheleia-skip-auto-save)

  (setf (alist-get 'my-cpp-clang-format apheleia-formatters)
        my-cpp-clang-format-command)
  (dolist (mode my-cpp-modes)
    (setf (alist-get mode apheleia-mode-alist) 'my-cpp-clang-format)))

(defun my-cpp-format-buffer ()
  "Format the current C/C++ buffer with apheleia (clang-format).
This is the C/C++ implementation behind the shared `,nf' format key
bound by init-ide.el."
  (interactive)
  (if (fboundp 'apheleia-format-buffer)
      (call-interactively #'apheleia-format-buffer)
    (user-error "apheleia is not available; cannot format the buffer")))

;;; Static analysis

(defun my-cpp-cppcheck ()
  "Run cppcheck on the current project with the GCC error template.
The GCC-style template makes the messages clickable in the compilation
buffer."
  (interactive)
  (my-cpp-compile-at
   (my-cpp-project-root)
   (concat "cppcheck --enable=all --inconclusive --std=c++17"
           " --template=gcc --quiet .")))

;;; Existing buffers

(defun my-cpp-configure-existing-buffers ()
  "Apply C/C++ setup to buffers that already exist when this file loads."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and buffer-file-name
                 (apply #'derived-mode-p my-cpp-modes))
        (my-cpp-company-setup)
        (when (fboundp 'apheleia-mode)
          (apheleia-mode 1))
        (my-cpp-eglot-ensure)))))

;;; Shared operations

;; Register the C/C++ implementations behind init-ide.el's shared ","
;; "n" keys: ,nb build, ,nt test, ,nd debug, ,nl lint, ,nf format.
(my-ide-register 'build my-cpp-modes #'my-cpp-build)
(my-ide-register 'test my-cpp-modes #'my-cpp-test)
(my-ide-register 'debug my-cpp-modes #'my-cpp-debug)
(my-ide-register 'lint my-cpp-modes #'my-cpp-cppcheck)
(my-ide-register 'format my-cpp-modes #'my-cpp-format-buffer)

;; The CMake mode maps also bind this layer's "," "t" keys (see the
;; keybinding section), so CMake buffers are part of the layer.  Give
;; them the shared operations that make sense from a CMakeLists.txt
;; buffer too: build/test/debug/lint all dispatch from the project
;; root and work unchanged.  Format is deliberately not registered:
;; clang-format cannot format CMake files and apheleia has no CMake
;; formatter here, so ,nf keeps the honest "No 'format' command" error.
(dolist (mode '(cmake-mode cmake-ts-mode))
  (my-ide-register 'build (list mode) #'my-cpp-build)
  (my-ide-register 'test (list mode) #'my-cpp-test)
  (my-ide-register 'debug (list mode) #'my-cpp-debug)
  (my-ide-register 'lint (list mode) #'my-cpp-cppcheck))

;;; Keybindings

;; The language layers share one prefix, "," "t" (left index): the
;; C/C++ keys below are bound in the C/C++ and CMake mode maps, the
;; cargo keys in the Rust mode maps (init-rust.el), so the mode
;; decides which function a key fires.  The shared operations live
;; under "," "n" in init-ide.el.  All lowercase; ,tj is j for the
;; JSON compilation database.
;;
;; The mode scoping keeps this language layer out of unrelated
;; buffers; the global "," keys stay available in language buffers
;; through keymap fallback.  CMake buffers are included so the
;; project commands work from a CMakeLists.txt buffer.
(defconst my-cpp-keymaps
  '(c-mode-map c++-mode-map objc-mode-map
    c-ts-mode-map c++-ts-mode-map
    cmake-mode-map cmake-ts-mode-map)
  "Mode maps where the C/C++-specific ',' 't' keys are active.")

;; The mode maps exist only after their libraries load (all built in).
(ignore-errors (require 'c-ts-mode))
(ignore-errors (require 'c++-ts-mode))
(ignore-errors (require 'cmake-mode))
(ignore-errors (require 'cmake-ts-mode))

(with-eval-after-load 'evil
  (my-comma-leader-def
    :keymaps my-cpp-keymaps
    "tc" #'my-cpp-configure
    "tb" #'my-cpp-run-build-command
    "te" #'my-cpp-run-test-command
    "td" #'my-cpp-cmake-debug-test
    "tj" #'my-cpp-capture-compilation-database
    "tv" #'my-cpp-check-compilation-database
    "th" #'ff-find-other-file
    "tw" #'my-cpp-write-clang-format))

(my-cpp-configure-existing-buffers)

(provide 'init-CIDE)
;;; init-CIDE.el ends here
