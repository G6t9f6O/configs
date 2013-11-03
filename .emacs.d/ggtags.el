;;; ggtags.el --- GNU Global source code tagging system  -*- lexical-binding: t; -*-

;; Copyright (C) 2013  Free Software Foundation, Inc.

;; Author: Leo Liu <sdl.web@gmail.com>
;; Version: 0.6.8
;; Keywords: tools, convenience
;; Created: 2013-01-29
;; URL: https://github.com/leoliu/ggtags

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A package to integrate GNU Global source code tagging system
;; (http://www.gnu.org/software/global) with Emacs.
;;
;; Usage:
;;
;; Type `M-x ggtags-mode' to enable the minor mode, or as usual enable
;; it in your desired major mode hooks. When the mode is on the symbol
;; at point is underlined if it is a valid (definition) tag.
;;
;; `M-.' finds definition or references according to the context at
;; point, i.e. if point is at a definition tag find references and
;; vice versa. `M-]' finds references.
;;
;; If multiple matches are found, navigation mode is entered, the
;; mode-line lighter changed, and a navigation menu-bar entry
;; presented. In this mode, `M-n' and `M-p' moves to next and previous
;; match, `M-}' and `M-{' to next and previous file respectively.
;; `M-o' toggles between full and abbreviated displays of file names
;; in the auxiliary popup window. When you locate the right match,
;; press RET to finish which hides the auxiliary window and exits
;; navigation mode. You can resume the search using `M-,'. To abort
;; the search press `M-*'.
;;
;; Normally after a few searches a dozen buffers are created visiting
;; files tracked by GNU Global. `C-c M-k' helps clean them up.
;;
;; Check the menu-bar entry `Ggtags' for other useful commands.

;;; Code:

(eval-when-compile (require 'cl))
(require 'compile)

(eval-when-compile
  (unless (fboundp 'setq-local)
    (defmacro setq-local (var val)
      (list 'set (list 'make-local-variable (list 'quote var)) val)))

  (unless (fboundp 'defvar-local)
    (defmacro defvar-local (var val &optional docstring)
      (declare (debug defvar) (doc-string 3))
      (list 'progn (list 'defvar var val docstring)
            (list 'make-variable-buffer-local (list 'quote var))))))

(eval-and-compile
  (or (fboundp 'user-error)
      (defalias 'user-error 'error)))

(defgroup ggtags nil
  "GNU Global source code tagging system."
  :group 'tools)

(defface ggtags-highlight '((t (:underline t)))
  "Face used to highlight a valid tag at point.")

(defcustom ggtags-auto-jump-to-first-match t
  "Non-nil to automatically jump to the first match."
  :type 'boolean
  :group 'ggtags)

(defcustom ggtags-global-window-height 8 ; ggtags-global-mode
  "Number of lines for the 'global' popup window.
If nil, use Emacs default."
  :type '(choice (const :tag "Default" nil) integer)
  :group 'ggtags)

(defcustom ggtags-global-abbreviate-filename 35
  "Non-nil to display file names abbreviated e.g. \"/u/b/env\".
If an integer abbreviate only names longer than that number."
  :type '(choice (const :tag "No" nil)
                 (const :tag "Always" t)
                 integer)
  :group 'ggtags)

(defcustom ggtags-oversize-limit (* 50 1024 1024)
  "The over size limit for the  GTAGS file."
  :type '(choice (const :tag "None" nil)
                 (const :tag "Always" t)
                 number)
  :group 'ggtags)

(defcustom ggtags-split-window-function split-window-preferred-function
  "A function to control how ggtags pops up the auxiliary window."
  :type 'function
  :group 'ggtags)

(defcustom ggtags-use-idutils (and (executable-find "mkid") t)
  "Non-nil to also generate the idutils DB."
  :type 'boolean
  :group 'ggtags)

(defcustom ggtags-global-output-format 'grep
  "The output format for the 'global' command."
  :type '(choice (const path)
                 (const ctags)
                 (const ctags-x)
                 (const grep)
                 (const cscope))
  :group 'ggtags)

(defcustom ggtags-global-ignore-case nil
  "Non-nil if Global should ignore case."
  :safe 'booleanp
  :type 'boolean
  :group 'ggtags)

(defcustom ggtags-mode-prefix-key "\C-c"
  "Key binding used for `ggtags-mode-prefix-map'.
Users should change the value using `customize-variable' to
properly update `ggtags-mode-map'."
  ;; Set later or initialisation will fail.
  ;; :set 'ggtags-mode-update-prefix-key
  :type 'key-sequence
  :group 'ggtags)

(defcustom ggtags-completing-read-function completing-read-function
  "Ggtags specific `completing-read-function' (which see)."
  :type 'function
  :group 'ggtags)

(defvar ggtags-bug-url "https://github.com/leoliu/ggtags/issues")

(defvar ggtags-cache nil)         ; (ROOT TABLE DIRTY CTAGS TIMESTAMP)

(defvar ggtags-current-tag-name nil)

;; Used by ggtags-global-mode
(defvar ggtags-global-error "match"
  "Stem of message to print when no matches are found.")

;; http://thread.gmane.org/gmane.comp.gnu.global.bugs/1518
(defvar ggtags-global-has-path-style    ; introduced in global 6.2.8
  (with-demoted-errors                  ; in case `global' not found
    (zerop (process-file "global" nil nil nil
                         "--path-style" "shorter" "--help")))
  "Non-nil if `global' supports --path-style switch.")

;; http://thread.gmane.org/gmane.comp.gnu.global.bugs/1542
(defvar ggtags-global-has-color         ; introduced in global 6.2.9
  (with-demoted-errors
    (zerop (process-file "global" nil nil nil "--color" "--help"))))

(defmacro ggtags-ensure-global-buffer (&rest body)
  (declare (indent 0))
  `(progn
     (or (and (buffer-live-p compilation-last-buffer)
              (with-current-buffer compilation-last-buffer
                (derived-mode-p 'ggtags-global-mode)))
         (error "No global buffer found"))
     (with-current-buffer compilation-last-buffer ,@body)))

(defmacro ggtags-with-ctags-maybe (&rest body)
  `(let ((process-environment
          (if (ggtags-cache-ctags-p (ggtags-root-directory))
              (cons "GTAGSLABEL=ctags" process-environment))
          process-environment))
     ,@body))

(defun ggtags-oversize-p ()
  (pcase ggtags-oversize-limit
    (`nil nil)
    (`t t)
    (t (when (ggtags-root-directory)
         (> (or (nth 7 (file-attributes
                        (expand-file-name "GTAGS" (ggtags-root-directory))))
                0)
            ggtags-oversize-limit)))))

(defun ggtags-use-ctags-p (root)
  "Non-nil if exuberant-ctags is used for indexing ROOT."
  (let ((default-directory (file-name-as-directory root)))
    ;; Check if GRTAGS contains no tags.
    (<= (length (split-string (shell-command-to-string
                               "gtags -d GRTAGS | head -10")
                              "\n" t))
        4)))

(defun ggtags-get-timestamp (root)
  "Get the timestamp (float) of file GTAGS in ROOT directory.
Return -1 if it does not exist."
  (let ((file (expand-file-name "GTAGS" root)))
    (if (file-exists-p file)
        (float-time (nth 5 (file-attributes file)))
      -1)))

(defun ggtags-get-libpath ()
  (split-string (or (getenv "GTAGSLIBPATH") "")
                (regexp-quote path-separator) t))

(defun ggtags-cache-get (key)
  (assoc (file-truename key) ggtags-cache))

(defun ggtags-cache-set (key val &optional dirty)
  (let* ((key (file-truename key))
         (c (ggtags-cache-get key))
         (ctags (ggtags-use-ctags-p key)))
    (if c
        (setcdr c (list val dirty ctags (float-time)))
      (push (list key val dirty ctags (float-time)) ggtags-cache))))

(defun ggtags-cache-mark-dirty (key flag)
  "Return non-nil if operation is successful."
  (let ((cache (ggtags-cache-get key)))
    (when cache
      (setcar (cddr cache) flag))))

(defun ggtags-cache-ctags-p (key)
  (fourth (ggtags-cache-get key)))

(defun ggtags-cache-dirty-p (key)
  "Value is non-nil if 'global -u' is needed."
  (third (ggtags-cache-get key)))

(defun ggtags-cache-stale-p (key)
  "Value is non-nil if tags in cache needs to be rebuilt."
  (> (ggtags-get-timestamp key)
     (or (fifth (ggtags-cache-get key)) 0)))

(defun ggtags-process-string (program &rest args)
  (with-temp-buffer
    (let ((exit (apply #'process-file program nil t nil args))
          (output (progn
                    (goto-char (point-max))
                    (skip-chars-backward " \t\n")
                    (buffer-substring (point-min) (point)))))
      (or (zerop exit)
          (error "`%s' non-zero exit: %s" program output))
      output)))

(defvar-local ggtags-root-directory nil
  "Internal; use function `ggtags-root-directory' instead.")

;;;###autoload
(defun ggtags-root-directory ()
  (or ggtags-root-directory
      (setq ggtags-root-directory
            (ignore-errors (file-name-as-directory
                            (ggtags-process-string "global" "-pr"))))))

(defun ggtags-check-root-directory ()
  (or (ggtags-root-directory) (error "File GTAGS not found")))

(defun ggtags-ensure-root-directory ()
  (or (ggtags-root-directory)
      (when (or (yes-or-no-p "File GTAGS not found; run gtags? ")
                (user-error "Aborted"))
        (let ((root (read-directory-name "Directory: " nil nil t)))
          (and (zerop (length root)) (user-error "No directory chosen"))
          (when (let ((process-environment
                       (if (and (not (getenv "GTAGSLABEL"))
                                (yes-or-no-p "Use `ctags' backend? "))
                           (cons "GTAGSLABEL=ctags" process-environment)
                         process-environment))
                      (default-directory (file-name-as-directory root)))
                  (and (apply #'ggtags-process-string
                              "gtags" (and ggtags-use-idutils '("--idutils")))
                       t))
            (ggtags-tag-names-1 root)   ; update cache
            (message "GTAGS generated in `%s'" (ggtags-root-directory)))))))

(defun ggtags-update-tags (&optional single-update)
  "Update GNU Global tag database."
  (interactive)
  (ggtags-with-ctags-maybe
   (if single-update
       (when buffer-file-name
         (process-file "global" nil 0 nil "--single-update"
                       (file-truename buffer-file-name)))
     (ggtags-process-string "global" "-u"))))

(defun ggtags-tag-names-1 (root &optional from-cache)
  (when root
    (if (and (not from-cache) (ggtags-cache-stale-p root))
        (let* ((default-directory (file-name-as-directory root))
               (tags (with-demoted-errors
                       (process-lines "global" "-c" ""))))
          (and tags (ggtags-cache-set root tags))
          tags)
      (cadr (ggtags-cache-get root)))))

;;;###autoload
(defun ggtags-tag-names (&optional from-cache)
  "Get a list of tag names."
  (let ((root (ggtags-root-directory)))
    (when (and root
               (not (ggtags-oversize-p))
               (not from-cache)
               (ggtags-cache-dirty-p root))
      (ggtags-update-tags))
    (apply 'append (mapcar (lambda (r)
                             (ggtags-tag-names-1 r from-cache))
                           (cons root (ggtags-get-libpath))))))

(defun ggtags-read-tag ()
  (ggtags-ensure-root-directory)
  (let ((default (thing-at-point 'symbol))
        (completing-read-function ggtags-completing-read-function))
    (setq ggtags-current-tag-name
          (cond (current-prefix-arg
                 (completing-read
                  (format (if default "Tag (default %s): " "Tag: ") default)
                  ;; XXX: build tag names more lazily such as using
                  ;; `completion-table-dynamic'.
                  (ggtags-tag-names) nil t nil nil default))
                ((not default)
                 (user-error "No tag at point"))
                (t (substring-no-properties default))))))

(defun ggtags-global-build-command (cmd &rest args)
  ;; CMD can be definition, reference, symbol, grep, idutils
  (let ((xs (append (list "global" "-v"
                          (format "--result=%s" ggtags-global-output-format)
                          (and ggtags-global-ignore-case "--ignore-case")
                          (and ggtags-global-has-color "--color")
                          (and ggtags-global-has-path-style
                               "--path-style=shorter")
                          (pcase cmd
                            ((pred stringp) cmd)
                            (`definition "-d")
                            (`reference "-r")
                            (`symbol "-s")
                            (`grep "--grep")
                            (`idutils "--idutils")))
                    args)))
    (mapconcat 'identity (delq nil xs) " ")))

;; takes three values: nil, t and a marker
(defvar ggtags-global-start-marker nil)

(defun ggtags-global-save-start-marker ()
  (when (markerp ggtags-global-start-marker)
    (eval-and-compile (require 'etags))
    (ring-insert find-tag-marker-ring ggtags-global-start-marker)
    (setq ggtags-global-start-marker t)))

(defun ggtags-global-start (command &optional root)
  (let* ((default-directory (or root (ggtags-root-directory)))
         (split-window-preferred-function ggtags-split-window-function))
    (setq ggtags-global-start-marker (point-marker))
    (ggtags-navigation-mode +1)
    (ggtags-with-ctags-maybe
     (compilation-start command 'ggtags-global-mode))))

(defun ggtags-find-tag-resume ()
  (interactive)
  (ggtags-ensure-global-buffer
    (ggtags-navigation-mode +1)
    (let ((split-window-preferred-function ggtags-split-window-function))
      (compile-goto-error))))

(defun ggtags-find-tag (cmd name)
  (ggtags-check-root-directory)
  (ggtags-global-start (ggtags-global-build-command cmd name)))

;;;###autoload
(defun ggtags-find-tag-dwim (name &optional definition)
  "Find definitions or references of tag NAME by context.
If point is at a definition tag, find references, and vice versa.
With a prefix arg (non-nil DEFINITION) always find defintions."
  (interactive (list (ggtags-read-tag) current-prefix-arg))
  (if (or definition
          (ggtags-cache-ctags-p (ggtags-root-directory))
          (not buffer-file-name))
      (ggtags-find-tag 'definition name)
    (ggtags-find-tag (format "--from-here=%d:%s"
                             (line-number-at-pos)
                             (shell-quote-argument
                              (file-truename buffer-file-name)))
                     name)))

(defun ggtags-find-reference (name)
  (interactive (list (ggtags-read-tag)))
  (ggtags-find-tag 'reference name))

(defun ggtags-find-other-symbol (name)
  "Find tag NAME wchi is a reference without a definition."
  (interactive (list (ggtags-read-tag)))
  (ggtags-find-tag 'symbol name))

(defun ggtags-read-string (prompt)
  "Like `read-string' but handle default automatically."
  (ggtags-ensure-root-directory)
  (let ((prompt (if (string-match ": *\\'" prompt)
                    (substring prompt 0 (match-beginning 0))
                  prompt))
        (default (thing-at-point 'symbol)))
    (read-string (format (if default "%s (default `%s'): "
                           "%s: ")
                         prompt default)
                 nil nil (and default (substring-no-properties default)))))

(defun ggtags-grep (pattern)
  (interactive (list (ggtags-read-string "Grep pattern")))
  (ggtags-find-tag 'grep (format "--regexp %S" pattern)))

(defun ggtags-idutils-query (pattern)
  (interactive (list (ggtags-read-string "ID query pattern")))
  (ggtags-find-tag 'idutils (format "--regexp %S" pattern)))

;; NOTE: Coloured output in grep requested: http://goo.gl/Y9IcX
(defun ggtags-find-tag-regexp (regexp directory)
  "List tags matching REGEXP in DIRECTORY (default to project root)."
  (interactive
   (list (ggtags-read-string "POSIX regexp")
         (if current-prefix-arg
             (read-directory-name "Directory: " nil nil t)
           (ggtags-root-directory))))
  (ggtags-check-root-directory)
  (let ((root (file-name-as-directory directory))
        (cmd (ggtags-global-build-command
              nil nil "-l" "--regexp" (prin1-to-string regexp))))
    (ggtags-global-start cmd root)))

(defun ggtags-query-replace (from to &optional delimited directory)
  "Query replace FROM with TO on all files in DIRECTORY."
  (interactive
   (append (query-replace-read-args "Query replace (regexp)" t t)
           (list (read-directory-name "In directory: " nil nil t))))
  (let ((default-directory (file-name-as-directory directory)))
    (ggtags-check-root-directory)
    (dolist (file (process-lines "global" "-P" "-l" "."))
      (let ((file (expand-file-name file directory)))
        (when (file-exists-p file)
          (let* ((message-log-max nil)
                 (visited (get-file-buffer file))
                 (buffer (or visited
                             (with-demoted-errors
                               (find-file-noselect file)))))
            (when buffer
              (set-buffer buffer)
              (if (save-excursion
                    (goto-char (point))
                    (re-search-forward from nil t))
                  (progn
                    (switch-to-buffer (current-buffer))
                    (perform-replace from to t t delimited
                                     nil multi-query-replace-map))
                (message "Nothing to do for `%s'" file)
                (or visited (kill-buffer))))))))))

(defun ggtags-delete-tag-files ()
  "Delete the tag files generated by gtags."
  (interactive)
  (when (ggtags-root-directory)
    (let ((files (directory-files (ggtags-root-directory) t
                                  (regexp-opt '("GPATH" "GRTAGS" "GTAGS" "ID"))))
          (buffer "*GTags File List*"))
      (or files (user-error "No tag files found"))
      (with-output-to-temp-buffer buffer
        (dolist (file files)
          (princ file)
          (princ "\n")))
      (let ((win (get-buffer-window buffer)))
        (unwind-protect
            (progn
              (fit-window-to-buffer win)
              (when (yes-or-no-p "Remove GNU Global tag files? ")
                (mapc 'delete-file files)))
          (when (window-live-p win)
            (quit-window t win)))))))

(defvar ggtags-current-mark nil)

(defun ggtags-next-mark (&optional arg)
  "Move to the next (newer) mark in the tag marker ring."
  (interactive)
  (and (zerop (ring-length find-tag-marker-ring))
       (user-error "No %s mark" (if arg "previous" "next")))
  (let ((mark (or (and ggtags-current-mark
                       ;; Note `ring-previous' gets newer item.
                       (funcall (if arg #'ring-next #'ring-previous)
                                find-tag-marker-ring ggtags-current-mark))
                  (prog1
                      (ring-ref find-tag-marker-ring (if arg 0 -1))
                    (ring-insert find-tag-marker-ring (point-marker))))))
    (setq ggtags-current-mark mark)
    (let ((i (- (ring-length find-tag-marker-ring)
                (ring-member find-tag-marker-ring ggtags-current-mark)))
          (message-log-max nil))
      (message "%d%s marker" i (pcase i
                                 (1 "st")
                                 (2 "nd")
                                 (3 "rd")
                                 (_ "th"))))
    (switch-to-buffer (marker-buffer mark))
    (goto-char mark)))

(defun ggtags-prev-mark ()
  "Move to the previous (older) mark in the tag marker ring."
  (interactive)
  (ggtags-next-mark 'previous))

(defvar-local ggtags-global-exit-status nil)

(defun ggtags-global-exit-message-function (_process-status exit-status msg)
  (setq ggtags-global-exit-status exit-status)
  (let ((count (save-excursion
                 (goto-char (point-max))
                 (if (re-search-backward "^\\([0-9]+\\) \\w+ located" nil t)
                     (string-to-number (match-string 1))
                   0))))
    ;; Clear the start marker in case of zero matches.
    (and (zerop count) (setq ggtags-global-start-marker nil))
    (cons (if (> exit-status 0)
              msg
            (format "found %d %s" count (if (= count 1) "match" "matches")))
          exit-status)))

;;; NOTE: Must not match the 'Global started at Mon Jun 3 10:24:13'
;;; line or `compilation-auto-jump' will jump there and fail. See
;;; comments before the 'gnu' entry in
;;; `compilation-error-regexp-alist-alist'.
(defvar ggtags-global-error-regexp-alist-alist
  (append
   '((path "^\\(?:[^/\n]*/\\)?[^ )\t\n]+$" 0)
     ;; ACTIVE_ESCAPE	src/dialog.cc	172
     (ctags "^\\([^ \t\n]+\\)[ \t]+\\(.*?\\)[ \t]+\\([0-9]+\\)$"
            2 3 nil nil 2 (1 font-lock-function-name-face))
     ;; ACTIVE_ESCAPE     172 src/dialog.cc    #undef ACTIVE_ESCAPE
     (ctags-x "^\\([^ \t\n]+\\)[ \t]+\\([0-9]+\\)[ \t]+\\(\\(?:[^/\n]*/\\)?[^ \t\n]+\\)"
              3 2 nil nil 3 (1 font-lock-function-name-face))
     ;; src/dialog.cc:172:#undef ACTIVE_ESCAPE
     (grep "^\\(.+?\\):\\([0-9]+\\):\\(?:[^0-9\n]\\|[0-9][^0-9\n]\\|[0-9][0-9].\\)"
           1 2 nil nil 1)
     ;; src/dialog.cc ACTIVE_ESCAPE 172 #undef ACTIVE_ESCAPE
     (cscope "^\\(.+?\\)[ \t]+\\([^ \t\n]+\\)[ \t]+\\([0-9]+\\).*\\(?:[^0-9\n]\\|[^0-9\n][0-9]\\|[^:\n][0-9][0-9]\\)$"
             1 3 nil nil 1 (2 font-lock-function-name-face)))
   compilation-error-regexp-alist-alist))

(defun ggtags-abbreviate-file (start end)
  (let ((inhibit-read-only t)
        (amount (if (numberp ggtags-global-abbreviate-filename)
                    (- (- end start) ggtags-global-abbreviate-filename)
                  999))
        (advance-word (lambda ()
                        "Return the length of the text made invisible."
                        (let ((wend (min end (progn (forward-word 1) (point))))
                              (wbeg (max start (progn (backward-word 1) (point)))))
                          (goto-char wend)
                          (if (<= (- wend wbeg) 1)
                              0
                            (put-text-property (1+ wbeg) wend 'invisible t)
                            (1- (- wend wbeg)))))))
    (goto-char start)
    (while (and (> amount 0) (> end (point)))
      (decf amount (funcall advance-word)))))

(defun ggtags-abbreviate-files (start end)
  (goto-char start)
  (let* ((error-re (cdr (assq ggtags-global-output-format
                              ggtags-global-error-regexp-alist-alist)))
         (sub (cadr error-re)))
    (when (and ggtags-global-abbreviate-filename error-re)
      (while (re-search-forward (car error-re) end t)
        (when (and (or (not (numberp ggtags-global-abbreviate-filename))
                       (> (length (match-string sub))
                          ggtags-global-abbreviate-filename))
                   ;; Ignore bogus file lines such as:
                   ;;     Global found 2 matches at Thu Jan 31 13:45:19
                   (get-text-property (match-beginning sub) 'compilation-message))
          (ggtags-abbreviate-file (match-beginning sub) (match-end sub)))))))

(defun ggtags-global-filter ()
  "Called from `compilation-filter-hook' (which see)."
  (ansi-color-apply-on-region compilation-filter-start (point)))

(defun ggtags-handle-single-match (buf _how)
  (when (and ggtags-auto-jump-to-first-match
             ;; If exit abnormally keep the window for inspection.
             (zerop ggtags-global-exit-status)
             (save-excursion
               (goto-char (point-min))
               (not (ignore-errors
                      (goto-char (compilation-next-single-property-change
                                  (point) 'compilation-message))
                      (end-of-line)
                      (compilation-next-single-property-change
                       (point) 'compilation-message)))))
    (ggtags-navigation-mode -1)
    ;; 0.5s delay for `ggtags-auto-jump-to-first-match'
    (sit-for 0)                    ; See: http://debbugs.gnu.org/13829
    (ggtags-navigation-mode-cleanup buf 0.5)))

(defvar ggtags-global-mode-font-lock-keywords
  '(("^Global \\(exited abnormally\\|interrupt\\|killed\\|terminated\\)\\(?:.*with code \\([0-9]+\\)\\)?.*"
     (1 'compilation-error)
     (2 'compilation-error nil t))
    ("^Global found \\([0-9]+\\)" (1 compilation-info-face))))

(define-compilation-mode ggtags-global-mode "Global"
  "A mode for showing outputs from gnu global."
  (setq-local compilation-error-regexp-alist
              (list ggtags-global-output-format))
  (setq-local compilation-auto-jump-to-first-error
              ggtags-auto-jump-to-first-match)
  (setq-local compilation-scroll-output 'first-error)
  (setq-local compilation-disable-input t)
  (setq-local compilation-always-kill t)
  (setq-local compilation-error-face 'compilation-info)
  (setq-local compilation-exit-message-function
              'ggtags-global-exit-message-function)
  (setq-local truncate-lines t)
  (jit-lock-register #'ggtags-abbreviate-files)
  (add-hook 'compilation-filter-hook 'ggtags-global-filter nil 'local)
  (add-hook 'compilation-finish-functions 'ggtags-handle-single-match nil t)
  (define-key ggtags-global-mode-map "o" 'visible-mode))

;; NOTE: Need this to avoid putting menu items in
;; `emulation-mode-map-alists', which creates double entries. See
;; http://i.imgur.com/VJJTzVc.png
(defvar ggtags-navigation-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\M-n" 'next-error)
    (define-key map "\M-p" 'previous-error)
    (define-key map "\M-}" 'ggtags-navigation-next-file)
    (define-key map "\M-{" 'ggtags-navigation-previous-file)
    (define-key map "\M->" 'ggtags-navigation-last-error)
    (define-key map "\M-<" 'ggtags-navigation-first-error)
    (define-key map "\M-o" 'ggtags-navigation-visible-mode)
    (define-key map [return] 'ggtags-navigation-mode-done)
    (define-key map "\r" 'ggtags-navigation-mode-done)
    ;; Intercept M-. and M-* keys
    (define-key map [remap pop-tag-mark] 'ggtags-navigation-mode-abort)
    (define-key map [remap ggtags-find-tag] 'undefined)
    map))

(defvar ggtags-navigation-mode-map
  (let ((map (make-sparse-keymap))
        (menu (make-sparse-keymap "GG-Navigation")))
    ;; Menu items: (info "(elisp)Extended Menu Items")
    (define-key map [menu-bar ggtags-navigation] (cons "GG-Navigation" menu))
    ;; Ordered backwards
    (define-key menu [visible-mode]
      '(menu-item "Visible mode" ggtags-navigation-visible-mode
                  :button (:toggle . (ignore-errors
                                       (ggtags-ensure-global-buffer
                                         visible-mode)))))
    (define-key menu [done]
      '(menu-item "Finish navigation" ggtags-navigation-mode-done))
    (define-key menu [abort]
      '(menu-item "Abort" ggtags-navigation-mode-abort))
    (define-key menu [last-error]
      '(menu-item "Last error" ggtags-navigation-last-error))
    (define-key menu [fist-error]
      '(menu-item "Fist error" ggtags-navigation-first-error))
    (define-key menu [previous-file]
      '(menu-item "Previous file" ggtags-navigation-previous-file))
    (define-key menu [next-file]
      '(menu-item "Next file" ggtags-navigation-next-file))
    (define-key menu [previous]
      '(menu-item "Previous match" previous-error))
    (define-key menu [next]
      '(menu-item "Next match" next-error))
    map))

(defun ggtags-move-to-tag (&optional name)
  "Move to NAME tag in current line."
  (let ((orig (point))
        (tag (or name ggtags-current-tag-name)))
    (beginning-of-line)
    (if (and tag (re-search-forward
                  (concat "\\_<" (regexp-quote tag) "\\_>")
                  (line-end-position)
                  t))
        (goto-char (match-beginning 0))
      (goto-char orig))))

(defun ggtags-navigation-mode-cleanup (&optional buf time)
  (let ((buf (or buf compilation-last-buffer)))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (when (get-buffer-process (current-buffer))
             (kill-compilation))
           (when (and (derived-mode-p 'ggtags-global-mode)
                      (get-buffer-window))
             (quit-window nil (get-buffer-window)))
           (and time (run-with-idle-timer time nil 'kill-buffer buf))))))

(defun ggtags-navigation-mode-done ()
  (interactive)
  (ggtags-navigation-mode -1)
  (setq ggtags-current-mark nil)
  (setq tags-loop-scan t
        tags-loop-operate '(ggtags-find-tag-resume))
  (ggtags-navigation-mode-cleanup))

(defun ggtags-navigation-mode-abort ()
  (interactive)
  (ggtags-navigation-mode -1)
  ;; Run after (ggtags-navigation-mode -1) or
  ;; ggtags-global-start-marker might not have been saved.
  (when (and (not (markerp ggtags-global-start-marker))
             ggtags-global-start-marker)
    (setq ggtags-global-start-marker nil)
    (pop-tag-mark))
  (ggtags-navigation-mode-cleanup nil 0))

(defun ggtags-navigation-next-file (n)
  (interactive "p")
  (ggtags-ensure-global-buffer
    (compilation-next-file n)
    (compile-goto-error)))

(defun ggtags-navigation-previous-file (n)
  (interactive "p")
  (ggtags-navigation-next-file (- n)))

(defun ggtags-navigation-first-error ()
  (interactive)
  (ggtags-ensure-global-buffer
    (goto-char (point-min))
    (compilation-next-error 1)
    (compile-goto-error)))

(defun ggtags-navigation-last-error ()
  (interactive)
  (ggtags-ensure-global-buffer
    (goto-char (point-max))
    (compilation-previous-error 1)
    (compile-goto-error)))

(defun ggtags-navigation-visible-mode (&optional arg)
  (interactive (list (or current-prefix-arg 'toggle)))
  (ggtags-ensure-global-buffer
    (visible-mode arg)))

(define-minor-mode ggtags-navigation-mode nil
  :lighter (" GG[" (:propertize "n" face error) "]")
  :global t
  (if ggtags-navigation-mode
      (progn
        (add-hook 'next-error-hook 'ggtags-move-to-tag)
        (add-hook 'next-error-hook 'ggtags-global-save-start-marker)
        (add-hook 'minibuffer-setup-hook 'ggtags-minibuffer-setup-function))
    ;; Call `ggtags-global-save-start-marker' in case of exiting from
    ;; `ggtags-handle-single-match' for single match.
    (ggtags-global-save-start-marker)
    (remove-hook 'next-error-hook 'ggtags-global-save-start-marker)
    (remove-hook 'next-error-hook 'ggtags-move-to-tag)
    (remove-hook 'minibuffer-setup-hook 'ggtags-minibuffer-setup-function)))

(defun ggtags-minibuffer-setup-function ()
  ;; Disable ggtags-navigation-mode in minibuffer.
  (setq-local ggtags-navigation-mode nil))

(defun ggtags-kill-file-buffers (&optional interactive)
  "Kill all buffers visiting files in the root directory."
  (interactive "p")
  (ggtags-check-root-directory)
  (let ((root (ggtags-root-directory))
        (count 0)
        (some (lambda (pred list)
                (loop for x in list when (funcall pred x) return it))))
    (dolist (buf (buffer-list))
      (let ((file (and (buffer-live-p buf)
                       (not (eq buf (current-buffer)))
                       (buffer-file-name buf))))
        (when (and file (funcall some (apply-partially #'file-in-directory-p
                                                       (file-truename file))
                                 (cons root (ggtags-get-libpath))))
          (and (kill-buffer buf)
               (incf count)))))
    (and interactive
         (message "%d %s killed" count (if (= count 1) "buffer" "buffers")))))

(defun ggtags-after-save-function ()
  (let ((root (with-demoted-errors (ggtags-root-directory))))
    (when root
      (ggtags-cache-mark-dirty root t)
      ;; When oversize update on a per-save basis.
      (when (and buffer-file-name (ggtags-oversize-p))
        (ggtags-update-tags 'single-update)))))

(defvar ggtags-tag-overlay nil)
(defvar ggtags-highlight-tag-timer nil)

(defvar ggtags-mode-prefix-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "M-DEL") 'ggtags-delete-tag-files)
    (define-key m "\M-p" 'ggtags-prev-mark)
    (define-key m "\M-n" 'ggtags-next-mark)
    (define-key m "\M-s" 'ggtags-find-other-symbol)
    (define-key m "\M-g" 'ggtags-grep)
    (define-key m "\M-i" 'ggtags-idutils-query)
    (define-key m "\M-k" 'ggtags-kill-file-buffers)
    (define-key m (kbd "M-%") 'ggtags-query-replace)
    m))

(defvar ggtags-mode-map
  (let ((map (make-sparse-keymap))
        (menu (make-sparse-keymap "Ggtags")))
    (define-key map "\M-." 'ggtags-find-tag-dwim)
    (define-key map (kbd "M-]") 'ggtags-find-reference)
    (define-key map (kbd "C-M-.") 'ggtags-find-tag-regexp)
    (define-key map ggtags-mode-prefix-key ggtags-mode-prefix-map)
    ;; Menu items
    (define-key map [menu-bar ggtags] (cons "Ggtags" menu))
    ;; Ordered backwards
    (define-key menu [report-bugs]
      `(menu-item "Report bugs"
                  (lambda () (interactive)
                    (browse-url ggtags-bug-url)
                    (message "Please visit %s" ggtags-bug-url))
                  :help ,(format "Visit %s" ggtags-bug-url)))
    (define-key menu [custom-ggtags]
      '(menu-item "Customize Ggtags"
                  (lambda () (interactive) (customize-group 'ggtags))))
    (define-key menu [sep2] menu-bar-separator)
    (define-key menu [delete-tags]
      '(menu-item "Delete tag files" ggtags-delete-tag-files
                  :enable (ggtags-root-directory)))
    (define-key menu [pop-mark]
      '(menu-item "Pop mark" pop-tag-mark
                  :help "Pop to previous mark and destroy it"))
    (define-key menu [next-mark]
      '(menu-item "Next mark" ggtags-next-mark))
    (define-key menu [prev-mark]
      '(menu-item "Previous mark" ggtags-prev-mark))
    (define-key menu [sep1] menu-bar-separator)
    (define-key menu [query-replace]
      '(menu-item "Query replace" ggtags-query-replace))
    (define-key menu [idutils]
      '(menu-item "Query idutils DB" ggtags-idutils-query))
    (define-key menu [grep]
      '(menu-item "Use grep" ggtags-grep))
    (define-key menu [find-symbol]
      '(menu-item "Find other symbol" ggtags-find-other-symbol))
    (define-key menu [find-reference]
      '(menu-item "Find reference" ggtags-find-reference))
    (define-key menu [find-tag-resume]
      '(menu-item "Resume find tag" tags-loop-continue))
    (define-key menu [find-tag-regexp]
      '(menu-item "Find tag matching regexp" ggtags-find-tag-regexp))
    (define-key menu [find-tag]
      '(menu-item "Find tag" ggtags-find-tag-dwim))
    (define-key menu [run-gtags]
      '(menu-item (if (ggtags-root-directory) "Update tag files" "Run gtags")
                  (lambda () (interactive)
                    (if (ggtags-root-directory)
                        (ggtags-update-tags)
                      (ggtags-ensure-root-directory)))))
    map))

(defun ggtags-mode-update-prefix-key (symbol value)
  (let ((old (and (boundp symbol) (symbol-value symbol))))
    (and old (define-key ggtags-mode-map old nil)))
  (when value
    (define-key ggtags-mode-map value ggtags-mode-prefix-map))
  (set-default symbol value))

;; Set here to avoid initialisation problem for
;; `ggtags-mode-prefix-key'.
(put 'ggtags-mode-prefix-key 'custom-set #'ggtags-mode-update-prefix-key)

;;;###autoload
(define-minor-mode ggtags-mode nil
  :lighter (:eval (if ggtags-navigation-mode "" " GG"))
  (if ggtags-mode
      (progn
        (add-hook 'after-save-hook 'ggtags-after-save-function nil t)
        (or (executable-find "global")
            (message "Failed to find GNU Global")))
    (remove-hook 'after-save-hook 'ggtags-after-save-function t)
    (and (overlayp ggtags-tag-overlay)
         (delete-overlay ggtags-tag-overlay))
    (setq ggtags-tag-overlay nil)))

(defun ggtags-highlight-tag-at-point ()
  (when ggtags-mode
    (unless (overlayp ggtags-tag-overlay)
      (setq ggtags-tag-overlay (make-overlay (point) (point)))
      (overlay-put ggtags-tag-overlay 'ggtags t))
    (let* ((bounds (bounds-of-thing-at-point 'symbol))
           (valid-tag (when bounds
                        (member (buffer-substring (car bounds) (cdr bounds))
                                (ggtags-tag-names (ggtags-oversize-p)))))
           (o ggtags-tag-overlay)
           (done-p (lambda ()
                     (and (memq o (overlays-at (car bounds)))
                          (= (overlay-start o) (car bounds))
                          (= (overlay-end o) (cdr bounds))
                          (or (and valid-tag (overlay-get o 'face))
                              (and (not valid-tag) (not (overlay-get o 'face))))))))
      (cond
       ((not bounds)
        (overlay-put ggtags-tag-overlay 'face nil)
        (move-overlay ggtags-tag-overlay (point) (point) (current-buffer)))
       ((not (funcall done-p))
        (move-overlay o (car bounds) (cdr bounds) (current-buffer))
        (overlay-put o 'face (and valid-tag 'ggtags-highlight)))))))

;;; imenu

(defun ggtags-goto-imenu-index (name line &rest _args)
  (save-restriction
    (widen)
    (goto-char (point-min))
    (forward-line (1- line))
    (ggtags-move-to-tag name)))

;;;###autoload
(defun ggtags-build-imenu-index ()
  "A function suitable for `imenu-create-index-function'."
  (when buffer-file-name
    (let ((file (file-truename buffer-file-name)))
      (with-temp-buffer
        (when (with-demoted-errors
                (zerop (ggtags-with-ctags-maybe
                        (process-file "global" nil t nil "-x" "-f" file))))
          (goto-char (point-min))
          (loop while (re-search-forward
                       "^\\([^ \t]+\\)[ \t]+\\([0-9]+\\)" nil t)
                collect (list (match-string 1)
                              (string-to-number (match-string 2))
                              'ggtags-goto-imenu-index)))))))

;;; hippie-expand

;;;###autoload
(defun try-complete-ggtags-tag (old)
  "A function suitable for `hippie-expand-try-functions-list'."
  (with-no-warnings                     ; to avoid loading hippie-exp
    (unless old
      (he-init-string (if (looking-back "\\_<.*" (line-beginning-position))
                          (match-beginning 0)
                        (point))
                      (point))
      (setq he-expand-list
            (and (not (equal he-search-string ""))
                 (with-demoted-errors (ggtags-root-directory))
                 (sort (all-completions he-search-string
                                        (ggtags-tag-names))
                       'string-lessp))))
    (if (null he-expand-list)
        (progn
          (if old (he-reset-string))
          nil)
      (he-substitute-string (car he-expand-list))
      (setq he-expand-list (cdr he-expand-list))
      t)))

;;; Finish up

(when ggtags-highlight-tag-timer
  (cancel-timer ggtags-highlight-tag-timer))

(setq ggtags-highlight-tag-timer
      (run-with-idle-timer 0.2 t 'ggtags-highlight-tag-at-point))

;; Higher priority for `ggtags-navigation-mode' to avoid being
;; hijacked by modes such as `view-mode'.
(defvar ggtags-mode-map-alist
  `((ggtags-navigation-mode . ,ggtags-navigation-map)))

(add-to-list 'emulation-mode-map-alists 'ggtags-mode-map-alist)

(provide 'ggtags)
;;; ggtags.el ends here