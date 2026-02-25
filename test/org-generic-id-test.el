;;; org-generic-id-test.el --- Tests for org-generic-id.el -*- lexical-binding: t -*-

(require 'org-generic-id)
(require 'cl-lib)
(require 'el-mock)

(ert-deftest org-generic-id--round-trip ()
  "Verify that ‘org-generic-id-locations-save’ and
‘org-generic-id-locations-load' round-trip."
  (let* ((org-generic-id-locations-file
          (make-temp-file "org-generic-id-locations."))
         (org-generic-id-locations-alist
          '(("ID"
             ("/tmp/bar" "id1" "id2" "id3")
             ("/tmp/foo" "fid"))
            ("SN"
             ("/tmp/bar" "sn1" "sna"))))
         (org-generic-id-locations
          (org-generic-id--locations-alist-to-hash
           org-generic-id-locations-alist)))
    (org-generic-id-locations-save)
    (org-generic-id-locations-load)
    (should (equal (org-generic-id--locations-hash-to-alist
                    org-generic-id-locations)
                   org-generic-id-locations-alist))))

(ert-deftest org-generic-id--find ()
  "Verify ‘org-generic-id-find’.
‘org-generic-id-locations-load' round-trip."
  (let* ((org-generic-id-locations-file
          (make-temp-file "org-generic-id-locations."))
         (org-file
          ;; When I rescan ID locations, the symlink "/var" is resolved to
          ;; "/private/var" on macOS. The simplest way to fix this is just to
          ;; resolve the symlink manually at the start.
          (abbreviate-file-name (file-truename (make-temp-file "my.org."))))
         (org-agenda-files (list org-file))
         (org-generic-id-extra-files nil))
    ;; Reset various variables by saving and reloading.
    (org-generic-id-locations-save)
    (org-generic-id-locations-load)
    ;; We run the test in a temp buffer because ‘org-generic-id-find’ will by
    ;; default search for the ID in the current buffer if it’s not found in
    ;; ‘org-generic-id-locations’.  We want to exercise the ID search/update, so
    ;; we don’t want to fall back to the current buffer.  We thus need to switch
    ;; buffer to ‘org-file’ to update it.
    (with-temp-buffer
      (with-current-buffer (find-file-noselect org-file)
        (org-mode)
        (insert "\
* id1
:PROPERTIES:
:ID: id1
:SN: sn1
:END:"))
      (org-generic-id-update-id-locations "ID")
      (org-generic-id-update-id-locations "SN")
      ;; Round trip variables
      (org-generic-id-locations-save)
      (org-generic-id-locations-load)
      (let (m)
        (setq m (org-generic-id-find-id-in-file
                 "ID" "id1" org-file))
        (should (equal m
                       `(,org-file . 1)))
        (setq m (org-generic-id-find "ID" "id1"))
        (should (equal m
                       `(,org-file . 1)))
        (with-current-buffer (get-file-buffer org-file)
          (goto-char (point-max))
          (insert "
* id2
:PROPERTIES:
:ID: id2
:END:"))
        (setq m (org-generic-id-find "ID" "id2" nil t t))
        (should (equal m nil))
        (setq m (org-generic-id-find "ID" "id2"))
        (should (equal m
                       `(,org-file . 44)))

        (setq m (org-generic-id-find-id-in-file
                 "SN" "sn1" org-file))
        (should (equal m
                       `(,org-file . 1)))
        (setq m (org-generic-id-find "SN" "sn1"))
        (should (equal m
                       `(,org-file . 1)))
        (with-current-buffer (get-file-buffer org-file)
          (goto-char (point-max))
          (insert "
* sn2
:PROPERTIES:
:SN: sn2
:END:"))
        (setq m (org-generic-id-find "SN" "sn2" nil t t))
        (should (equal m nil))
        (setq m (org-generic-id-find "SN" "sn2"))
        (should (equal m
                       `(,org-file . 78)))))))
