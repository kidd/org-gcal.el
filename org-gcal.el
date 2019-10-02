;;; org-gcal.el --- Org sync with Google Calendar -*- lexical-binding: t -*-

;; Author: myuhe <yuhei.maeda_at_gmail.com>
;; URL: https://github.com/kidd/org-gcal.el
;; Version: 0.3
;; Maintainer: Raimon Grau <raimonster@gmail.com>
;; Copyright (C) :2014 myuhe all rights reserved.
;; Package-Requires: ((request "20190901") (request-deferred "20181129") (alert) (emacs "26"))
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
(require 'rx)

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

(defcustom org-gcal-fetch-file-alist nil
  "\
Association list '(calendar-id file). For each calendar-id,‘org-gcal-fetch’
and ‘org-gcal-sync’ will retrieve new events on the calendar and insert
them into the file."
  :group 'org-gcal
  :type '(alist :key-type (string :tag "Calendar Id") :value-type (file :tag "Org file")))

(defvaralias 'org-gcal-file-alist 'org-gcal-fetch-file-alist)

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

(defcustom org-gcal-calendar-id-property "calendar-id"
  "\
Org-mode property on org-gcal entries that records the Calendar ID."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-etag-property "ETag"
  "\
Org-mode property on org-gcal entries that records the ETag."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-drawer-name "org-gcal"
  "\
Name of drawer in which event time and description are stored on org-gcal
entries."
  :group 'org-gcal
  :type 'string)

(defvar org-gcal-token-plist nil
  "Token plist.")

(defconst org-gcal-auth-url "https://accounts.google.com/o/oauth2/auth"
  "Google OAuth2 server URL.")

(defconst org-gcal-token-url "https://www.googleapis.com/oauth2/v3/token"
  "Google OAuth2 server URL.")

(defconst org-gcal-resource-url "https://www.googleapis.com/auth/calendar"
  "URL used to request access to calendar resources.")

(defconst org-gcal-events-url "https://www.googleapis.com/calendar/v3/calendars/%s/events")

(cl-defstruct (org-gcal--event-entry
               (:constructor org-gcal--event-entry-create))
  ;; Entry ID. Created by ‘org-gcal--format-entry-id’.
  entry-id
  ;; Optional marker pointing to entry-id.
  marker
  ;; Optional Event resource fetched from server.
  event)

;;;###autoload
(defun org-gcal-sync (&optional a-token skip-export silent)
  "Import events from calendars.
Using A-TOKEN and export the ones to the calendar if unless
SKIP-EXPORT.  Set SILENT to non-nil to inhibit notifications."
  (interactive)
  (org-gcal--ensure-token)
  (when org-gcal-auto-archive
    (dolist (i org-gcal-fetch-file-alist)
      (with-current-buffer
          (find-file-noselect (cdr i))
        (org-gcal--archive-old-event))))
  (deferred:loop org-gcal-fetch-file-alist
    (lambda (x)
      (let* ((calendar-id (car x))
             (calendar-file (cdr x))
             (a-token (if a-token
                          a-token
                        (org-gcal--get-access-token)))

             (skip-export skip-export)
             (silent silent))
        (deferred:$
          (request-deferred
           (format org-gcal-events-url calendar-id)
           :type "GET"
           :params `(("access_token" . ,a-token)
                     ("key" . ,org-gcal-client-secret)
                     ("singleEvents" . "True")
                     ("orderBy" . "startTime")
                     ("timeMin" . ,(org-gcal--subtract-time))
                     ("timeMax" . ,(org-gcal--add-time))
                     ("grant_type" . "authorization_code"))
           :parser 'org-gcal--json-read)
          (deferred:nextc it
            (lambda (response)
              (let
                  ((data (request-response-data response))
                   (status-code (request-response-status-code response))
                   (error-thrown (request-response-error-thrown response)))
                (cond
                 ;; If there is no network connectivity, the response will
                 ;; not include a status code.
                 ((eq status-code nil)
                  (org-gcal--notify
                   "Got Error"
                   "Could not contact remote service. Please check your network connectivity.")
                  (error "Got error %S: %S" status-code error-thrown))
                 ((eq 401 (or (plist-get (plist-get (request-response-data response) :error) :code)
                              status-code))
                  (org-gcal--notify
                   "Received HTTP 401"
                   "OAuth token expired. Now trying to refresh-token")
                  (deferred:$
                    (org-gcal--refresh-token)
                    (deferred:nextc it
                      (lambda (a-token)
                        (org-gcal-sync a-token skip-export silent)))))
                 ((eq 403 status-code)
                  (org-gcal--notify "Received HTTP 403"
                                    "Ensure you enabled the Calendar API through the Developers Console, then try again.")
                  (error "Got error %S: %S" status-code error-thrown))
                 ;; We got some 2xx response, but for some reason no
                 ;; message body.
                 ((and (> 299 status-code) (eq data nil))
                  (org-gcal--notify
                   (concat "Received HTTP" (number-to-string status-code))
                   "Error occured, but no message body.")
                  (error "Got error %S: %S" status-code error-thrown))
                 ((not (eq error-thrown nil))
                  ;; Generic error-handler meant to provide useful
                  ;; information about failure cases not otherwise
                  ;; explicitly specified.
                  (org-gcal--notify
                   (concat "Status code: " (number-to-string status-code))
                   (pp-to-string error-thrown))
                  (error "Got error %S: %S" status-code error-thrown))
                 ;; Fetch was successful. Return the list of events retrieved for
                 ;; further processing.
                 (t
                  (org-gcal--filter (plist-get data :items)))))))
          ;; Iterate over all events. For previously unretrieved events, add
          ;; them to the bottom of the file. For retrieved events, just collect
          ;; them into a list and pass to the next step.
          (deferred:nextc it
            (lambda (events)
              (with-current-buffer (find-file-noselect calendar-file)
                (goto-char (point-max))
                (cl-loop
                 for event across events
                 if
                 (let* ((entry-id (org-gcal--format-entry-id
                                   calendar-id (plist-get event :id)))
                        (marker (org-id-find entry-id 'markerp)))
                   (cond
                    (marker
                     (org-gcal--event-entry-create
                      :entry-id entry-id
                      :marker marker
                      :event event))
                    (t
                     ;; Otherwise, insert a new entry into the
                     ;; default fetch file.
                     (insert "\n* ")
                     (org-gcal--update-entry calendar-id event)
                     nil)))
                 collect it))))
          ;; Find already retrieved entries and update them. This will update
          ;; events that have been moved from the default fetch file.
          (deferred:nextc it
            (lambda (entries)
              (deferred:loop entries
                (lambda (entry)
                  (deferred:$
                    (let ((marker (or (org-gcal--event-entry-marker entry)
                                      (org-id-find (org-gcal--event-entry-entry-id entry))))
                          (event (org-gcal--event-entry-event entry)))
                      (org-with-point-at marker
                        ;; If skipping exports, just overwrite current entry's
                        ;; calendar data with what's been retrieved from the
                        ;; server. Otherwise, sync the entry at the current
                        ;; point.
                        (set-marker marker nil)
                        (if (and skip-export event)
                            (progn
                              (org-gcal--update-entry calendar-id event)
                              (deferred:succeed nil))
                          (org-gcal-post-at-point nil skip-export))))
                    ;; Log but otherwise ignore errors.
                    (deferred:error it
                      (lambda (err)
                        (message "org-gcal-sync: error: %s" err))))))))
          (deferred:nextc it
            (lambda (_)
              (unless silent
                (org-gcal--notify "Completed event fetching ."
                                  (concat "Events fetched into\n" calendar-file)))
              (deferred:succeed nil))))))))

;;;###autoload
(defun org-gcal-fetch ()
  "Fetch event data from google calendar."
  (interactive)
  (org-gcal-sync nil t))

;;;###autoload
(defun org-gcal-sync-buffer (&optional _a-token skip-export silent)
  "\
Sync entries containing Calendar events in the currently-visible portion of the
buffer.

Uses access token A-TOKEN if non-nil.
Updates events on the server unless SKIP-EXPORT is set. In this case, events
modified on the server will overwrite entries in the buffer.
Set SILENT to non-nil to inhibit notifications."
  (interactive)
  (org-gcal--ensure-token)
  (let*
      ((name (or (buffer-file-name) (buffer-name)))
       (drawer-point
        (lambda ()
          (re-search-forward
           (format "^[ \t]*:%s:[ \t]*$" org-gcal-drawer-name)
           (point-max)
           'noerror)))
       (markers
        (save-excursion
          (goto-char (point-min))
          (cond
           ((eq major-mode 'org-mode)
            (cl-loop
             while (funcall drawer-point)
             collect (point-marker)))
           ((eq major-mode 'org-agenda-mode)
            (cl-loop
             while (not (eobp))
             if
             (let ((m (org-get-at-bol 'org-hd-marker)))
               (when m
                 (org-with-point-at m
                   (save-restriction
                     (org-narrow-to-element)
                     (if (funcall drawer-point)
                         (point-marker)
                       ;; No org-gcal drawer present - this is not an org-gcal
                       ;; entry, so skip it.
                       nil)))))
             collect it
             do (forward-line 1)))
           (t
            (user-error "Unsupported major mode %s in current buffer" major-mode))))))
    (deferred:$
      (deferred:loop markers
        (lambda (marker)
          (org-with-point-at marker
            (set-marker marker nil)
            (deferred:$
              (org-gcal-post-at-point nil skip-export)
              (deferred:error it
                (lambda (err)
                  (message "org-gcal-sync-buffer: error: %s" err)))))))
      (deferred:nextc it
        (lambda (_)
          (unless silent
            (org-gcal--notify "Completed syncing events in buffer."
                              (concat "Events synced in\n" name)))
          (deferred:succeed nil))))))

;;;###autoload
(defun org-gcal-fetch-buffer (&optional _a-token _skip-export _silent)
  "\
Fetch changes to events in the currently-visible portion of the buffer, not
writing any changes to Calendar."
  (interactive)
  (org-gcal-sync-buffer nil t))

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

(defun org-gcal--all-property-local-values (pom property literal-nil)
  "Return all values for PROPERTY in entry at point or marker POM.
Works like ‘org--property-local-values’, except that if multiple values of a
property whose key doesn’t contain a ‘+’ sign are present, this function will
return all of them. In particular, we wish to retrieve all local values of the
\"ID\" property. LITERAL-NIL also works the same way.

Does not preserve point."
  (org-with-point-at pom
    (org-gcal--back-to-heading)
    (let ((range (org-get-property-block)))
      (when range
        (goto-char (car range))
        (let* ((case-fold-search t)
               (end (cdr range))
               value)
          ;; Find values.
          (let* ((property+ (org-re-property
                             (concat (regexp-quote property) "\\+?") t t)))
            (while (re-search-forward property+ end t)
              (let ((v (match-string-no-properties 3)))
                (push (if literal-nil v (org-not-nil v)) value))))
          ;; Return final values.
          (and (not (equal value '(nil))) (nreverse value)))))))

(defun org-gcal--put-id (pom calendar-id event-id)
  "\
Store a canonical ID generated from CALENDAR-ID and EVENT-ID in the \":ID:\"
property at point-or-marker POM.
The existing \":ID\" entries at POM, if any, will be inserted after the
canonical ID, so that existing links won’t be broken."
  (org-with-point-at pom
    (org-gcal--back-to-heading)
    (let ((ids (org-gcal--all-property-local-values (point) "ID" nil))
          (entry-id (org-gcal--format-entry-id calendar-id event-id)))
      ;; First delete all existing IDs and insert canonical ID. This will put
      ;; it as the first ID in the entry.
      (org-entry-delete (point) "ID")
      (org-entry-put (point) "ID" entry-id)
      ;; Now find the ID just inserted and insert the other IDs in their
      ;; original order.
      (let* ((range (org-get-property-block)))
        (goto-char (car range))
        (re-search-forward
         (org-re-property "ID" nil t) (cdr range) t)
        ;; See ‘org-re-property’ - match 5 is the end of the line.
        (goto-char (match-end 5))
        (let ((indentation (match-string-no-properties 4)))
          (mapc
           (lambda (id)
             (newline)
             (insert indentation ":ID: " id))
           (cl-remove-if (lambda (x) (string= x entry-id)) ids)))))))

(defun org-gcal--event-id-from-entry-id (entry-id)
  "Parse an ENTRY-ID created by ‘org-gcal--format-entry-id’ and return EVENT-ID."
  (when
      (and entry-id
           (string-match
            (rx-to-string
             '(and
               string-start
               (submatch-n 1
                           (1+ (not (any ?/ ?\n))))
               (? ?/
                  (submatch-n 2 (1+ (not (any ?/ ?\n)))))
               string-end))
            entry-id))
    (match-string 1 entry-id)))

(defun org-gcal--format-entry-id (calendar-id event-id)
  "Format CALENDAR-ID and ENTRY-ID into a canonical ID for an Org mode entry."
  (format "%s/%s" event-id calendar-id))

(defun org-gcal--property-from-name (name)
  "\
Converts property names (as strings) to a symbol suitable for use as the
PROPERTY argument to ‘org-element-property’."
  (intern (concat ":" (upcase name))))

(defun org-gcal--back-to-heading ()
  "\
Call ‘org-back-to-heading’ with the invisible-ok argument set to true.
We always intend to go back to the invisible heading here."
  (org-back-to-heading 'invisible-ok))

;;;###autoload
(defun org-gcal-post-at-point (&optional skip-import skip-export)
  "\
Post entry at point to current calendar. This overwrites the event on the
server with the data from the entry, except if the ‘org-gcal-etag-property’ is
present and is out of sync with the server, in which case the entry is
overwritten with data from the server instead.

If SKIP-IMPORT is not nil, don’t overwrite the entry with data from the server.
If SKIP-EXPORT is not nil, don’t overwrite the event on the server."
  (interactive)
  (org-gcal--ensure-token)
  (save-excursion
    ;; Post entry at point in org-agenda buffer.
    (when (eq major-mode 'org-agenda-mode)
      (let ((m (org-get-at-bol 'org-hd-marker)))
        (set-buffer (marker-buffer m))
        (goto-char (marker-position m))))
    (end-of-line)
    (org-gcal--back-to-heading)
    (let* ((skip-import skip-import)
           (skip-export skip-export)
           (marker (point-marker))
           (elem (org-element-headline-parser (point-max) t))
           (smry (org-element-property :title elem))
           (loc (org-element-property :LOCATION elem))
           (event-id (org-gcal--event-id-from-entry-id
                      (org-element-property :ID elem)))
           (etag (org-element-property
                  (org-gcal--property-from-name org-gcal-etag-property)
                  elem))
           (calendar-id
            (org-element-property
             (org-gcal--property-from-name org-gcal-calendar-id-property)
             elem))
           (tobj) (start) (end) (desc))
      ;; Parse :org-gcal: drawer for event time and description.
      (goto-char (marker-position marker))
      (when
          (re-search-forward
            (format "^[ \t]*:%s:[ \t]*$" org-gcal-drawer-name)
            (save-excursion (outline-next-heading) (point))
            'noerror)
        ;; First read any event time from the drawer if present. It's located
        ;; at the beginning of the drawer.
        (save-excursion
          (when
              (re-search-forward "<[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
                                 (save-excursion (outline-next-heading) (point))
                                 'noerror)
            (goto-char (match-beginning 0))
            (setq tobj (org-element-timestamp-parser))))
        ;; Lines after the timestamp contain the description. Skip leading
        ;; blank lines.
        (forward-line)
        (beginning-of-line)
        (re-search-forward
         "\\(?:^[ \t]*$\\)*\\([^z-a]*?\\)\n?[ \t]*:END:"
         (save-excursion (outline-next-heading) (point)))
        (setq desc (match-string-no-properties 1))
        (setq desc
              (if (string-match-p "\\‘\n*\\’" desc)
                  nil
                (replace-regexp-in-string
                 "^✱" "*"
                 (replace-regexp-in-string
                  "\\`\\(?: *<[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].*?>$\\)\n?\n?"
                  ""
                  (replace-regexp-in-string
                   " *:PROPERTIES:\n *\\(.*\\(?:\n.*\\)*?\\) *:END:\n+"
                   ""
                   desc))))))
      ;; Prefer to read event time from the SCHEDULED property if present.
      (setq tobj (or (org-element-property :scheduled elem) tobj))
      (setq
       start
       (org-gcal--format-org2iso
        (plist-get (cadr tobj) :year-start)
        (plist-get (cadr tobj) :month-start)
        (plist-get (cadr tobj) :day-start)
        (plist-get (cadr tobj) :hour-start)
        (plist-get (cadr tobj) :minute-start)
        (when (plist-get (cadr tobj) :hour-start) t))
       end
       (org-gcal--format-org2iso
        (plist-get (cadr tobj) :year-end)
        (plist-get (cadr tobj) :month-end)
        (plist-get (cadr tobj) :day-end)
        (plist-get (cadr tobj) :hour-end)
        (plist-get (cadr tobj) :minute-end)
        (when (plist-get (cadr tobj) :hour-start) t)))
      (org-gcal--post-event start end smry loc desc calendar-id marker etag
                            event-id nil skip-import skip-export))))

;;;###autoload
(defun org-gcal-delete-at-point ()
  "Delete entry at point to current calendar."
  (interactive)
  (org-gcal--ensure-token)
  (save-excursion
    ;; Delete entry at point in org-agenda buffer.
    (when (eq major-mode 'org-agenda-mode)
      (let ((m (org-get-at-bol 'org-hd-marker)))
        (set-buffer (marker-buffer m))
        (goto-char (marker-position m))))
    (end-of-line)
    (org-gcal--back-to-heading)
    (let* ((marker (point-marker))
           (elem (org-element-headline-parser (point-max) t))
           (smry (org-element-property :title elem))
           (calendar-id
            (org-element-property
             (org-gcal--property-from-name org-gcal-calendar-id-property)
             elem))
           (etag (org-element-property
                  (org-gcal--property-from-name org-gcal-etag-property)
                  elem))
           (event-id (org-gcal--event-id-from-entry-id
                      (org-element-property :ID elem))))
      (when (and event-id
                 (y-or-n-p (format "Do you really want to delete event?\n\n%s\n\n" smry)))
        (org-gcal--delete-event calendar-id event-id etag marker)))))

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
  (deferred:$
    (request-deferred
     org-gcal-token-url
     :type "POST"
     :data `(("client_id" . ,org-gcal-client-id)
             ("client_secret" . ,org-gcal-client-secret)
             ("code" . ,(org-gcal-request-authorization))
             ("redirect_uri" .  "urn:ietf:wg:oauth:2.0:oob")
             ("grant_type" . "authorization_code"))
     :parser 'org-gcal--json-read)
    (deferred:nextc it
      (lambda (response)
        (let
            ((data (request-response-data response))
             (status-code (request-response-status-code response))
             (error-thrown (request-response-error-thrown response)))
          (cond
           ;; If there is no network connectivity, the response will not
           ;; include a status code.
           ((eq status-code nil)
            (org-gcal--notify
             "Got Error"
             "Could not contact remote service. Please check your network connectivity.")
            (error "Network connectivity issue %s: %s" status-code error-thrown))
           ;; Generic error-handler meant to provide useful information about
           ;; failure cases not otherwise explicitly specified.
           ((not (eq error-thrown nil))
            (org-gcal--notify
             (concat "Status code: " (number-to-string status-code))
             (pp-to-string error-thrown))
            (error "Got error %S: %S" status-code error-thrown))
           ;; Fetch was successful.
           (t
            (when data
              (setq org-gcal-token-plist data)
              (org-gcal--save-sexp data org-gcal-token-file))
            (deferred:succeed nil))))))))

(defun org-gcal--refresh-token ()
  "Refresh OAuth access and return the new access token as a deferred object."
  (deferred:$
    (request-deferred
     org-gcal-token-url
     :type "POST"
     :data `(("client_id" . ,org-gcal-client-id)
             ("client_secret" . ,org-gcal-client-secret)
             ("refresh_token" . ,(org-gcal--get-refresh-token))
             ("grant_type" . "refresh_token"))
     :parser 'org-gcal--json-read)
    (deferred:nextc it
      (lambda (response)
        (let ((data (request-response-data response))
              (status-code (request-response-status-code response))
              (error-thrown (request-response-error-thrown response)))
          (cond
           ((eq error-thrown nil)
            (plist-put org-gcal-token-plist
                       :access_token
                       (plist-get data :access_token))
            (org-gcal--save-sexp org-gcal-token-plist org-gcal-token-file)
            (let ((_token (plist-get org-gcal-token-plist :access_token)))
              (deferred:succeed nil)))
           (t
            (error "Got error %S: %S" status-code error-thrown))))))))

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
         (concat org-gcal-token-file " does not exist.")
         (concat "Please create " org-gcal-token-file " before proceeding."))))))

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

