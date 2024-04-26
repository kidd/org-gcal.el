;;; test-helper.el --- Helpers for org-gcal.el-test.el
(defun my-ert-runner-print-test-name (_stats test)
  (message "ert-runner: now running test %s\n"
           (ert-test-name test)))
(when (boundp 'ert-runner-reporter-test-started-functions)
  (add-to-list 'ert-runner-reporter-test-started-functions
               'my-ert-runner-print-test-name))
;;; test-helper.el ends here
