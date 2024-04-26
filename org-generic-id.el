;;; org-generic-id.el --- Global identifiers for Org entries -*- lexical-binding: t; -*-
;;
;; Author: Robert Irelan <rirelan at gmail dot com>
;; Homepage: https://orgmode.org
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:

;; This file generalizes ‘org-id' to allow using any property, not just :ID:,
;; to locate Org-mode entries. This library only handles storing IDs in entries,
;; locating entries with a given ID, and storing a map of IDs to files
;; containing such IDs. Generation of IDs must be handled by the user of the
;; library - unlike ‘org-id', no functions are provided to automatically
;; generate IDs.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'org)
(require 'persist)

(declare-function message-make-fqdn "message" ())
(declare-function org-goto-location "org-goto" (&optional _buf help))

;;; Customization

(defgroup org-generic-id nil
  "Options concerning global entry identifiers in Org mode."
  :tag "Org ID"
  :group 'org)

(defcustom org-generic-id-locations-file (convert-standard-filename
                                          (concat user-emacs-directory ".org-generic-id-locations"))
  "The file for remembering in which file an ID was defined."
  :group 'org-generic-id
  :type 'file)

(defcustom org-generic-id-locations-file-relative nil
  "Determines if org-generic-id-locations should be stored as relative links.
Non-nil means that links to locations are stored as links
relative to the location of where `org-generic-id-locations-file' is
stored.

Nil means to store absolute paths to files.

This customization is useful when folders are shared across
systems but mounted at different roots.  Relative path to
`org-generic-id-locations-file' still has to be maintained across
systems."
  :group 'org-generic-id
  :type 'boolean)

(defun org-generic-id--make-hash-table (&rest args)
  "Make hash table with ‘equal’ test and optional other ARGS."
  (apply #'make-hash-table :test #'equal args))

(defvar org-generic-id-locations (org-generic-id--make-hash-table)
  "Hashtable storing map of ID names to IDs to file containing them.

Example structure:

#s(hash-table size 31 test equal rehash-size 1.5 rehash-threshold 0.8125 data
              (\"entry-id\"
                #s(hash-table size 2 test equal rehash-size 1.5
                              rehash-threshold 0.8125 data
                                        (\"entry-id-1\" \"file1.org\"
                                         \"entry-id-2\" \"file2.org\")))
              (\"other-id\"
                #s(hash-table size 2 test equal rehash-size 1.5
                              rehash-threshold 0.8125 data
                                        (\"other-id-1\" \"file3.org\"
                                         \"other-id-2\" \"file4.org\"))))
")

(defvar org-generic-id--files
  (org-generic-id--make-hash-table :weakness 'value)
  "Hashtable mapping file names to buffers visiting the files.

The keys are file names - multiple keys may refer to the same buffer.  The
values are as follows:

- buffer: list containing the buffer corresponding to the file
- nil: list containing nil, signifying that the file has been determined to not
         be visited by a buffer
- `unknown’: when the buffer for a file has not been determined.

The table has weak values so that it does not cause buffers to be retained when
they would otherwise be garbage collected (after being killed, for example).")

(defun org-generic-id-files ()
  "Return a list of all files known to have IDs."
  (let ((tmp (org-generic-id--make-hash-table))
        res)
    (maphash
     (lambda (_id-name id-hash)
       (maphash
        (lambda (_id file)
          (puthash file t tmp))
        id-hash))
     org-generic-id-locations)
    (maphash
     (lambda (file _v) (push file res))
     tmp)
    res))

(persist-defvar
  org-generic-id--last-update-id-time nil
  "Time at which ‘org-generic-id-update-id-locations’ last completed.

This is a plist mapping each ID-PROP to the last time that ID-PROP was updated.
For documentation on ID-PROP see ‘org-generic-id-find’.")

(defcustom org-generic-id-extra-files 'org-agenda-text-search-extra-files
  "Files to be searched for IDs, besides the agenda files.
When Org reparses files to remake the list of files and IDs it is tracking,
it will normally scan the agenda files, the archives related to agenda files,
any files that are listed as ID containing in the current register, and
any Org file currently visited by Emacs.
You can list additional files here."
  :group 'org-generic-id
  :type
  '(choice
    (symbol :tag "Variable")
    (repeat :tag "List of files"
            (file))))

(defcustom org-generic-id-search-archives t
  "Non-nil means search also the archive files of agenda files for entries.
This is a possibility to reduce overhead, but it means that entries moved
to the archives can no longer be found by ID."
  :group 'org-generic-id
  :type 'boolean)

;;; The API functions

;;;###autoload
(defun org-generic-id-get (&optional id-prop pom)
  "Get the ID-PROP property of the entry at point-or-marker POM.
If POM is nil, refer to the entry at point.
If the entry does not have an ID, the function returns nil.
In any case, the ID of the entry is returned."
  (org-with-point-at pom
    (let ((id (org-entry-get nil id-prop)))
      (cond
       ((and id (stringp id) (string-match "\\S-" id))
        id)
       (t nil)))))

;;;###autoload
(defun org-generic-id-find (id-prop id &optional markerp cached no-fallback)
  "Return the location of the entry with property ID-PROP, value ID.
The return value is a cons cell (file-name . position), or nil
if there is no entry with that ID.
With optional argument MARKERP, return the position as a new marker.

Normally, if an entry with ID is not found, this function will run
‘org-generic-id-update-id-locations' in order to pick up any updates to the
files, and then search again, before concluding an ID can’t be found. If
CACHED is passed, that function will not be run.

Normally the ID will be searched for in the current buffer before updating ID
locations. This behavior can be disabled with NO-FALLBACK."
  (cond
   ((symbolp id) (setq id (symbol-name id)))
   ((numberp id) (setq id (number-to-string id))))
  (let ((file (org-generic-id-find-id-file id-prop id no-fallback))
        org-agenda-new-buffers where)
    (when file
      (setq where (org-generic-id-find-id-in-file id-prop id file markerp)))
    (unless (or where cached)
      (org-generic-id-update-id-locations id-prop nil t)
      (setq file (org-generic-id-find-id-file id-prop id no-fallback))
      (when file
        (setq where (org-generic-id-find-id-in-file
                     id-prop id file markerp))))
    where))

;;; Internal functions

;; Storing ID locations (files)

;;;###autoload
(defun org-generic-id-update-id-locations (id-prop &optional files silent)
  "Scan relevant files for IDs.
Store the relation between files and corresponding IDs.
This will scan all agenda files, all associated archives, and all
files currently mentioned in `org-generic-id-locations'.
When FILES is given, scan also these files."
  (interactive "sID Property: ")
  (let* ((files
          (delete-dups
           (mapcar #'abbreviate-file-name
                   (cl-remove-if-not
                    ;; Default `org-generic-id-extra-files' value contains
                    ;; `agenda-archives' symbol.
                    #'stringp
                    (append
                     ;; Agenda files and all associated archives.
                     (org-agenda-files t org-generic-id-search-archives)
                     ;; Explicit extra files.
                     (if (symbolp org-generic-id-extra-files)
                         (symbol-value org-generic-id-extra-files)
                       org-generic-id-extra-files)
                     ;; All files known to have IDs.
                     (org-generic-id-files)
                     ;; Additional files from function call.
                     files)))))
         (nfiles (length files))
         (id-regexp
          (rx-to-string `(seq bol (0+ (any "\t "))
                          ,(format ":%s:" id-prop)
                          (1+ " ") (not (any " ")))))
         (seen-ids nil)
         (ndup 0)
         (i 0))
    (unless (gethash id-prop org-generic-id-locations)
      (puthash id-prop (org-generic-id--make-hash-table) org-generic-id-locations))
    (with-temp-buffer
      (delay-mode-hooks
        (org-mode)
        (dolist (file files)
          (condition-case err
              (when-let
                  ((file
                    (car-safe
                     (org-generic-id-files-modified-since-modtime
                      (org-generic-id--last-update-id-time-get id-prop)
                      (list file)
                      org-generic-id--files))))
                (unless silent
                  (cl-incf i)
                  (message "Finding :%s: locations (%d/%d files): %s"
                           id-prop i nfiles file))
                (goto-char (point-min))
                (let ((buf
                       (org-generic-id--get-file-to-buf
                        org-generic-id--files file)))
                  (save-excursion
                    (if buf
                        (set-buffer buf)
                      (insert-file-contents file nil nil nil 'replace))
                    (save-restriction
                      (widen)
                      (goto-char (point-min))
                      (let ((ids nil)
                            (case-fold-search t))
                        (while (re-search-forward id-regexp nil t)
                          (when (org-at-property-p)
                            (push (org-entry-get (point) id-prop) ids)))
                        (dolist (id ids)
                          (cond
                           ((not (member id seen-ids))
                            (push id seen-ids)
                            (puthash id file (gethash id-prop org-generic-id-locations)))
                           (silent nil)
                           (t
                            (message "Duplicate :%s: property %S" id-prop id)
                            (cl-incf ndup)))))))))
            (file-error
             (warn "org-generic-id-update-id-locations: file “%s”: %S"
                   file err))))))
    ;; Save the new locations and reload to regenerate variables.
    (org-generic-id-locations-save)
    (org-generic-id-locations-load)
    (org-generic-id--last-update-id-time-put id-prop (current-time))
    (when (and (not silent) (> ndup 0))
      (warn
       "WARNING: %d duplicate :%s: properties found, check *Messages* buffer"
       ndup id-prop))
    (message "%d files scanned, and %d :%s: IDs found."
             nfiles
             (hash-table-count (gethash id-prop org-generic-id-locations))
             id-prop)
    org-generic-id-locations))

(defun org-generic-id-locations-save ()
  "Save `org-generic-id-locations' in `org-generic-id-locations-file'."
  (when (and org-generic-id-locations)
    (let ((out (if (hash-table-p org-generic-id-locations)
                   (org-generic-id--locations-hash-to-alist
                    org-generic-id-locations)
                 org-generic-id-locations)))
      (when (and org-generic-id-locations-file-relative out)
        (setq out (mapcar
                   (lambda (item)
                     (if (file-name-absolute-p (car item))
                         (cons (file-relative-name
                                (car item) (file-name-directory
                                            org-generic-id-locations-file))
                               (cdr item))
                       item))
                   out)))
      (with-temp-file org-generic-id-locations-file
        (let ((print-level nil)
              (print-length nil))
          (pp out (current-buffer)))))))

;;;###autoload
(defun org-generic-id-locations-load ()
  "Read the data from `org-generic-id-locations-file'."
  (setq org-generic-id-locations nil)
  (with-temp-buffer
    (condition-case nil
        (progn
          (insert-file-contents org-generic-id-locations-file)
          (setq org-generic-id-locations (read (current-buffer)))
          (let ((loc (file-name-directory org-generic-id-locations-file)))
            (mapc (lambda (id-item)
                    (mapc
                     (lambda (item)
                       (unless (file-name-absolute-p (car item))
                         (setf (car item) (expand-file-name (car item) loc))))
                     (cdr id-item)))
                  org-generic-id-locations)))
      (error
       (message "Could not read org-generic-id-values from %s.  Setting it to nil."
                org-generic-id-locations-file))))
  (setq org-generic-id-locations (org-generic-id--locations-alist-to-hash org-generic-id-locations)))

;;;###autoload
(defun org-generic-id-add-location (id-prop id file)
  "Add the ID with location FILE to the database of ID locations."
  ;; Only when the buffer has a file
  (unless file
    (error "bug: ‘org-generic-id-add-locations' expects a file-visiting buffer"))
  (let ((afile (abbreviate-file-name file)))
    (when id
      (let ((id-prop-hash (gethash id-prop org-generic-id-locations
                                   (org-generic-id--make-hash-table))))
        (puthash id-prop id-prop-hash org-generic-id-locations)
        (puthash id afile id-prop-hash))
      (when (eq 'unknown (gethash afile org-generic-id--files 'unknown))
        (puthash afile (find-buffer-visiting afile) org-generic-id--files)))))

(unless noninteractive
  (add-hook 'kill-emacs-hook 'org-generic-id-locations-save))

(defun org-generic-id--locations-hash-to-alist (hash)
  "Turn an org-generic-id hash into an alist, so it can be written to a file."
  (let (res)
    (maphash
     (lambda (k v)
       (let ((v (org-generic-id--hash-to-alist v)))
         (setf (alist-get k res) v)))
     hash)
    (setq res (sort res (lambda (x y) (string< (car x) (car y)))))
    res))

(defun org-generic-id--hash-to-alist (hash)
  "Turn a hash into an alist while reversing keys and values.

Create an alist with each key being the distinct values in the original hash,
and each value a list of all original hash keys that map to the key of the
alist. For example, a hash

    {’id1’: ’file1’, ’id2’: ’file2’, ’id3’: ’file1’}

is turned into an alist like this:

    ((’file1’ . (’id1’ ’id3’)) (’file2’ . (’id2’)))"
  (let (res x)
    (maphash
     (lambda (k v)
       (if (setq x (assoc v res))
           (setcdr x (cons k (cdr x)))
         (push (list v k) res)))
     hash)
    (mapc (lambda (x)
            (setcdr x (sort (cdr x) #'string<)))
          res)
    (setq res (sort res (lambda (x y) (string< (car x) (car y)))))
    res))

(defun org-generic-id--locations-alist-to-hash (list)
  "Turn an org-generic-id location list into a hash table."
  (let ((res (org-generic-id--make-hash-table
              :size (apply '+ (mapcar 'length list)))))
    (mapc
     (lambda (x)
       (puthash (car x) (org-generic-id--alist-to-hash (cdr x)) res))
     list)
    res))

(defun org-generic-id--alist-to-hash (list)
  "Reverse the transformation made in ‘org-generic-id--hash-to-alist’."
  (let ((res (org-generic-id--make-hash-table
              :size (apply '+ (mapcar 'length list))))
        f)
    (mapc
     (lambda (x)
       (setq f (car x))
       (mapc (lambda (i) (puthash i f res)) (cdr x)))
     list)
    res))

;; Finding entries with specified id

;;;###autoload
(defun org-generic-id-find-id-file (id-prop id &optional no-fallback)
  "Query the id database for the file in which this ID is located.

If NO-FALLBACK is set, don’t fall back to current buffer if not found in
‘org-generic-id-locations’."
  (or (and org-generic-id-locations
           (hash-table-p org-generic-id-locations)
           ;; Guard for errors in the ‘gethash’ call after this
           (gethash id-prop org-generic-id-locations)
           (gethash id
                    (gethash id-prop org-generic-id-locations)))
      ;; Fall back on current buffer
      (and (not no-fallback)
           (buffer-file-name (or (buffer-base-buffer (current-buffer))
                                 (current-buffer))))))

(defun org-generic-id-find-id-in-file (id-prop id file &optional markerp)
  "Return the position of the entry ID in FILE.

If that files does not exist, or if it does not contain this ID,
return nil.

The position is returned as a cons cell (file-name . position).  With
optional argument MARKERP, return the position as a new marker."
  (cond
   ((not file) nil)
   ((not (file-exists-p file)) nil)
   (t
    (let* ((visiting (find-buffer-visiting file))
           (buffer (or visiting (find-file-noselect file))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((pos (org-with-wide-buffer (org-find-property id-prop id))))
              (cond
               ((null pos) nil)
               (markerp (move-marker (make-marker) pos buffer))
               (t (cons file pos)))))
        ;; Remove opened buffer in the process.
        (unless (or visiting markerp) (kill-buffer buffer)))))))

(cl-defun org-generic-id-files-modified-since-modtime (modtime files &optional file-to-buf)
  "Return all files modified since a certain time.
MODTIME is a timestamp of the format returned by ‘current-time’.
of filenames that should be checked.

Each filename’s modtime is checked as follows:

- If there is no buffer visiting the file, the modtime is read from the file
  system and checked against MODTIME.
- If the buffer visiting the file is marked modified, it is always considered
  modified.
- Otherwise, the modtime is read using ‘visited-file-modtime’ from the buffer
  visiting the file.

FILE-TO-BUF, if present, is a hashtable mapping file names to either the buffer
visiting that file, or nil if it’s known that no file is visiting the buffer.
See ‘org-generic-id--files' for more information about the format."
  (if (null modtime)
      files
    (cl-loop for file in files
             when (file-exists-p file)
             if
             (let* ((buf (org-generic-id--get-file-to-buf file-to-buf file)))
               (cond
                ((null buf)
                 (time-less-p modtime
                              (file-attribute-modification-time
                               (file-attributes file))))
                ((buffer-modified-p buf) t)
                (t
                 (time-less-p modtime
                              (with-current-buffer buf
                                (visited-file-modtime))))))
             collect file)))

(defun org-generic-id--get-file-to-buf (file-to-buf file)
  "Get buffer visiting FILE, or nil if no such buffer.

If FILE or ‘(abbreviate-file-name FILE)’ is present in FILE-TO-BUF, use that.
Otherwise, find the buffer visiting FILE if any, and cache the result in
FILE-TO-BUF, whose format is documented at ‘org-generic-id--files’."
  (let ((b (gethash file file-to-buf 'unknown)))
    (if (not (eq 'unknown b))
        b
      (let* ((tmp (or (get-file-buffer file) (find-buffer-visiting file)))
             (buf (when tmp (if-let ((base (buffer-base-buffer tmp))) base tmp))))
        (org-generic-id--files-buffer-hook-impl
         file-to-buf file buf)
        buf))))

(defun org-generic-id--last-update-id-time-get (id-prop)
  "Get last update ID time for ID-PROP.
ID-PROP is a string.  This function converts ID-PROP to a symbol in order to
query ‘org-generic-id--last-update-id-time' using ‘plist-get’."
  (plist-get org-generic-id--last-update-id-time (intern id-prop)))

(defun org-generic-id--last-update-id-time-put (id-prop time)
  "Set last update ID time for ID-PROP to TIME.
ID-PROP is a string; TIME is an Emacs time value as returned by ‘encode-time’.
This function converts ID-PROP to a symbol in order to query
‘org-generic-id--last-update-id-time' using ‘plist-put’."
  ;; Work around the fact that ‘plist-put’ does nothing if the plist is nil,
  ;; since a nil list can’t be mutated in place.
  (if org-generic-id--last-update-id-time
      (plist-put org-generic-id--last-update-id-time
                 (intern id-prop) time)
    (setq org-generic-id--last-update-id-time
          (list (intern id-prop) time))))

(defun org-generic-id--files-find-file-hook ()
  "Update ‘org-generic-id--files’ after a file is loaded."
  (org-generic-id--files-buffer-hook-impl
   org-generic-id--files (buffer-file-name) (current-buffer)))

(defun org-generic-id--files-kill-buffer-hook ()
  "Update ‘org-generic-id--files’ after a buffer is killed."
  (org-generic-id--files-buffer-hook-impl
   org-generic-id--files (buffer-file-name) nil))

(defun org-generic-id--files-buffer-hook-impl (file-to-buf fname buf)
  "Update FILE-TO-BUF to associate FNAME with BUF.
FILE-TO-BUF has a format like ‘org-generic-id--files’."
  (when fname
    (let ((true-fname (abbreviate-file-name fname)))
      (puthash fname buf file-to-buf)
      (when (not (equal fname true-fname))
        (puthash true-fname buf file-to-buf)))))

(add-hook 'find-file-hook #'org-generic-id--files-find-file-hook)
(add-hook 'kill-buffer-hook #'org-generic-id--files-kill-buffer-hook)


(unless (featurep 'org-generic-id)
  (unless org-generic-id-locations
    (message "Loading org-generic-id-locations on first load.")
    (org-generic-id-locations-load)))

(provide 'org-generic-id)

;;; org-generic-id.el ends here
