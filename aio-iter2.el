;;; aio-iter2.el --- Reimplement aio using iter2 -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Author: Robert Irelan <rirelan@gmail.com>, Christopher Wellons <wellons@nullprogram.com>
;; URL: https://github.com/telotortium/emacs-aio-iter2.el
;; Version: 1.0
;;
;; Keep in sync with org-gcal-pkg.el.
;; Package-Requires: ((emacs "26.1") (aio "1.0") (iter2 "1.0"))

;;; Commentary:

;; `aio-iter2` provides new versions of the `aio-lambda`, `aio-defun`, and `aio-with-async`
;; macros that are defined using `iter2-lambda` instead of `iter-lambda`, in order to
;; obtain the benefits of `iter2-lambda` in `aio`-using code.

;;; Code:

(require 'cl-lib)
(require 'font-lock)
(require 'generator)
(require 'iter2)
(require 'aio)
(require 'rx)

(defmacro aio-iter2-lambda (arglist &rest body)
  "Like `lambda', but define an async function.

ARGLIST and BODY are as in ‘lambda’.  The body of this function may use
`aio-await' to wait on promises.  When an async function is called, it
immediately returns a promise that will resolve to the function's return value,
or any uncaught error signal.

Replacement of `aio-lambda` that uses `iter2-lambda` instead
of `iter-lambda`."
  (declare (indent defun)
           (doc-string 3)
           (debug (&define lambda-list lambda-doc
                           [&optional ("interactive" interactive)]
                           &rest sexp)))
  (let ((args (make-symbol "args"))
        (promise (make-symbol "promise"))
        (split-body (macroexp-parse-body body)))
    `(lambda (&rest ,args)
       ,@(car split-body)
       (let* ((,promise (aio-promise))
              (iter (apply (iter2-lambda ,arglist
                             (aio-with-promise ,promise
                               ,@(cdr split-body)))
                           ,args)))
         (prog1 ,promise
           (aio--step iter ,promise nil))))))

(defmacro aio-iter2-defun (name arglist &rest body)
  "Like `aio-iter2-lambda' but gives the function a name like `defun'.
NAME, ARGLIST, and BODY are as in ‘defun’."
  (declare (indent defun)
           (doc-string 3)
           (debug (&define name lambda-list &rest sexp)))
  `(progn
     (defalias ',name (aio-iter2-lambda ,arglist ,@body))
     (function-put ',name 'aio-defun-p t)
     ;; Evaluates to the name of the function, like ‘defun’.
     ',name))

(defmacro aio-iter2-with-async (&rest body)
  "Evaluate BODY asynchronously as if it was inside `aio-iter2-lambda'.

Since BODY is evalued inside an asynchronous lambda, `aio-await'
is available here.  This macro evaluates to a promise for BODY's
eventual result.

Beware: Dynamic bindings that are lexically outside
‘aio-iter2-with-async’ blocks have no effect.  For example,

  (defvar dynamic-var nil)
  (defun my-func ()
    (let ((dynamic-var 123))
      (aio-iter2-with-async dynamic-var)))
  (let ((dynamic-var 456))
    (aio-wait-for (my-func)))
  ⇒ 456

Other global state such as the current buffer behaves likewise."
  (declare (indent 0)
           (debug (&rest sexp)))
  `(let ((promise (funcall (aio-iter2-lambda ()
                             (aio-await (aio-sleep 0))
                             ,@body))))
     (prog1 promise
       ;; The is the main feature: Force the final result to be
       ;; realized so that errors are reported.
       (aio-listen promise #'funcall))))

;; `emacs-lisp-mode' font lock

(font-lock-add-keywords
 'emacs-lisp-mode
 `((,(rx "(aio-iter2-defun" (+ blank)
         (group (+ (or (syntax word) (syntax symbol)))))
    1 'font-lock-function-name-face)))

(provide 'aio-iter2)

;;; aio-iter2.el ends here
