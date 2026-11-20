;; emacs.d-test.el --- unit tests for redguardtoo/emacs.d -*- coding: utf-8; lexical-binding: t; -*-


;;; Commentary:
(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path
             (expand-file-name "../lisp" (file-name-directory load-file-name)))
(require 'init-spelling)

(ert-deftest test-general ()
  (should t))

(ert-deftest my-spell-check-buffer-reports-missing-backend ()
  (cl-letf (((symbol-value 'ispell-program-name) nil)
            ((symbol-function 'executable-find) (lambda (_program) nil)))
    (let ((error-data (should-error (my-spell-check-buffer) :type 'user-error)))
      (should (string-match-p "Install aspell or hunspell"
                              (error-message-string error-data))))))

(ert-deftest my-spell-check-buffer-runs-wucuo-in-normal-mode ()
  (let (checked-mode)
    (cl-letf (((symbol-value 'ispell-program-name) "aspell")
              ((symbol-function 'executable-find) (lambda (_program) "/fake/aspell"))
              ((symbol-function 'my-ensure) (lambda (_feature) t))
              ((symbol-function 'wucuo-spell-check-internal)
               (lambda () (setq checked-mode wucuo-flyspell-start-mode))))
      (my-spell-check-buffer)
      (should (equal checked-mode "normal")))))

;; wucuo 经 after-save-hook 由 auto-save-visited-mode 的 idle timer 触发,
;; timer 回调运行在 `inhibit-quit' 为 t 的上下文, `flyspell-word' 内部
;; 无超时的 `(accept-process-output ispell-process)' 会触发 Emacs C 层
;; "Blocking call to accept-process-output with quit inhibited!!" 警告.
;; init-spelling.el 用 advice 在 `flyspell-word' 外层临时允许 quit 消除它.
(ert-deftest my-flyspell-word-with-local-quit-runs-with-quit-enabled ()
  "advice 执行期间 `inhibit-quit' 必须为 nil.
C 层警告的触发条件就是 Vinhibit_quit 非空 (process.c), 让 advice
进入时临时置空即可消除警告并使 C-g 可中断 ispell 等待."
  (let ((inside-inhibit-quit 'unset))
    (my-flyspell-word-with-local-quit
     (lambda (&rest _args) (setq inside-inhibit-quit inhibit-quit)))
    (should (null inside-inhibit-quit))))

(ert-deftest my-flyspell-word-with-local-quit-passes-through ()
  "advice 必须透传参数并返回原始函数的返回值."
  (should (equal 3 (my-flyspell-word-with-local-quit
                    (lambda (&rest args) (apply #'+ args))
                    1 2))))

(ert-deftest my-flyspell-word-advice-registered ()
  "advice 必须以 :around 形式挂在 `flyspell-word' 上."
  (require 'flyspell)
  (let (found)
    (advice-mapc (lambda (ad _props)
                   (when (eq ad #'my-flyspell-word-with-local-quit)
                     (setq found t)))
                 'flyspell-word)
    (should found)))

(ert-run-tests-batch-and-exit)