(defun org-gcal--update-entry (calendar-id event)
  "\
Update the entry at the current heading with information from EVENT, which is
parsed from the Calendar API JSON response using
‘org-gcal--json-read’. Point must be located on an Org-mode heading line or
an error will be thrown. Point is not preserved."
  (unless (org-at-heading-p)
    (user-error "Must be on Org-mode heading."))
  (let* ((smry  (or (plist-get event :summary)
                    "busy"))
         (desc  (plist-get event :description))
         (loc   (plist-get event :location))
         (_link  (plist-get event :htmlLink))
         (meet  (plist-get event :hangoutLink))
         (etag (plist-get event :etag))
         (event-id    (plist-get event :id))
         (stime (plist-get (plist-get event :start)
                           :dateTime))
         (etime (plist-get (plist-get event :end)
                           :dateTime))
         (sday  (plist-get (plist-get event :start)
                           :date))
         (eday  (plist-get (plist-get event :end)
                           :date))
         (start (if stime stime sday))
         (end   (if etime etime eday))
         (elem))
    (when loc (replace-regexp-in-string "\n" ", " loc))
    (org-edit-headline smry)
    (org-entry-put (point) org-gcal-etag-property etag)
    (when loc (org-entry-put (point) "LOCATION" loc))
    (when meet
      (org-entry-put
       (point)
       "HANGOUTS"
       (format "[[%s][%s]]"
               meet
               "Join Hangouts Meet")))
    (org-entry-put (point) org-gcal-calendar-id-property calendar-id)
    (org-gcal--put-id (point) calendar-id event-id)
    ;; Insert event time and description in :ORG-GCAL: drawer, erasing the
    ;; current contents.
    (org-gcal--back-to-heading)
    (setq elem (org-element-at-point))
    (save-excursion
      (when (re-search-forward
             (format
              "^[ \t]*:%s:[^z-a]*?\n[ \t]*:END:[ \t]*\n?"
              (regexp-quote org-gcal-drawer-name))
             (save-excursion (outline-next-heading) (point))
             'noerror)
        (replace-match "" 'fixedcase)))
    (unless (re-search-forward ":PROPERTIES:[^z-a]*?:END:"
                       (save-excursion (outline-next-heading) (point))
                       'noerror)
        (message "PROPERTIES not found: %s (%s) %d"
                 (buffer-name) (buffer-file-name) (point)))
    (end-of-line)
    (newline)
    (insert (format ":%s:" org-gcal-drawer-name))
    (newline)
    (let*
        ((timestamp
          (if (or (string= start end) (org-gcal--alldayp start end))
              (org-gcal--format-iso2org start)
              (format "%s--%s"
                      (org-gcal--format-iso2org start)
                      (org-gcal--format-iso2org
                       (if (< 11 (length end))
                           end
                         (org-gcal--iso-previous-day end)))))))
      (if (org-element-property :scheduled elem)
          (org-schedule nil timestamp)
        (insert timestamp)
        (newline)
        (when desc (newline))))
    ;; Insert event description if present.
    (when desc
      (insert (replace-regexp-in-string "^\*" "✱" desc))
      (insert (if (string= "\n" (org-gcal--safe-substring desc -1)) "" "\n")))
    (insert ":END:")))

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
  (or (cl-loop for (id . file) in org-gcal-fetch-file-alist
               if (file-equal-p file (buffer-file-name (buffer-base-buffer)))
               return id)
      (user-error (concat "Buffer `%s' may not related to google calendar; "
                          "please check/configure `org-gcal-fetch-file-alist'")
                  (buffer-name))))

(defun org-gcal--get-event (calendar-id event-id &optional a-token)
  "\
Retrieves a Google Calendar event given a CALENDAR-ID and EVENT-ID. If the
access token A-TOKEN is not specified, it is loaded from the token file.

Returns a ‘deferred’ function that on success returns a ‘request-response‘
object."
  (let ((a-token (if a-token
                     a-token
                   (org-gcal--get-access-token))))
    (deferred:$
      (request-deferred
       (concat
        (format org-gcal-events-url calendar-id)
        (concat "/" event-id))
       :type "GET"
       :headers '(("Content-Type" . "application/json"))
       :params `(("access_token" . ,a-token)
                 ("key" . ,org-gcal-client-secret)
                 ("grant_type" . "authorization_code"))
       :parser 'org-gcal--json-read)
      (deferred:nextc it
        (lambda (response)
          (let
              ((_data (request-response-data response))
               (status-code (request-response-status-code response))
               (error-thrown (request-response-error-thrown response)))
            (cond
             ;; If there is no network connectivity, the response will not
             ;; include a status code.
             ((eq status-code nil)
              (org-gcal--notify
               "Got Error"
               "Could not contact remote service. Please check your network connectivity.")
              (error "Network connectivity issue"))
             ((eq 401 (or (plist-get (plist-get (request-response-data response) :error) :code)
                          status-code))
              (org-gcal--notify
               "Received HTTP 401"
               "OAuth token expired. Now trying to refresh token.")
              (deferred:$
                (org-gcal--refresh-token)
                (deferred:nextc it
                  (lambda (a-token)
                    (org-gcal--get-event calendar-id event-id a-token)))))
             ;; Generic error-handler meant to provide useful information about
             ;; failure cases not otherwise explicitly specified.
             ((not (eq error-thrown nil))
              (org-gcal--notify
               (concat "Status code: " (number-to-string status-code))
               (pp-to-string error-thrown))
              (error "Got error %S: %S" status-code error-thrown))
             ;; Fetch was successful.
             (t response))))))))

(defun org-gcal--post-event (start end smry loc desc calendar-id marker &optional etag event-id a-token skip-import skip-export)
  "\
Creates or updates an event on Calendar CALENDAR-ID with attributes START, END,
SMRY, LOC, DESC. The Org buffer and point from which the event is read is given
by MARKER.

If ETAG is provided, it is used to retrieve the event data from the server and
overwrite the event at MARKER if the event has changed on the server. MARKER is
destroyed by this function.

Returns a ‘deferred’ object that can be used to wait for completion."
  (let ((stime (org-gcal--param-date start))
        (etime (org-gcal--param-date end))
        (stime-alt (org-gcal--param-date-alt start))
        (etime-alt (org-gcal--param-date-alt end))
        (a-token (if a-token
                     a-token
                   (org-gcal--get-access-token))))
    (deferred:try
      (deferred:$
        (request-deferred
         (concat
          (format org-gcal-events-url calendar-id)
          (when (and event-id etag)
            (concat "/" event-id)))
         :type (if event-id "PATCH" "POST")
         :headers (append
                   '(("Content-Type" . "application/json"))
                   (if (null etag) nil
                     `(("If-Match" . ,etag))))
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

         :parser 'org-gcal--json-read)
        (deferred:nextc it
          (lambda (response)
            (let
                ((_temp (request-response-data response))
                 (status-code (request-response-status-code response))
                 (error-msg (request-response-error-thrown response)))
              (cond
               ;; If there is no network connectivity, the response will not
               ;; include a status code.
               ((eq status-code nil)
                (org-gcal--notify
                 "Got Error"
                 "Could not contact remote service. Please check your network connectivity.")
                (error "Network connectivity issue"))
               ((eq 401 (or (plist-get (plist-get (request-response-data response) :error) :code)
                            status-code))
                (org-gcal--notify
                 "Received HTTP 401"
                 "OAuth token expired. Now trying to refresh-token")
                (deferred:$
                  (org-gcal--refresh-token)
                  (deferred:nextc it
                    (lambda (a-token)
                      (org-gcal--post-event start end smry loc desc calendar-id
                                            marker etag event-id a-token
                                            skip-import skip-export)))))
               ;; ETag on current entry is stale. This means the event on the
               ;; server has been updated. In that case, update the event using
               ;; the data from the server.
               ((eq status-code 412)
                (unless skip-import
                  (org-gcal--notify
                   "Received HTTP 412"
                   "ETag stale - will overwrite this entry with event from server.")
                  (deferred:$
                    (org-gcal--get-event calendar-id event-id a-token)
                    (deferred:nextc it
                      (lambda (response)
                        (save-excursion
                          (with-current-buffer (marker-buffer marker)
                            (goto-char (marker-position marker))
                            (org-gcal--update-entry
                             calendar-id
                             (request-response-data response))))
                        (deferred:succeed nil))))))
               ;; Generic error-handler meant to provide useful information about
               ;; failure cases not otherwise explicitly specified.
               ((not (eq error-msg nil))
                (org-gcal--notify
                 (concat "Status code: " (number-to-string status-code))
                 (pp-to-string error-msg))
                (error "Got error %S: %S" status-code error-msg))
               ;; Fetch was successful.
               (t
                (unless skip-export
                  (let* ((data (request-response-data response)))
                    (save-excursion
                      (with-current-buffer (marker-buffer marker)
                        (goto-char (marker-position marker))
                        ;; Update the entry to add ETag, as well as other
                        ;; properties if this is a newly-created event.
                        (org-gcal--update-entry calendar-id data)))
                    (org-gcal--notify "Event Posted"
                                      (concat "Org-gcal post event\n  " (plist-get data :summary)))))
                (deferred:succeed nil)))))))
      :finally
      (lambda ()
        (set-marker marker nil)))))


(defun org-gcal--delete-event (calendar-id event-id etag marker &optional a-token)
  "\
Deletes an event on Calendar CALENDAR-ID with EVENT-ID. The Org buffer and
point from which the event is read is given by MARKER. MARKER is destroyed by
this function.

If ETAG is provided, it is used to retrieve the event data from the server and
overwrite the event at MARKER if the event has changed on the server.

Returns a ‘deferred’ object that can be used to wait for completion."
  (let ((a-token (if a-token
                     a-token
                   (org-gcal--get-access-token))))
    (deferred:try
      (deferred:$
        (request-deferred
         (concat
          (format org-gcal-events-url calendar-id)
          (concat "/" event-id))
         :type "DELETE"
         :headers (append
                   '(("Content-Type" . "application/json"))
                   (if (null etag) nil
                     `(("If-Match" . ,etag))))
         :params `(("access_token" . ,a-token)
                   ("key" . ,org-gcal-client-secret)
                   ("grant_type" . "authorization_code"))

         :parser 'org-gcal--json-read)
        (deferred:nextc it
          (lambda (response)
            (let
                ((_temp (request-response-data response))
                 (status-code (request-response-status-code response))
                 (error-msg (request-response-error-thrown response)))
              (cond
               ;; If there is no network connectivity, the response will not
               ;; include a status code.
               ((eq status-code nil)
                (org-gcal--notify
                 "Got Error"
                 "Could not contact remote service. Please check your network connectivity.")
                (error "Network connectivity issue"))
               ((eq 401 (or (plist-get (plist-get (request-response-data response) :error) :code)
                            status-code))
                (org-gcal--notify
                 "Received HTTP 401"
                 "OAuth token expired. Now trying to refresh-token")
                (deferred:$
                  (org-gcal--refresh-token)
                  (deferred:nextc it
                    (lambda (a-token)
                      (org-gcal--delete-event calendar-id event-id
                                              etag marker a-token)))))
               ;; ETag on current entry is stale. This means the event on the
               ;; server has been updated. In that case, update the event using
               ;; the data from the server.
               ((eq status-code 412)
                (org-gcal--notify
                 "Received HTTP 412"
                 "ETag stale - will overwrite this entry with event from server.")
                (deferred:$
                  (org-gcal--get-event calendar-id event-id a-token)
                  (deferred:nextc it
                    (lambda (response)
                      (save-excursion
                        (with-current-buffer (marker-buffer marker)
                          (goto-char (marker-position marker))
                          (org-gcal--update-entry
                           calendar-id
                           (request-response-data response))))))))
               ;; Generic error-handler meant to provide useful information about
               ;; failure cases not otherwise explicitly specified.
               ((not (eq error-msg nil))
                (org-gcal--notify
                 (concat "Status code: " (number-to-string status-code))
                 (pp-to-string error-msg))
                (error "Got error %S: %S" status-code error-msg))
               ;; Fetch was successful.
               (t
                (org-gcal--notify "Event Deleted" "Org-gcal deleted event")))))))
      :finally
      (lambda ()
        (set-marker marker nil)))))

(defun org-gcal--capture-post ()
  (dolist (i org-gcal-fetch-file-alist)
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
   (t (deferred:sync! (org-gcal-request-token)))))

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
