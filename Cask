(source melpa)
(source gnu)

(depends-on "oauth2-auto"
            ;; Currently waiting for https://github.com/rhaps0dy/emacs-oauth2-auto/pull/1
            ;; to be merged.
            ;:git "https://github.com/rhaps0dy/emacs-oauth2-auto"
            :git "https://github.com/telotortium/emacs-oauth2-auto"
            :branch "main")
(package-descriptor "org-gcal-pkg.el")

(files :defaults)

(development
  (depends-on "el-mock")
  (depends-on "ert-runner")
  (depends-on "load-relative"))
