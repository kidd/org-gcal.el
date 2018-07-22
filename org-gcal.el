;;; org-gcal.el --- Org sync with Google Calendar -*- lexical-binding: t -*-

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
;; Put the org-gcal.el to your
;; load-path.
;; Add to .emacs:
;; (require 'org-gcal)
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

(defgroup org-gcal nil "Org sync with Google Calendar"
  :tag "Org google calendar"
  :group 'org)

(defcustom org-gcal-up-days 30
  "Number of days to get events before today."
  :group 'org-gcal
  :type 'integer)

(defcustom org-gcal-down-days 60
  "Number of days to get events after today."
  :group 'org-gcal
  :type 'integer)

(defcustom org-gcal-auto-archive t
  "If non-nil, old events archive automatically."
  :group 'org-gcal
  :type 'boolean)

(defcustom org-gcal-dir
  (concat user-emacs-directory "org-gcal/")
  "File in which to save token."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-token-file
  (expand-file-name ".org-gcal-token" org-gcal-dir)
  "File in which to save token."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-client-id nil
  "Client ID for OAuth."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-client-secret nil
  "Google calendar secret key for OAuth."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-file-alist nil
  "List of association '(calendar-id file) to synchronize at once for calendar id."
  :group 'org-gcal
  :type '(alist :key-type (string :tag "Calendar Id") :value-type (file :tag "Org file")))

(defcustom org-gcal-logo-file nil
  "Org-gcal logo image filename to display in notifications."
  :group 'org-gcal
  :type 'file)

(defcustom org-gcal-fetch-event-filters '()
  "Predicate functions to filter calendar events.
Predicate functions take an event, and if they return nil the
   event will not be fetched."
  :group 'org-gcal
  :type 'list)

(defcustom org-gcal-notify-p t
  "If nil no more alert messages are shown for status updates."
  :group 'org-gcal
  :type 'boolean)

(defcustom org-gcal-header-alist ()
  "\
Association list of '(calendar-id header). For each calendar-id present in this
list, the associated header will be inserted at the top of the file associated
with the calendar-id in org-gcal-file-alist, before any calendar entries.

This is intended to set headers in the org-mode files maintained by org-gcal to
control categories, archive locations, and other local variables."
  :group 'org-gcal
  :type '(alist :key-type (string :tag "Calendar Id") :value-type (string :tag "Header")))

(defvar org-gcal-token-plist nil
  "Token plist.")

(defconst org-gcal-auth-url "https://accounts.google.com/o/oauth2/auth"
  "Google OAuth2 server URL.")

(defconst org-gcal-token-url "https://www.googleapis.com/oauth2/v3/token"
  "Google OAuth2 server URL.")

(defconst org-gcal-resource-url "https://www.googleapis.com/auth/calendar"
  "URL used to request access to calendar resources.")

(defconst org-gcal-events-url "https://www.googleapis.com/calendar/v3/calendars/%s/events")

;;;###autoload
(defun org-gcal-sync (&optional a-token skip-export silent)
  "Import events from calendars.
Using A-TOKEN and export the ones to the calendar if unless
SKIP-EXPORT.  Set SILENT to non-nil to inhibit notifications."
  (interactive)
  (org-gcal--ensure-token)
  (when org-gcal-auto-archive
    (dolist (i org-gcal-file-alist)
      (with-current-buffer
          (find-file-noselect (cdr i))
        (org-gcal--archive-old-event))))
  (cl-loop for x in org-gcal-file-alist
           do
           (let ((x x)
                 (a-token (if a-token
                              a-token
                            (org-gcal--get-access-token)))

                 (skip-export skip-export)
                 (silent silent))
             (deferred:$
               (request-deferred
                (format org-gcal-events-url (car x))
                :type "GET"
                :params `(("access_token" . ,a-token)
                          ("key" . ,org-gcal-client-secret)
                          ("singleEvents" . "True")
                          ("orderBy" . "startTime")
                          ("timeMin" . ,(org-gcal--subtract-time))
                          ("timeMax" . ,(org-gcal--add-time))
                          ("grant_type" . "authorization_code"))
                :parser 'org-gcal--json-read
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
                       (org-gcal--notify
                        "Got Error"
                        "Could not contact remote service. Please check your network connectivity."))
                      ;; Receiving a 403 response could mean that the calendar
                      ;; API has not been enabled. When the user goes and
                      ;; enables it, a new token will need to be generated. This
                      ;; takes care of that step.
                      ((eq 401 (or (plist-get (plist-get (request-response-data response) :error) :code)
                                   status))
                       (org-gcal--notify
                        "Received HTTP 401"
                        "OAuth token expired. Now trying to refresh-token")
                       (deferred:next
                         (lambda()
                           (org-gcal-refresh-token 'org-gcal-sync skip-export))))
                      ((eq 403 status)
                       (org-gcal--notify "Received HTTP 403"
                                         "Ensure you enabled the Calendar API through the Developers Console, then try again.")
                       (deferred:nextc it
                         (lambda()
                           (org-gcal-refresh-token 'org-gcal-sync skip-export))))
                      ;; We got some 2xx response, but for some reason no
                      ;; message body.
                      ((and (> 299 status) (eq temp nil))
                       (org-gcal--notify
                        (concat "Received HTTP" (number-to-string status))
                        "Error occured, but no message body."))
                      ((not (eq error-msg nil))
                       ;; Generic error-handler meant to provide useful
                       ;; information about failure cases not otherwise
                       ;; explicitly specified.
                       (org-gcal--notify
                        (concat "Status code: " (number-to-string status))
                        (pp-to-string error-msg)))
                      ;; Fetch was successful.
                      (t
                       (with-current-buffer (find-file-noselect (cdr x))
                         (unless skip-export
                           (save-excursion
                             (cl-loop with buf = (find-file-noselect org-gcal-token-file)
                                      for local-event in (org-gcal--parse-id (cdr x))
                                      for pos in (org-gcal--headline-list (cdr x))
                                      when (or
                                            (eq (car local-event) nil)
                                            (not (string= (cdr local-event)
                                                          (cdr (assoc (caar local-event)
                                                                      (with-current-buffer buf
                                                                        (plist-get (read (buffer-string)) (intern (concat ":" (car x))))))))))
                                      do
                                      (goto-char pos)
                                      (org-gcal-post-at-point t)
                                      finally
                                      (kill-buffer buf))
                             (sit-for 2)
                             (org-gcal-sync nil t t)))
                         (erase-buffer)
                         (let ((items (org-gcal--filter (plist-get (request-response-data response) :items))))
                           (when (assoc (car x) org-gcal-header-alist)
                             (insert (cdr (assoc (car x) org-gcal-header-alist))))
                           (insert
                            (mapconcat 'identity
                                       (mapcar (lambda (lst) (org-gcal--cons-list lst))
                                               items)
                                       ""))
                           (let ((plst (with-temp-buffer (insert-file-contents org-gcal-token-file)
                                                         (read (buffer-string)))))
                             (with-temp-file org-gcal-token-file
                               (pp (plist-put plst
                                              (intern (concat ":" (car x)))
                                              (mapcar (lambda (lst (cons (plist-get lst :id) (org-gcal--cons-list lst)) items)) (current-buffer))))
                               (org-set-startup-visibility)
                               (save-buffer)))))
                       (unless silent
                         (org-gcal--notify "Completed event fetching ."
                                           (concat "Fetched data overwrote\n" (cdr x)))))))))))))

;;;###autoload
(defun org-gcal-fetch ()
  "Fetch event data from google calendar."
  (interactive)
  (org-gcal-sync nil t))

(defun org-gcal--filter (items)
  "Filter ITEMS on an AND of `org-gcal-fetch-event-filters' functions.
Run each element from ITEMS through all of the filters.  If any
filter returns NIL, discard the item."
  (if org-gcal-fetch-event-filters
      (cl-remove-if
       (lambda (item)
         (and (member nil
                      (mapcar (lambda (filter-func)
                                (funcall filter-func item)) org-gcal-fetch-event-filters))
              t))
       items)
    items))

(defun org-gcal--headline-list (file)
  "Return positions for all headlines of FILE."
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (hl) (org-element-property :begin hl))))))

(defun org-gcal--parse-id (file)
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

;;;###autoload
(defun org-gcal-post-at-point (&optional skip-import)
  "Post entry at point to current calendar.
If SKIP-IMPORT is not nil, do not import events from the
current calendar."
  (interactive)
  (org-gcal--ensure-token)
  (save-excursion
    (end-of-line)
    (org-back-to-heading)
    (let* ((skip-import skip-import)
           (calendar-id (org-gcal--get-calendar-id-of-buffer))
           (elem (org-element-headline-parser (point-max) t))
           (tobj (progn (re-search-forward "<[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
                                           (save-excursion (outline-next-heading) (point)))
                        (goto-char (match-beginning 0))
                        (org-element-timestamp-parser)))
           (smry (org-element-property :title elem))
           (loc (org-element-property :LOCATION elem))
           (id (org-element-property :ID elem))
           (start (org-gcal--format-org2iso
                   (plist-get (cadr tobj) :year-start)
                   (plist-get (cadr tobj) :month-start)
                   (plist-get (cadr tobj) :day-start)
                   (plist-get (cadr tobj) :hour-start)
                   (plist-get (cadr tobj) :minute-start)
                   (when (plist-get (cadr tobj) :hour-start)
                     t)))
           (end (org-gcal--format-org2iso
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
                                                 " *:PROPERTIES:\n  \\(.*\\(?:\n.*\\)*?\\) :END:\n\n"
                                                 ""
                                                 (buffer-substring-no-properties
                                                  (plist-get (cadr elem) :contents-begin)
                                                  (plist-get (cadr elem) :contents-end)))))
                   "")))
      (org-gcal--post-event start end smry loc desc calendar-id event-id nil skip-import))))

;;;###autoload
(defun org-gcal-delete-at-point ()
  "Delete entry at point to current calendar."
  (interactive)
  (org-gcal--ensure-token)
  (save-excursion
    (end-of-line)
    (org-back-to-heading)
    (let* ((elem (org-element-headline-parser (point-max) t))
           (smry (org-element-property :title elem))
           (event-id (org-element-property :ID elem)))
      (when (and event-id
                 (y-or-n-p (format "Do you really want to delete event?\n\n%s\n\n" smry)))
        (org-gcal--delete-event event-id calendar-id nil skip-import)))))

(defun org-gcal-request-authorization ()
  "Request OAuth authorization at AUTH-URL by launching `browse-url'.
CLIENT-ID is the client id provided by the provider.
It returns the code provided by the service."
  (browse-url (concat org-gcal-auth-url
                      "?client_id=" (url-hexify-string org-gcal-client-id)
                      "&response_type=code"
                      "&redirect_uri=" (url-hexify-string "urn:ietf:wg:oauth:2.0:oob")
                      "&scope=" (url-hexify-string org-gcal-resource-url)))
  (read-string "Enter the code your browser displayed: "))

(defun org-gcal-request-token ()
  "Refresh OAuth access at TOKEN-URL."
  (request
   org-gcal-token-url
   :type "POST"
   :data `(("client_id" . ,org-gcal-client-id)
           ("client_secret" . ,org-gcal-client-secret)
           ("code" . ,(org-gcal-request-authorization))
           ("redirect_uri" .  "urn:ietf:wg:oauth:2.0:oob")
           ("grant_type" . "authorization_code"))
   :parser 'org-gcal--json-read
   :success (cl-function
             (lambda (&key data &allow-other-keys)
               (when data
                 (setq org-gcal-token-plist data)
                 (org-gcal--save-sexp data org-gcal-token-file))))
   :error
   (cl-function (lambda (&key error-thrown &allow-other-keys)
                  (message "Got error: %S" error-thrown)))))

(defun org-gcal-refresh-token (&optional fun skip-export start end smry loc desc calendar-id event-id)
  "Refresh OAuth access and call FUN after that.
Pass SKIP-EXPORT, START, END, SMRY, LOC, DESC, CALENDAR-ID, and EVENT-ID to FUN if
needed."
  (deferred:$
    (request-deferred
     org-gcal-token-url
     :type "POST"
     :data `(("client_id" . ,org-gcal-client-id)
             ("client_secret" . ,org-gcal-client-secret)
             ("refresh_token" . ,(org-gcal--get-refresh-token))
             ("grant_type" . "refresh_token"))
     :parser 'org-gcal--json-read
     :error
     (cl-function (lambda (&key error-thrown &allow-other-keys)
                    (message "Got error: %S" error-thrown))))
    (deferred:nextc it
      (lambda (response)
        (let ((temp (request-response-data response)))
          (plist-put org-gcal-token-plist
                     :access_token
                     (plist-get temp :access_token))
          (org-gcal--save-sexp org-gcal-token-plist org-gcal-token-file)
          org-gcal-token-plist)))
    (deferred:nextc it
      (lambda (token)
        (cond ((eq fun 'org-gcal-sync)
               (org-gcal-sync (plist-get token :access_token) skip-export))
              ((eq fun 'org-gcal--post-event)
               (org-gcal--post-event start end smry loc desc calendar-id event-id (plist-get token :access_token)))
              ((eq fun 'org-gcal--delete-event)
               (org-gcal--delete-event event-id calendar-id (plist-get token :access_token))))))))

;; Internal
(defun org-gcal--archive-old-event ()
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward org-heading-regexp nil t)
      (condition-case nil
          (goto-char (cdr (org-gcal--timestamp-successor)))
        (error (error "Org-gcal error: Couldn't parse %s"
                      (buffer-file-name))))
      (let ((elem (org-element-headline-parser (point-max) t))
            (tobj (cadr (org-element-timestamp-parser))))
        (when (>
               (time-to-seconds (time-subtract (current-time) (days-to-time org-gcal-up-days)))
               (time-to-seconds (encode-time 0  (if (plist-get tobj :minute-end)
                                                    (plist-get tobj :minute-end) 0)
                                             (if (plist-get tobj :hour-end)
                                                 (plist-get tobj :hour-end) 24)
                                             (plist-get tobj :day-end)
                                             (plist-get tobj :month-end)
                                             (plist-get tobj :year-end))))
          (org-gcal--notify "Archived event." (org-element-property :title elem))
          (let ((kill-ring kill-ring)
                (select-enable-clipboard nil))
            (org-archive-subtree)))))
    (save-buffer)))

(defun org-gcal--save-sexp (data file)
  (if (file-directory-p org-gcal-dir)
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
      (make-directory org-gcal-dir)
      (org-gcal--save-sexp data file))))

(defun org-gcal--json-read ()
  (let ((json-object-type 'plist))
    (goto-char (point-min))
    (re-search-forward "^{" nil t)
    (delete-region (point-min) (1- (point)))
    (goto-char (point-min))
    (json-read-from-string
     (decode-coding-string
      (buffer-substring-no-properties (point-min) (point-max)) 'utf-8))))

(defun org-gcal--get-refresh-token ()
  (if org-gcal-token-plist
      (plist-get org-gcal-token-plist :refresh_token)
    (progn
      (if (file-exists-p org-gcal-token-file)
          (progn
            (with-temp-buffer (insert-file-contents org-gcal-token-file)
                              (plist-get (plist-get (read (buffer-string)) :token) :refresh_token)))
        (org-gcal--notify
         (concat org-gcal-token-file " is not exists")
         (concat "Make" org-gcal-token-file))))))

(defun org-gcal--get-access-token ()
  (if org-gcal-token-plist
      (plist-get org-gcal-token-plist :access_token)
    (progn
      (if (file-exists-p org-gcal-token-file)
          (progn
            (with-temp-buffer (insert-file-contents org-gcal-token-file)
                              (plist-get (plist-get (read (buffer-string)) :token) :access_token)))
        (org-gcal--notify
         (concat org-gcal-token-file " is not exists")
         (concat "Make " org-gcal-token-file))))))

(defun org-gcal--safe-substring (string from &optional to)
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

(defun org-gcal--alldayp (s e)
  (let ((slst (org-gcal--parse-date s))
        (elst (org-gcal--parse-date e)))
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

(defun org-gcal--parse-date (str)
  (list :year (string-to-number  (org-gcal--safe-substring str 0 4))
        :mon  (string-to-number (org-gcal--safe-substring str 5 7))
        :day  (string-to-number (org-gcal--safe-substring str 8 10))
        :hour (string-to-number (org-gcal--safe-substring str 11 13))
        :min  (string-to-number (org-gcal--safe-substring str 14 16))
        :sec  (string-to-number (org-gcal--safe-substring str 17 19))))

(defun org-gcal--adjust-date (fn day)
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (funcall fn (current-time) (days-to-time day)) t))

(defun org-gcal--add-time ()
  (org-gcal--adjust-date 'time-add org-gcal-down-days))

(defun org-gcal--subtract-time ()
  (org-gcal--adjust-date 'time-subtract org-gcal-up-days))

(defun org-gcal--time-zone (seconds)
  (current-time-zone (seconds-to-time seconds)))

(defun org-gcal--format-iso2org (str &optional tz)
  (let* ((plst (org-gcal--parse-date str))
         (seconds (org-gcal--time-to-seconds plst)))
    (concat
     "<"
     (format-time-string
      (if (< 11 (length str)) "%Y-%m-%d %a %H:%M" "%Y-%m-%d %a")
      (seconds-to-time
       (+ (if tz (car (org-gcal--time-zone seconds)) 0)
          seconds)))
     ;;(if (and repeat (not (string= repeat ""))) (concat " " repeat) "")
     ">")))

(defun org-gcal--format-org2iso (year mon day &optional hour min tz)
  (let ((seconds (time-to-seconds (encode-time 0
                                               (or min 0)
                                               (or hour 0)
                                               day mon year))))
    (format-time-string
     (if (or hour min) "%Y-%m-%dT%H:%M:00Z" "%Y-%m-%d")
     (seconds-to-time
      (-
       seconds
       (if tz (car (org-gcal--time-zone seconds)) 0))))))

(defun org-gcal--iso-next-day (str &optional previous-p)
  (let ((format (if (< 11 (length str))
                    "%Y-%m-%dT%H:%M"
                  "%Y-%m-%d"))
        (plst (org-gcal--parse-date str))
        (prev (if previous-p -1 +1)))
    (format-time-string format
                        (seconds-to-time
                         (+ (org-gcal--time-to-seconds plst)
                            (* 60 60 24 prev))))))

(defun org-gcal--iso-previous-day (str)
  (org-gcal--iso-next-day str t))

(defun org-gcal--cons-list (plst)
  (let* ((smry  (or (plist-get plst :summary)
                    "busy"))
         (desc  (plist-get plst :description))
         (loc   (plist-get plst :location))
         (link  (plist-get plst :htmlLink))
         (event-id    (plist-get plst :id))
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
    (concat
     "* " smry "\n"
     "  :PROPERTIES:\n"
     (when loc "  :LOCATION: ") loc (when loc "\n")
     "  :LINK: ""[[" link "][Go to gcal web page]]\n"
     "  :ID: " event-id "\n"
     "  :END:\n"
     (if (or (string= start end) (org-gcal--alldayp start end))
         (concat "\n  "(org-gcal--format-iso2org start))
       (if (and
            (= (plist-get (org-gcal--parse-date start) :year)
               (plist-get (org-gcal--parse-date end)   :year))
            (= (plist-get (org-gcal--parse-date start) :mon)
               (plist-get (org-gcal--parse-date end)   :mon))
            (= (plist-get (org-gcal--parse-date start) :day)
               (plist-get (org-gcal--parse-date end)   :day)))
           (concat "\n  <"
                   (org-gcal--format-date start "%Y-%m-%d %a %H:%M")
                   "-"
                   (org-gcal--format-date end "%H:%M")
                   ">")
         (concat "\n  " (org-gcal--format-iso2org start)
                 "--"
                 (org-gcal--format-iso2org
                  (if (< 11 (length end))
                      end
                    (org-gcal--iso-previous-day end)))))) "\n"
     (when desc "\n")
     (when desc (replace-regexp-in-string "^\*" "✱" desc))
     (when desc (if (string= "\n" (org-gcal--safe-substring desc -1)) "" "\n")))))

(defun org-gcal--format-date (str format &optional tz)
  (let* ((plst (org-gcal--parse-date str))
         (seconds (org-gcal--time-to-seconds plst)))
    (concat
     (format-time-string format
                         (seconds-to-time
                          (+ (if tz (car (org-gcal--time-zone seconds)) 0)
                             seconds))))))

(defun org-gcal--param-date (str)
  (if (< 11 (length str)) "dateTime" "date"))

(defun org-gcal--param-date-alt (str)
  (if (< 11 (length str)) "date" "dateTime"))

(defun org-gcal--get-calendar-id-of-buffer ()
  "Find calendar id of current buffer."
  (or (cl-loop for (id . file) in org-gcal-file-alist
               if (file-equal-p file (buffer-file-name))
               return id)
      (user-error (concat "Buffer `%s' may not related to google calendar; "
                          "please check/configure `org-gcal-file-alist'")
                  (buffer-name))))

(defun org-gcal--post-event (start end smry loc desc calendar-id &optional event-id a-token skip-import skip-export)
  (let ((stime (org-gcal--param-date start))
        (etime (org-gcal--param-date end))
        (stime-alt (org-gcal--param-date-alt start))
        (etime-alt (org-gcal--param-date-alt end))
        (a-token (if a-token
                     a-token
                   (org-gcal--get-access-token))))
    (request
     (concat
      (format org-gcal-events-url calendar-id)
      (when event-id
        (concat "/" event-id)))
     :type (if event-id "PATCH" "POST")
     :headers '(("Content-Type" . "application/json"))
     :data (encode-coding-string
            (json-encode `(("start" (,stime . ,start) (,stime-alt . nil))
                           ("end" (,etime . ,(if (equal "date" etime)
                                                 (org-gcal--iso-next-day end)
                                               end)) (,etime-alt . nil))
                           ("summary" . ,smry)
                           ("location" . ,loc)
                           ("description" . ,desc)))
            'utf-8)
     :params `(("access_token" . ,a-token)
               ("key" . ,org-gcal-client-secret)
               ("grant_type" . "authorization_code"))

     :parser 'org-gcal--json-read
     :error (cl-function
             (lambda (&key response &allow-other-keys)
               (let ((status (request-response-status-code response))
                     (error-msg (request-response-error-thrown response)))
                 (cond
                  ((eq status 401)
                   (progn
                     (org-gcal--notify
                      "Received HTTP 401"
                      "OAuth token expired. Now trying to refresh-token")
                     (org-gcal-refresh-token 'org-gcal--post-event skip-export start end smry loc desc calendar-id event-id)))
                  (t
                   (org-gcal--notify
                    (concat "Status code: " (pp-to-string status))
                    (pp-to-string error-msg)))))))
     :success (cl-function
               (lambda (&key data &allow-other-keys)
                 (progn
                   (org-gcal--notify "Event Posted"
                                     (concat "Org-gcal post event\n  " (plist-get data :summary)))
                   (unless skip-import (org-gcal-fetch))))))))

(defun org-gcal--delete-event (event-id calendar-id &optional a-token skip-import skip-export)
  (let ((skip-import skip-import)
        (a-token (if a-token
                     a-token
                   (org-gcal--get-access-token))))
    (request
     (concat
      (format org-gcal-events-url calendar-id)
      (concat "/" event-id))
     :type "DELETE"
     :headers '(("Content-Type" . "application/json"))
     :params `(("access_token" . ,a-token)
               ("key" . ,org-gcal-client-secret)
               ("grant_type" . "authorization_code"))
     :error (cl-function
             (lambda (&key response &allow-other-keys)
               (let ((status (request-response-status-code response))
                     (error-msg (request-response-error-thrown response)))
                 (cond
                  ((eq status 401)
                   (progn
                     (org-gcal--notify
                      "Received HTTP 401"
                      "OAuth token expired. Now trying to refresh-token")
                     (org-gcal-refresh-token 'org-gcal--delete-event skip-export nil nil nil nil nil calendar-id event-id)))
                  (t
                   (org-gcal--notify
                    (concat "Status code: " (pp-to-string status))
                    (pp-to-string error-msg)))))))
     :success (cl-function
               (lambda (&key &allow-other-keys)
                 (progn
                   (org-gcal-fetch)
                   (org-gcal--notify "Event Deleted" "Org-gcal deleted event")))))))

(defun org-gcal--capture-post ()
  (dolist (i org-gcal-file-alist)
    (when (string=  (file-name-nondirectory (cdr i))
                    (substring (buffer-name) 8))
      (org-gcal-post-at-point))))

(add-hook 'org-capture-before-finalize-hook 'org-gcal--capture-post)

(defun org-gcal--ensure-token ()
  (cond
   (org-gcal-token-plist t)
   ((and (file-exists-p org-gcal-token-file)
         (ignore-errors
           (setq org-gcal-token-plist
                 (with-temp-buffer
                   (insert-file-contents org-gcal-token-file)
                   (plist-get (read (current-buffer)) :token))))) t)
   (t (org-gcal-request-token))))

(defun org-gcal--timestamp-successor ()
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

(defun org-gcal--notify (title message)
  "Send alert with TITLE and MESSAGE."
  (when org-gcal-notify-p
    (if org-gcal-logo-file
        (alert message :title title :icon org-gcal-logo-file)
      (alert message :title title))))

(defun org-gcal--time-to-seconds (plst)
  (time-to-seconds
   (encode-time
    (plist-get plst :sec)
    (plist-get plst :min)
    (plist-get plst :hour)
    (plist-get plst :day)
    (plist-get plst :mon)
    (plist-get plst :year))))


(provide 'org-gcal)

;;; org-gcal.el ends here
