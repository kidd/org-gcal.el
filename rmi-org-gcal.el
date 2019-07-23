;;; rmi-org-gcal.el --- Org sync with Google Calendar -*- lexical-binding: t -*-

;; Author: myuhe <yuhei.maeda_at_gmail.com>
;; URL: https://github.com/kidd/org-gcal.el
;; Version: 0.3
;; Maintainer: Raimon Grau <raimonster@gmail.com>
;; Copyright (C) :2014 myuhe all rights reserved.
;; Package-Requires: ((request-deferred "0.2.0") (alert "1.1") (emacs "24") (cl-lib "0.5") (org "8.2.4"))
;; Keywords: convenience,

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published byn
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING. If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 0:110-1301, USA.

;;; Commentary:
;;
;; Put the rmi-org-gcal.el to your
;; load-path.
;; Add to .emacs:
;; (require 'rmi-org-gcal)
;;
;;; Changelog:
;; 2014-01-03 Initial release.

(require 'alert)
(require 'json)
(require 'request-deferred)
(require 'org-element)
(require 'org-archive)
(require 'cl-lib)

;; Customization
;;; Code:

(defgroup rmi-org-gcal nil "Org sync with Google Calendar"
  :tag "Org google calendar"
  :group 'org)

(defcustom rmi-org-gcal-up-days 30
  "Number of days to get events before today."
  :group 'rmi-org-gcal
  :type 'integer)

(defcustom rmi-org-gcal-down-days 60
  "Number of days to get events after today."
  :group 'rmi-org-gcal
  :type 'integer)

(defcustom rmi-org-gcal-auto-archive t
  "If non-nil, old events archive automatically."
  :group 'rmi-org-gcal
  :type 'boolean)

(defcustom rmi-org-gcal-dir
  (concat user-emacs-directory "rmi-org-gcal/")
  "File in which to save token."
  :group 'rmi-org-gcal
  :type 'string)

(defcustom rmi-org-gcal-token-file
  (expand-file-name ".rmi-org-gcal-token" rmi-org-gcal-dir)
  "File in which to save token."
  :group 'rmi-org-gcal
  :type 'string)

(defcustom rmi-org-gcal-client-id nil
  "Client ID for OAuth."
  :group 'rmi-org-gcal
  :type 'string)

(defcustom rmi-org-gcal-client-secret nil
  "Google calendar secret key for OAuth."
  :group 'rmi-org-gcal
  :type 'string)

(defcustom rmi-org-gcal-file-alist nil
  "List of association '(calendar-id file) to synchronize at once for calendar id."
  :group 'rmi-org-gcal
  :type '(alist :key-type (string :tag "Calendar Id") :value-type (file :tag "Org file")))

(defcustom rmi-org-gcal-logo-file nil
  "Org-gcal logo image filename to display in notifications."
  :group 'rmi-org-gcal
  :type 'file)

(defcustom rmi-org-gcal-fetch-event-filters '()
  "Predicate functions to filter calendar events.
Predicate functions take an event, and if they return nil the
   event will not be fetched."
  :group 'rmi-org-gcal
  :type 'list)

(defcustom rmi-org-gcal-notify-p t
  "If nil no more alert messages are shown for status updates."
  :group 'rmi-org-gcal
  :type 'boolean)

(defcustom rmi-org-gcal-header-alist ()
  "\
Association list of '(calendar-id header). For each calendar-id present in this
list, the associated header will be inserted at the top of the file associated
with the calendar-id in rmi-org-gcal-file-alist, before any calendar entries.

This is intended to set headers in the org-mode files maintained by rmi-org-gcal to
control categories, archive locations, and other local variables."
  :group 'rmi-org-gcal
  :type '(alist :key-type (string :tag "Calendar Id") :value-type (string :tag "Header")))

(defcustom rmi-org-gcal-property "org-gcal"
  "\
Org-mode property to be set on all entries that should be handled by rmi-org-gcal."
  :group 'rmi-org-gcal
  :type 'string)

(defcustom rmi-org-gcal-calendar-id-property "calendar-id"
  "\
Org-mode property on org-gcal entries that records the Calendar ID."
  :group 'rmi-org-gcal
  :type 'string)

(defcustom rmi-org-gcal-etag-property "ETag"
  "\
Org-mode property on org-gcal entries that records the ETag."
  :group 'rmi-org-gcal
  :type 'string)

(defvar rmi-org-gcal-token-plist nil
  "Token plist.")

(defconst rmi-org-gcal-auth-url "https://accounts.google.com/o/oauth2/auth"
  "Google OAuth2 server URL.")

(defconst rmi-org-gcal-token-url "https://www.googleapis.com/oauth2/v3/token"
  "Google OAuth2 server URL.")

(defconst rmi-org-gcal-resource-url "https://www.googleapis.com/auth/calendar"
  "URL used to request access to calendar resources.")

(defconst rmi-org-gcal-events-url "https://www.googleapis.com/calendar/v3/calendars/%s/events")

;;;###autoload
(defun rmi-org-gcal-sync (&optional a-token skip-export silent)
  "Import events from calendars.
Using A-TOKEN and export the ones to the calendar if unless
SKIP-EXPORT.  Set SILENT to non-nil to inhibit notifications."
  (interactive)
  (rmi-org-gcal--ensure-token)
  (when rmi-org-gcal-auto-archive
    (dolist (i rmi-org-gcal-file-alist)
      (with-current-buffer
          (find-file-noselect (cdr i))
        (rmi-org-gcal--archive-old-event))))
  (cl-loop for x in rmi-org-gcal-file-alist
           do
           (let ((x x)
                 (a-token (if a-token
                              a-token
                            (rmi-org-gcal--get-access-token)))

                 (skip-export skip-export)
                 (silent silent))
             (deferred:$
               (request-deferred
                (format rmi-org-gcal-events-url (car x))
                :type "GET"
                :params `(("access_token" . ,a-token)
                          ("key" . ,rmi-org-gcal-client-secret)
                          ("singleEvents" . "True")
                          ("orderBy" . "startTime")
                          ("timeMin" . ,(rmi-org-gcal--subtract-time))
                          ("timeMax" . ,(rmi-org-gcal--add-time))
                          ("grant_type" . "authorization_code"))
                :parser 'rmi-org-gcal--json-read
                :error
                (cl-function (lambda (&key error-thrown &allow-other-keys)
                               (message "Got error: %S" error-thrown))))
               (deferred:nextc it
                 (lambda (response)
                   (let
                       ((temp (request-response-data response))
                        (status (request-response-status-code response))
                        (error-msg (request-response-error-thrown response)))
                     (cond
                      ;; If there is no network connectivity, the response will
                      ;; not include a status code.
                      ((eq status nil)
                       (rmi-org-gcal--notify
                        "Got Error"
                        "Could not contact remote service. Please check your network connectivity."))
                      ;; Receiving a 403 response could mean that the calendar
                      ;; API has not been enabled. When the user goes and
                      ;; enables it, a new token will need to be generated. This
                      ;; takes care of that step.
                      ((eq 401 (or (plist-get (plist-get (request-response-data response) :error) :code)
                                   status))
                       (rmi-org-gcal--notify
                        "Received HTTP 401"
                        "OAuth token expired. Now trying to refresh-token")
                       (deferred:next
                         (lambda()
                           (rmi-org-gcal-refresh-token 'rmi-org-gcal-sync skip-export))))
                      ((eq 403 status)
                       (rmi-org-gcal--notify "Received HTTP 403"
                                         "Ensure you enabled the Calendar API through the Developers Console, then try again.")
                       (deferred:nextc it
                         (lambda()
                           (rmi-org-gcal-refresh-token 'rmi-org-gcal-sync skip-export))))
                      ;; We got some 2xx response, but for some reason no
                      ;; message body.
                      ((and (> 299 status) (eq temp nil))
                       (rmi-org-gcal--notify
                        (concat "Received HTTP" (number-to-string status))
                        "Error occured, but no message body."))
                      ((not (eq error-msg nil))
                       ;; Generic error-handler meant to provide useful
                       ;; information about failure cases not otherwise
                       ;; explicitly specified.
                       (rmi-org-gcal--notify
                        (concat "Status code: " (number-to-string status))
                        (pp-to-string error-msg)))
                      ;; Fetch was successful.
                      (t
                       (with-current-buffer (find-file-noselect (cdr x))
                         (unless skip-export
                           (save-excursion
                             (cl-loop with buf = (find-file-noselect rmi-org-gcal-token-file)
                                      for local-event in (rmi-org-gcal--parse-id (cdr x))
                                      for pos in (rmi-org-gcal--headline-list (cdr x))
                                      when (or
                                            (eq (car local-event) nil)
                                            (not (string= (cdr local-event)
                                                          (cdr (assoc (caar local-event)
                                                                      (with-current-buffer buf
                                                                        (plist-get (read (buffer-string)) (intern (concat ":" (car x))))))))))
                                      do
                                      (goto-char pos)
                                      (rmi-org-gcal-post-at-point t)
                                      finally
                                      (kill-buffer buf))
                             (sit-for 2)
                             (rmi-org-gcal-sync nil t t)))
                         (erase-buffer)
                         (let ((items (rmi-org-gcal--filter (plist-get (request-response-data response) :items))))
                           (when (assoc (car x) rmi-org-gcal-header-alist)
                             (insert (cdr (assoc (car x) rmi-org-gcal-header-alist))))
                           (insert
                            (mapconcat 'identity
                                       (mapcar (lambda (lst) (rmi-org-gcal--cons-list lst))
                                               items)
                                       ""))
                           (let ((plst (with-temp-buffer (insert-file-contents rmi-org-gcal-token-file)
                                                         (read (buffer-string)))))
                             (with-temp-file rmi-org-gcal-token-file
                               (pp (plist-put plst
                                              (intern (concat ":" (car x)))
                                              (mapcar
                                               (lambda (lst)
                                                       (cons (plist-get lst :id)
                                                             (rmi-org-gcal--cons-list lst)))
                                               items))
                                   (current-buffer)))))
                         (org-set-startup-visibility)
                         (save-buffer))
                       (unless silent
                         (rmi-org-gcal--notify "Completed event fetching ."
                                           (concat "Fetched data overwrote\n" (cdr x)))))))))))))

;;;###autoload
(defun rmi-org-gcal-fetch ()
  "Fetch event data from google calendar."
  (interactive)
  (rmi-org-gcal-sync nil t))

(defun rmi-org-gcal--filter (items)
  "Filter ITEMS on an AND of `rmi-org-gcal-fetch-event-filters' functions.
Run each element from ITEMS through all of the filters.  If any
filter returns NIL, discard the item."
  (if rmi-org-gcal-fetch-event-filters
      (cl-remove-if
       (lambda (item)
         (and (member nil
                      (mapcar (lambda (filter-func)
                                (funcall filter-func item)) rmi-org-gcal-fetch-event-filters))
              t))
       items)
    items))

(defun rmi-org-gcal--headline-list (file)
  "Return positions for all headlines of FILE."
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (hl) (org-element-property :begin hl))))))

(defun rmi-org-gcal--parse-id (file)
  "Return a list of conses (ID . entry) of file FILE."
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (save-excursion
        (cl-loop for pos in (org-element-map (org-element-parse-buffer) 'headline
                              (lambda (hl) (org-element-property :begin hl)))
                 do (goto-char pos)
                 collect (cons (org-element-map (org-element-at-point) 'headline
                                 (lambda (hl)
                                   (org-element-property :ID hl)))
                               (buffer-substring-no-properties
                                pos
                                (car
                                 (org-element-map (org-element-at-point) 'headline
                                   (lambda (hl) (org-element-property :end hl)))))))))))

(defun rmi-org-gcal--property-from-name (name)
  "\
Converts property names (as strings) to a symbol suitable for use as the
PROPERTY argument to ‘org-element-property’."
  (intern (concat ":" (upcase name))))

;;;###autoload
(defun rmi-org-gcal-post-at-point (&optional skip-import)
  "Post entry at point to current calendar.
If SKIP-IMPORT is not nil, do not import events from the
current calendar."
  (interactive)
  (rmi-org-gcal--ensure-token)
  (save-excursion
    (end-of-line)
    (org-back-to-heading)
    (let* ((skip-import skip-import)
           (elem (org-element-headline-parser (point-max) t))
           (tobj (progn (re-search-forward "<[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
                                           (save-excursion (outline-next-heading) (point)))
                        (goto-char (match-beginning 0))
                        (org-element-timestamp-parser)))
           (smry (org-element-property :title elem))
           (loc (org-element-property :LOCATION elem))
           (id (org-element-property :ID elem))
           (start (rmi-org-gcal--format-org2iso
                   (plist-get (cadr tobj) :year-start)
                   (plist-get (cadr tobj) :month-start)
                   (plist-get (cadr tobj) :day-start)
                   (plist-get (cadr tobj) :hour-start)
                   (plist-get (cadr tobj) :minute-start)
                   (when (plist-get (cadr tobj) :hour-start)
                     t)))
           (end (rmi-org-gcal--format-org2iso
                 (plist-get (cadr tobj) :year-end)
                 (plist-get (cadr tobj) :month-end)
                 (plist-get (cadr tobj) :day-end)
                 (plist-get (cadr tobj) :hour-end)
                 (plist-get (cadr tobj) :minute-end)
                 (when (plist-get (cadr tobj) :hour-start)
                   t)))
           (desc (if (plist-get (cadr elem) :contents-begin)
                     (replace-regexp-in-string "^✱" "*"
                                               (replace-regexp-in-string
                                                "\\`\\(?: *<[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].*?>$\\)\n?\n?"
                                                ""
                                                (replace-regexp-in-string
                                                 " *:PROPERTIES:\n *\\(.*\\(?:\n.*\\)*?\\) *:END:\n+"
                                                 ""
                                                 (buffer-substring-no-properties
                                                  (plist-get (cadr elem) :contents-begin)
                                                  (plist-get (cadr elem) :contents-end)))))
                   "")))
      (rmi-org-gcal--post-event start end smry loc desc id nil skip-import))))

;;;###autoload
(defun rmi-org-gcal-delete-at-point ()
  "Delete entry at point to current calendar."
  (interactive)
  (rmi-org-gcal--ensure-token)
  (save-excursion
    (end-of-line)
    (org-back-to-heading)
    (let* ((elem (org-element-headline-parser (point-max) t))
           (smry (org-element-property :title elem))
           (id (org-element-property :ID elem)))
      (when (and id
                 (y-or-n-p (format "Do you really want to delete event?\n\n%s\n\n" smry)))
        (rmi-org-gcal--delete-event id)))))

(defun rmi-org-gcal-request-authorization ()
  "Request OAuth authorization at AUTH-URL by launching `browse-url'.
CLIENT-ID is the client id provided by the provider.
It returns the code provided by the service."
  (browse-url (concat rmi-org-gcal-auth-url
                      "?client_id=" (url-hexify-string rmi-org-gcal-client-id)
                      "&response_type=code"
                      "&redirect_uri=" (url-hexify-string "urn:ietf:wg:oauth:2.0:oob")
                      "&scope=" (url-hexify-string rmi-org-gcal-resource-url)))
  (read-string "Enter the code your browser displayed: "))

(defun rmi-org-gcal-request-token ()
  "Refresh OAuth access at TOKEN-URL."
  (request
   rmi-org-gcal-token-url
   :type "POST"
   :data `(("client_id" . ,rmi-org-gcal-client-id)
           ("client_secret" . ,rmi-org-gcal-client-secret)
           ("code" . ,(rmi-org-gcal-request-authorization))
           ("redirect_uri" .  "urn:ietf:wg:oauth:2.0:oob")
           ("grant_type" . "authorization_code"))
   :parser 'rmi-org-gcal--json-read
   :success (cl-function
             (lambda (&key data &allow-other-keys)
               (when data
                 (setq rmi-org-gcal-token-plist data)
                 (rmi-org-gcal--save-sexp data rmi-org-gcal-token-file))))
   :error
   (cl-function (lambda (&key error-thrown &allow-other-keys)
                  (message "Got error: %S" error-thrown)))))

(defun rmi-org-gcal-refresh-token (&optional fun skip-export start end smry loc desc id)
  "Refresh OAuth access and call FUN after that.
Pass SKIP-EXPORT, START, END, SMRY, LOC, DESC.  and ID to FUN if
needed."
  (deferred:$
    (request-deferred
     rmi-org-gcal-token-url
     :type "POST"
     :data `(("client_id" . ,rmi-org-gcal-client-id)
             ("client_secret" . ,rmi-org-gcal-client-secret)
             ("refresh_token" . ,(rmi-org-gcal--get-refresh-token))
             ("grant_type" . "refresh_token"))
     :parser 'rmi-org-gcal--json-read
     :error
     (cl-function (lambda (&key error-thrown &allow-other-keys)
                    (message "Got error: %S" error-thrown))))
    (deferred:nextc it
      (lambda (response)
        (let ((temp (request-response-data response)))
          (plist-put rmi-org-gcal-token-plist
                     :access_token
                     (plist-get temp :access_token))
          (rmi-org-gcal--save-sexp rmi-org-gcal-token-plist rmi-org-gcal-token-file)
          rmi-org-gcal-token-plist)))
    (deferred:nextc it
      (lambda (token)
        (cond ((eq fun 'rmi-org-gcal-sync)
               (rmi-org-gcal-sync (plist-get token :access_token) skip-export))
              ((eq fun 'rmi-org-gcal--post-event)
               (rmi-org-gcal--post-event start end smry loc desc id (plist-get token :access_token)))
              ((eq fun 'rmi-org-gcal--delete-event)
               (rmi-org-gcal--delete-event id (plist-get token :access_token))))))))

;; Internal
(defun rmi-org-gcal--archive-old-event ()
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward org-heading-regexp nil t)
      (condition-case nil
          (goto-char (cdr (rmi-org-gcal--timestamp-successor)))
        (error (error "Org-gcal error: Couldn't parse %s"
                      (buffer-file-name))))
      (let ((elem (org-element-headline-parser (point-max) t))
            (tobj (cadr (org-element-timestamp-parser))))
        (when (>
               (time-to-seconds (time-subtract (current-time) (days-to-time rmi-org-gcal-up-days)))
               (time-to-seconds (encode-time 0  (if (plist-get tobj :minute-end)
                                                    (plist-get tobj :minute-end) 0)
                                             (if (plist-get tobj :hour-end)
                                                 (plist-get tobj :hour-end) 24)
                                             (plist-get tobj :day-end)
                                             (plist-get tobj :month-end)
                                             (plist-get tobj :year-end))))
          (rmi-org-gcal--notify "Archived event." (org-element-property :title elem))
          (let ((kill-ring kill-ring)
                (select-enable-clipboard nil))
            (org-archive-subtree)))))
    (save-buffer)))

(defun rmi-org-gcal--save-sexp (data file)
  (if (file-directory-p rmi-org-gcal-dir)
      (if (file-exists-p file)
          (if  (plist-get (read (buffer-string)) :token)
              (with-temp-file file
                (pp (plist-put (read (buffer-string)) :token data) (current-buffer)))
            (with-temp-file file
              (pp `(:token ,data :elem nil) (current-buffer))))
        (progn
          (find-file-noselect file)
          (with-temp-file file
            (pp `(:token ,data :elem nil) (current-buffer)))))
    (progn
      (make-directory rmi-org-gcal-dir)
      (rmi-org-gcal--save-sexp data file))))

(defun rmi-org-gcal--json-read ()
  (let ((json-object-type 'plist))
    (goto-char (point-min))
    (re-search-forward "^{" nil t)
    (delete-region (point-min) (1- (point)))
    (goto-char (point-min))
    (json-read-from-string
     (decode-coding-string
      (buffer-substring-no-properties (point-min) (point-max)) 'utf-8))))

(defun rmi-org-gcal--get-refresh-token ()
  (if rmi-org-gcal-token-plist
      (plist-get rmi-org-gcal-token-plist :refresh_token)
    (progn
      (if (file-exists-p rmi-org-gcal-token-file)
          (progn
            (with-temp-buffer (insert-file-contents rmi-org-gcal-token-file)
                              (plist-get (plist-get (read (buffer-string)) :token) :refresh_token)))
        (rmi-org-gcal--notify
         (concat rmi-org-gcal-token-file " is not exists")
         (concat "Make" rmi-org-gcal-token-file))))))

(defun rmi-org-gcal--get-access-token ()
  (if rmi-org-gcal-token-plist
      (plist-get rmi-org-gcal-token-plist :access_token)
    (progn
      (if (file-exists-p rmi-org-gcal-token-file)
          (progn
            (with-temp-buffer (insert-file-contents rmi-org-gcal-token-file)
                              (plist-get (plist-get (read (buffer-string)) :token) :access_token)))
        (rmi-org-gcal--notify
         (concat rmi-org-gcal-token-file " is not exists")
         (concat "Make " rmi-org-gcal-token-file))))))

(defun rmi-org-gcal--safe-substring (string from &optional to)
  "Call the `substring' function safely.
No errors will be returned for out of range values of FROM and
TO.  Instead an empty string is returned."
  (let* ((len (length string))
         (to (or to len)))
    (when (< from 0)
      (setq from (+ len from)))
    (when (< to 0)
      (setq to (+ len to)))
    (if (or (< from 0) (> from len)
            (< to 0) (> to len)
            (< to from))
        ""
      (substring string from to))))

(defun rmi-org-gcal--alldayp (s e)
  (let ((slst (rmi-org-gcal--parse-date s))
        (elst (rmi-org-gcal--parse-date e)))
    (and
     (= (length s) 10)
     (= (length e) 10)
     (= (- (time-to-seconds
            (encode-time 0 0 0
                         (plist-get elst :day)
                         (plist-get elst :mon)
                         (plist-get elst :year)))
           (time-to-seconds
            (encode-time 0 0 0
                         (plist-get slst :day)
                         (plist-get slst :mon)
                         (plist-get slst :year)))) 86400))))

(defun rmi-org-gcal--parse-date (str)
  (list :year (string-to-number  (rmi-org-gcal--safe-substring str 0 4))
        :mon  (string-to-number (rmi-org-gcal--safe-substring str 5 7))
        :day  (string-to-number (rmi-org-gcal--safe-substring str 8 10))
        :hour (string-to-number (rmi-org-gcal--safe-substring str 11 13))
        :min  (string-to-number (rmi-org-gcal--safe-substring str 14 16))
        :sec  (string-to-number (rmi-org-gcal--safe-substring str 17 19))))

(defun rmi-org-gcal--adjust-date (fn day)
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (funcall fn (current-time) (days-to-time day)) t))

(defun rmi-org-gcal--add-time ()
  (rmi-org-gcal--adjust-date 'time-add rmi-org-gcal-down-days))

(defun rmi-org-gcal--subtract-time ()
  (rmi-org-gcal--adjust-date 'time-subtract rmi-org-gcal-up-days))

(defun rmi-org-gcal--time-zone (seconds)
  (current-time-zone (seconds-to-time seconds)))

(defun rmi-org-gcal--format-iso2org (str &optional tz)
  (let* ((plst (rmi-org-gcal--parse-date str))
         (seconds (rmi-org-gcal--time-to-seconds plst)))
    (concat
     "<"
     (format-time-string
      (if (< 11 (length str)) "%Y-%m-%d %a %H:%M" "%Y-%m-%d %a")
      (seconds-to-time
       (+ (if tz (car (rmi-org-gcal--time-zone seconds)) 0)
          seconds)))
     ;;(if (and repeat (not (string= repeat ""))) (concat " " repeat) "")
     ">")))

(defun rmi-org-gcal--format-org2iso (year mon day &optional hour min tz)
  (let ((seconds (time-to-seconds (encode-time 0
                                               (or min 0)
                                               (or hour 0)
                                               day mon year))))
    (format-time-string
     (if (or hour min) "%Y-%m-%dT%H:%M:00Z" "%Y-%m-%d")
     (seconds-to-time
      (-
       seconds
       (if tz (car (rmi-org-gcal--time-zone seconds)) 0))))))

(defun rmi-org-gcal--iso-next-day (str &optional previous-p)
  (let ((format (if (< 11 (length str))
                    "%Y-%m-%dT%H:%M"
                  "%Y-%m-%d"))
        (plst (rmi-org-gcal--parse-date str))
        (prev (if previous-p -1 +1)))
    (format-time-string format
                        (seconds-to-time
                         (+ (rmi-org-gcal--time-to-seconds plst)
                            (* 60 60 24 prev))))))

(defun rmi-org-gcal--iso-previous-day (str)
  (rmi-org-gcal--iso-next-day str t))

(defun rmi-org-gcal--cons-list (plst)
  (let* ((smry  (or (plist-get plst :summary)
                    "busy"))
         (desc  (plist-get plst :description))
         (loc   (plist-get plst :location))
         (link  (plist-get plst :htmlLink))
         (meet  (plist-get plst :hangoutLink))
         (id    (plist-get plst :id))
         (stime (plist-get (plist-get plst :start)
                           :dateTime))
         (etime (plist-get (plist-get plst :end)
                           :dateTime))
         (sday  (plist-get (plist-get plst :start)
                           :date))
         (eday  (plist-get (plist-get plst :end)
                           :date))
         (start (if stime stime sday))
         (end   (if etime etime eday)))
    (when loc (replace-regexp-in-string "\n" ", " loc))
    (concat
     "* " smry "\n"
     "  :PROPERTIES:\n"
     "  :" (symbol-name rmi-org-gcal-property) ": t\n"
     (when loc "  :LOCATION: ") loc (when loc "\n")
     "  :LINK: ""[[" link "][Go to gcal web page]]\n"
     (when meet
       (format "  %s [[%s][%s]]\n"
               ":HANGOUTS:"
               meet
               "Join Hangouts Meet"))
     "  :ID: " id "\n"
     "  :END:\n"
     (if (or (string= start end) (rmi-org-gcal--alldayp start end))
         (concat "\n  "(rmi-org-gcal--format-iso2org start))
       (if (and
            (= (plist-get (rmi-org-gcal--parse-date start) :year)
               (plist-get (rmi-org-gcal--parse-date end)   :year))
            (= (plist-get (rmi-org-gcal--parse-date start) :mon)
               (plist-get (rmi-org-gcal--parse-date end)   :mon))
            (= (plist-get (rmi-org-gcal--parse-date start) :day)
               (plist-get (rmi-org-gcal--parse-date end)   :day)))
           (concat "\n  <"
                   (rmi-org-gcal--format-date start "%Y-%m-%d %a %H:%M")
                   "-"
                   (rmi-org-gcal--format-date end "%H:%M")
                   ">")
         (concat "\n  " (rmi-org-gcal--format-iso2org start)
                 "--"
                 (rmi-org-gcal--format-iso2org
                  (if (< 11 (length end))
                      end
                    (rmi-org-gcal--iso-previous-day end)))))) "\n"
     (when desc "\n")
     (when desc (replace-regexp-in-string "^\*" "✱" desc))
     (when desc (if (string= "\n" (rmi-org-gcal--safe-substring desc -1)) "" "\n")))))

(defun rmi-org-gcal--format-date (str format &optional tz)
  (let* ((plst (rmi-org-gcal--parse-date str))
         (seconds (rmi-org-gcal--time-to-seconds plst)))
    (concat
     (format-time-string format
                         (seconds-to-time
                          (+ (if tz (car (rmi-org-gcal--time-zone seconds)) 0)
                             seconds))))))

(defun rmi-org-gcal--param-date (str)
  (if (< 11 (length str)) "dateTime" "date"))

(defun rmi-org-gcal--param-date-alt (str)
  (if (< 11 (length str)) "date" "dateTime"))

(defun rmi-org-gcal--get-calendar-id-of-buffer ()
  "Find calendar id of current buffer."
  (or (cl-loop for (id . file) in rmi-org-gcal-file-alist
               if (file-equal-p file (buffer-file-name (buffer-base-buffer)))
               return id)
      (user-error (concat "Buffer `%s' may not related to google calendar; "
                          "please check/configure `rmi-org-gcal-file-alist'")
                  (buffer-name))))

(defun rmi-org-gcal--post-event (start end smry loc desc &optional id a-token skip-import skip-export)
  (let ((stime (rmi-org-gcal--param-date start))
        (etime (rmi-org-gcal--param-date end))
        (stime-alt (rmi-org-gcal--param-date-alt start))
        (etime-alt (rmi-org-gcal--param-date-alt end))
        (a-token (if a-token
                     a-token
                   (rmi-org-gcal--get-access-token))))
    (request
     (concat
      (format rmi-org-gcal-events-url (rmi-org-gcal--get-calendar-id-of-buffer))
      (when id
        (concat "/" id)))
     :type (if id "PATCH" "POST")
     :headers '(("Content-Type" . "application/json"))
     :data (encode-coding-string
            (json-encode `(("start" (,stime . ,start) (,stime-alt . nil))
                           ("end" (,etime . ,(if (equal "date" etime)
                                                 (rmi-org-gcal--iso-next-day end)
                                               end)) (,etime-alt . nil))
                           ("summary" . ,smry)
                           ("location" . ,loc)
                           ("description" . ,desc)))
            'utf-8)
     :params `(("access_token" . ,a-token)
               ("key" . ,rmi-org-gcal-client-secret)
               ("grant_type" . "authorization_code"))

     :parser 'rmi-org-gcal--json-read
     :error (cl-function
             (lambda (&key response &allow-other-keys)
               (let ((status (request-response-status-code response))
                     (error-msg (request-response-error-thrown response)))
                 (cond
                  ((eq status 401)
                   (progn
                     (rmi-org-gcal--notify
                      "Received HTTP 401"
                      "OAuth token expired. Now trying to refresh-token")
                     (rmi-org-gcal-refresh-token 'rmi-org-gcal--post-event skip-export start end smry loc desc id)))
                  (t
                   (rmi-org-gcal--notify
                    (concat "Status code: " (pp-to-string status))
                    (pp-to-string error-msg)))))))
     :success (cl-function
               (lambda (&key data &allow-other-keys)
                 (progn
                   (rmi-org-gcal--notify "Event Posted"
                                     (concat "Org-gcal post event\n  " (plist-get data :summary)))
                   (unless skip-import (rmi-org-gcal-fetch))))))))

(defun rmi-org-gcal--delete-event (event-id &optional a-token)
  (let ((a-token (if a-token
                     a-token
                   (rmi-org-gcal--get-access-token)))
        (calendar-id (rmi-org-gcal--get-calendar-id-of-buffer)))
    (request
     (concat
      (format rmi-org-gcal-events-url calendar-id)
      (concat "/" event-id))
     :type "DELETE"
     :headers '(("Content-Type" . "application/json"))
     :params `(("access_token" . ,a-token)
               ("key" . ,rmi-org-gcal-client-secret)
               ("grant_type" . "authorization_code"))
     :error (cl-function
             (lambda (&key response &allow-other-keys)
               (let ((status (request-response-status-code response))
                     (error-msg (request-response-error-thrown response)))
                 (cond
                  ((eq status 401)
                   (progn
                     (rmi-org-gcal--notify
                      "Received HTTP 401"
                      "OAuth token expired. Now trying to refresh-token")
                     (rmi-org-gcal-refresh-token 'rmi-org-gcal--delete-event nil nil nil nil nil nil event-id)))
                  (t
                   (rmi-org-gcal--notify
                    (concat "Status code: " (pp-to-string status))
                    (pp-to-string error-msg)))))))
     :success (cl-function
               (lambda (&key &allow-other-keys)
                 (progn
                   (rmi-org-gcal-fetch)
                   (rmi-org-gcal--notify "Event Deleted" "Org-gcal deleted event")))))))

(defun rmi-org-gcal--capture-post ()
  (dolist (i rmi-org-gcal-file-alist)
    (when (string=  (file-name-nondirectory (cdr i))
                    (substring (buffer-name) 8))
      (rmi-org-gcal-post-at-point))))

(add-hook 'org-capture-before-finalize-hook 'rmi-org-gcal--capture-post)

(defun rmi-org-gcal--ensure-token ()
  (cond
   (rmi-org-gcal-token-plist t)
   ((and (file-exists-p rmi-org-gcal-token-file)
         (ignore-errors
           (setq rmi-org-gcal-token-plist
                 (with-temp-buffer
                   (insert-file-contents rmi-org-gcal-token-file)
                   (plist-get (read (current-buffer)) :token))))) t)
   (t (rmi-org-gcal-request-token))))

(defun rmi-org-gcal--timestamp-successor ()
  "Search for the next timestamp object.
Return value is a cons cell whose CAR is `timestamp' and CDR is
beginning position."
  (save-excursion
    (when (re-search-forward
           (concat org-ts-regexp-both
                   "\\|"
                   "\\(?:<[0-9]+-[0-9]+-[0-9]+[^>\n]+?\\+[0-9]+[dwmy]>\\)"
                   "\\|"
                   "\\(?:<%%\\(?:([^>\n]+)\\)>\\)")
           nil t)
      (cons 'timestamp (match-beginning 0)))))

(defun rmi-org-gcal--notify (title message)
  "Send alert with TITLE and MESSAGE."
  (when rmi-org-gcal-notify-p
    (if rmi-org-gcal-logo-file
        (alert message :title title :icon rmi-org-gcal-logo-file)
      (alert message :title title))))

(defun rmi-org-gcal--time-to-seconds (plst)
  (time-to-seconds
   (encode-time
    (plist-get plst :sec)
    (plist-get plst :min)
    (plist-get plst :hour)
    (plist-get plst :day)
    (plist-get plst :mon)
    (plist-get plst :year))))


(provide 'rmi-org-gcal)

;;; rmi-org-gcal.el ends here
