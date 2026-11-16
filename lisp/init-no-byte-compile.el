;; -*- coding: utf-8; lexical-binding: t; -*-
;; Copyright (C) 2026 meidanzo <meidanzo@foxmail.com> and others
;; Derived from redguardtoo/emacs.d (GPL-3.0-or-later); modified by meidanzo, 2026.
;; SPDX-License-Identifier: GPL-3.0-or-later

(when (boundp 'evil-mode)
  (general-imap ","
    (general-key-dispatch 'self-insert-command
      :timeout 0.5
      "." 'my-toggle-input-method)))

(provide 'init-no-byte-compile)
;;; init-no-byte-compile.el ends here

;; Local Variables:
;; no-byte-compile: t
;; End:
