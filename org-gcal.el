;;; org-gcal.el --- Org sync with Google Calendar -*- lexical-binding: t -*-

;; Author: myuhe <yuhei.maeda_at_gmail.com>
;; URL: https://github.com/kidd/org-gcal.el
;; Version: 0.4.2
;; Maintainer: Raimon Grau <raimonster@gmail.com>
;; Copyright (C) :2014 myuhe all rights reserved.
;; Keywords: convenience,

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
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
(require 'aio)
;; Not on MELPA yet. Must install from https://github.com/rhaps0dy/emacs-oauth2-auto.
(require 'oauth2-auto)
(require 'ol)
(require 'org)
(require 'org-archive)
(require 'org-clock)
(require 'org-element)
(require 'org-generic-id)
(require 'org-id)
(require 'parse-time)
(require 'persist)
(require 'request-deferred)
(require 'cl-lib)
(require 'rx)
(require 'subr-x)

;; Customization
;;; Code:

(defgroup org-gcal nil "Org sync with Google Calendar"
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

(defvaralias 'org-gcal-file-alist 'org-gcal-fetch-file-alist)

(defcustom org-gcal-fetch-file-alist nil
  "\
Association list '(calendar-id file). For each calendar-id,‘org-gcal-fetch’
and ‘org-gcal-sync’ will retrieve new events on the calendar and insert
them into the file."
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

(defcustom org-gcal-update-cancelled-events-with-todo t
  "If ‘t’, mark cancelled events with the TODO keyword in
‘org-gcal-cancelled-todo-keyword’."
  :group 'org-gcal
  :type 'boolean)

(defcustom org-gcal-cancelled-todo-keyword "CANCELLED"
  "TODO keyword to use for cancelled events."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-local-timezone nil
  "Org-gcal local timezone. timezone value should use 'TZ
database name', which can be found in
'https://en.wikipedia.org/wiki/List_of_tz_database_time_zones'."
  :group 'org-gcal
  :type 'string)

(defvaralias 'org-gcal-remove-cancelled-events 'org-gcal-remove-api-cancelled-events)
(defcustom org-gcal-remove-api-cancelled-events 'ask
  "Whether to remove Org-mode headlines for events cancelled in Google Calendar.

The events will always be marked cancelled before they’re removed if
‘org-gcal-update-cancelled-events-with-todo’ is true."
  :group 'org-gcal
  :type '(choice
          (const :tag "Never remove" nil)
          (const :tag "Prompt whether to remove" 'ask)
          (const :tag "Always remove without prompting" t)))

(defcustom org-gcal-remove-events-with-cancelled-todo nil
  "Whether to attempt to remove Org-mode headlines for cancelled events.
Specifically effects events marked with ‘org-gcal-cancelled-todo-keyword’.

By default, this is set to nil so that if you decline removing an event when
‘org-gcal-remove-api-cancelled-events’ is set to ‘ask’, you won’t be prompted
to remove the event again.  Set to t to override this.

Note that whether a headline is removed is still controlled by
‘org-gcal-remove-api-cancelled-events’."
  :group 'org-gcal
  :type 'boolean)

(defcustom org-gcal-managed-newly-fetched-mode "gcal"
  "Default value of ‘org-gcal-managed-property’ on newly-fetched events.

This is the value set on events fetched from a calendar by ‘org-gcal-sync’ and
‘org-gcal-fetch’.

Values:

- “org”: Event is intended to be managed primarily by org-gcal. These events
  will be pushed to Google Calendar by ‘org-gcal-sync’, ‘org-gcal-sync-buffer’,
  and ‘org-gcal-post-at-point’ if they have been modified in the Org file. If
  the ETag is out of sync with Google Calendar, the Org headline will still be
  updated from Google Calendar.
- “gcal”: Event is intended to be managed primarily by org-gcal. These events
  will not be pushed to Google Calendar by bulk update functions like
  ‘org-gcal-sync’, ‘org-gcal-sync-buffer’. When running
  ‘org-gcal-post-at-point’, the user will be prompted to approve pushing the
  event by default."
  :group 'org-gcal
  :type '(choice
          (const :tag "Event managed on Google Calendar" "gcal")
          (const :tag "Event managed in Org file" "org")))

(defcustom org-gcal-managed-update-existing-mode "gcal"
  "Default value of ‘org-gcal-managed-property’ for existing events without it.

This is the value set on existing entries containing calendar events when they
are updated by ‘org-gcal-sync’, ‘org-gcal-fetch', or ‘org-gcal-post-at-point’
and don’t yet have a value for ‘org-gcal-managed-property’ set.

Values: see ‘org-gcal-managed-newly-fetched-mode’."
  :group 'org-gcal
  :type '(choice
          (const :tag "Event managed on Google Calendar" "gcal")
          (const :tag "Event managed in Org file" "org")))

(defcustom org-gcal-managed-create-from-entry-mode "org"
  "Default value of ‘org-gcal-managed-property’ when creating event from entry.

This is the value set when ‘org-gcal-post-at-point’ creates a Google Calendar
event from an Org-mode entry. This is used when ‘org-gcal-calendar-id-property’
or ‘org-gcal-entry-id-property’ is missing from an entry. If these are present,
‘org-gcal-managed-update-existing-mode’ is used instead.

Values: see ‘org-gcal-managed-newly-fetched-mode’."
  :group 'org-gcal
  :type '(choice
          (const :tag "Event managed on Google Calendar" "gcal")
          (const :tag "Event managed in Org file" "org")))

(defcustom org-gcal-managed-post-at-point-update-existing 'prompt
  "Behavior when running ‘org-gcal-post-at-point’ on existing entries."

  :group 'org-gcal
  :type '(choice
          (const :tag "Never push to Google Calendar" 'never-push)
          (const :tag "Prompt whether to push to Google Calendar if run manually, never push during syncs" 'prompt)
          (const :tag "Prompt whether to push to Google Calendar, even during syncs" 'prompt-sync)
          (const :tag "Always push to Google Calendar" 'always-push)))

(defcustom org-gcal-recurring-events-mode 'top-level
  "How to treat instances of recurring events not already fetched.

- ‘top-level’: insert all instances at the top level of the appropriate file for
  the calendar ID in ‘org-gcal-fetch-file-alist’.
- ‘nested’: insert instances of a recurring event under the Org-mode headline
  containing the parent event. If a headline for the parent event doesn’t exist,
  it will be created."
  :group 'org-gcal
  :type '(choice
          (const :tag "Insert at top level" 'top-level)
          (const :tag "Insert under headline for parent event" 'nested)))

(defcustom org-gcal-after-update-entry-functions nil
  "List of functions to run just before ‘org-gcal--update-entry’ returns.

This is the function called when an event is created, updated, or deleted. Each
function in the list is called with the following arguments:

- CALENDAR-ID: the calendar ID of the event, as a string.
- EVENT: the event data downloaded from the Google Calendar API and parsed using
  ‘org-gcal--json-read'.
- UPDATE-MODE: a symbol, one of
  - NEWLY-FETCHED: the event is newly fetched (see
    ‘org-gcal-managed-newly-fetched-mode').
  - UPDATE-EXISTING: a headline with existing calendar and event IDs is being
    updated (see ‘org-gcal-managed-update-existing-mode').
  - CREATE-FROM-ENTRY: a headline without existing calendar and event IDs is
    being updated (see ‘org-gcal-managed-create-from-entry-mode’)."
  :group 'org-gcal
  :type 'list)

(defcustom org-gcal-entry-id-property "entry-id"
  "\
Org-mode property on org-gcal entries that records the calendar and event ID."
  :group 'org-gcal
  :type 'string)

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

(defcustom org-gcal-managed-property "org-gcal-managed"
  " Org-mode property on org-gcal entries that records how an event is managed.

  For values the property can take, see ‘org-gcal-managed-newly-fetched-mode’."
  :group 'org-gcal
  :type 'string)

(defcustom org-gcal-drawer-name "org-gcal"
  "\
Name of drawer in which event time and description are stored on org-gcal
entries."
  :group 'org-gcal
  :type 'string)

(defvar org-gcal--sync-lock nil
  "Set if a sync function is running.")

(defvar org-gcal-token-plist nil
  "Token plist.")

(defcustom org-gcal-default-transparency "opaque"
  "The default value to use for transparency when creating a new event.

See: https://developers.google.com/calendar/v3/reference/events/insert."
  :group 'org-gcal
  :type 'string)

(defun org-gcal-events-url (calendar-id)
  "URL used to request access to events on calendar CALENDAR-ID."
  (format "https://www.googleapis.com/calendar/v3/calendars/%s/events"
          (url-hexify-string calendar-id)))

(defun org-gcal-instances-url (calendar-id event-id)
  "URL used to request access to instances of recurring events.
Returns a URL for recurrent event EVENT-ID on calendar CALENDAR-ID."
  (format "https://www.googleapis.com/calendar/v3/calendars/%s/events/%s/instances"
          (url-hexify-string calendar-id)
          (url-hexify-string event-id)))

(cl-defstruct (org-gcal--event-entry
               (:constructor org-gcal--event-entry-create))
  ;; Entry ID. Created by ‘org-gcal--format-entry-id’.
  entry-id
  ;; Optional marker pointing to entry-id.
  marker
  ;; Optional Event resource fetched from server.
  event)

(persist-defvar
 org-gcal--sync-tokens nil
 "Storage for Calendar API sync tokens, used for performing incremental sync.

This is a a hash table mapping calendar IDs (as given in
‘org-gcal-fetch-file-alist’) to a list (EXPIRES SYNC-TOKEN).  EXPIRES is an
Emacs time value that stores the time after which we should perform a full sync
instead of an incremental sync using the SYNC-TOKEN stored from the Calendar
API.

Persisted between sessions of Emacs.  To clear sync tokens, call
‘org-gcal-sync-tokens-clear’.")

(defmacro org-gcal--sync-tokens-get (key &optional remove?)
  "Get KEY from ‘org-gcal--sync-tokens’, or nil if not found.

This is a macro instead of a function so that it can be used as a place
expression in ‘setf’.  In that case, if REMOVE? is non-nil, the key-value
pair will be removed instead of set."
  `(alist-get ,key org-gcal--sync-tokens nil ,remove? #'equal))

;;;###autoload
(defun org-gcal-sync (&optional skip-export silent)
  "Import events from calendars.
Export the ones to the calendar if unless
SKIP-EXPORT.  Set SILENT to non-nil to inhibit notifications."
  (interactive)
  (when org-gcal--sync-lock
    (user-error "org-gcal sync locked. If a previous sync has failed, call ‘org-gcal--sync-unlock’ to reset the lock and try again."))
  (org-gcal--sync-lock)
  (org-generic-id-update-id-locations org-gcal-entry-id-property)
  (when org-gcal-auto-archive
    (dolist (i org-gcal-fetch-file-alist)
      (with-current-buffer
          (find-file-noselect (cdr i))
        (org-gcal--archive-old-event))))
  (let ((up-time (org-gcal--up-time))
        (down-time (org-gcal--down-time)))
    (deferred:try
      (deferred:$
        (deferred:loop org-gcal-fetch-file-alist
          (lambda (calendar-id-file)
            (deferred:$
              (org-gcal--sync-calendar calendar-id-file skip-export silent
                                       up-time down-time)
              (deferred:succeed nil)
              (deferred:nextc it
                (lambda (_)
                  (org-gcal--notify "Completed event fetching ."
                                    (concat "Events fetched into\n"
                                            (cdr calendar-id-file))
                                    silent)
                  (deferred:succeed nil))))))
        ;; After syncing new events to Org, sync existing events in Org.
        (deferred:nextc it
          (lambda (_)
            (org-generic-id-update-id-locations org-gcal-entry-id-property)
            (when t
              (mapc
               (lambda (file)
                 (with-current-buffer (find-file-noselect file 'nowarn)
                   (org-with-wide-buffer
                    (org-gcal--sync-unlock)
                    (org-gcal-sync-buffer skip-export silent 'filter-time
                                          'filter-managed))))
               (org-generic-id-files))))))
      :finally
      (lambda ()
        (org-gcal--sync-unlock)))))


(defun org-gcal--sync-calendar (calendar-id-file skip-export silent
                                up-time down-time)
  "Sync events for CALENDAR-ID-FILE

CALENDAR-ID-FILE is a cons in ‘org-gcal-fetch-file-alist’, for which see."
  (let* (
         ;; Need to add a dummy value to the beginning of the list to generate a
         ;; unique list that can be modified in
         ;; ‘org-gcal--sync-calendar-events’. Later we’ll strip this first
         ;; element.
         (parent-events (list 'dummy)))
    (deferred:$
      (org-gcal--sync-calendar-events
       calendar-id-file skip-export silent nil up-time down-time parent-events)
      (deferred:nextc it
        (lambda (_)
          (deferred:loop
            ;; Strip dummy first element and remove duplicates
            (cl-remove-duplicates (cdr parent-events) :test #'string=)
            (lambda (parent-event-id)
              (when (eq org-gcal-recurring-events-mode 'nested)
                (deferred:$
                  (org-gcal--sync-event
                   calendar-id-file parent-event-id skip-export)
                  (org-gcal--sync-instances
                   calendar-id-file parent-event-id skip-export silent nil
                   up-time down-time))))))))))

(defun org-gcal--sync-calendar-events
    (calendar-id-file skip-export silent page-token up-time down-time
     parent-events)
  "Sync events for CALENDAR-ID-FILE

CALENDAR-ID-FILE is a cons in ‘org-gcal-fetch-file-alist’, for which see."
  (let* ((calendar-id (car calendar-id-file))
         (calendar-file (cdr calendar-id-file))
         (page-token-cons '(dummy)))
    (deferred:$
      (org-gcal--sync-request-events calendar-id page-token up-time down-time)
      (deferred:nextc it
        (lambda (response)
          (let ((retry-fn
                 (lambda ()
                   (org-gcal--sync-calendar-events
                    calendar-id-file skip-export silent page-token
                    up-time down-time parent-events))))
            (org-gcal--sync-handle-response
             response calendar-id-file page-token-cons down-time retry-fn))))
      (deferred:nextc it
        (lambda (events)
          (org-gcal--sync-handle-events calendar-id calendar-file
                                        events nil up-time down-time
                                        parent-events)))
      (deferred:nextc it
        (lambda (entries)
          (org-gcal--sync-update-entries calendar-id entries skip-export)))
      ;; Retrieve the next page of results if needed.
      (deferred:nextc it
        (lambda (_)
          (let ((pt (car (last page-token-cons))))
            (if pt
                (org-gcal--sync-calendar-events
                 calendar-id-file skip-export silent pt
                 up-time down-time parent-events)
              (deferred:succeed nil))))))))

(defun org-gcal--sync-instances
    (calendar-id-file parent-event-id skip-export silent page-token
                      up-time down-time)
  "Sync instances of instances of recurring event PARENT-EVENT-ID.

CALENDAR-ID-FILE is a cons in ‘org-gcal-fetch-file-alist’, for which see."
  (let* ((calendar-id (car calendar-id-file))
         (calendar-file (cdr calendar-id-file))
         (page-token-cons '(dummy)))
    (deferred:$
      (org-gcal--sync-request-instances calendar-id parent-event-id
                                        up-time down-time page-token)
      (deferred:nextc it
        (lambda (response)
          (let ((retry-fn
                 (lambda ()
                   (org-gcal--sync-instances
                    calendar-id-file parent-event-id skip-export silent
                    page-token up-time down-time))))
            (org-gcal--sync-handle-response
             response calendar-id-file page-token-cons down-time retry-fn))))
      (deferred:nextc it
        (lambda (events)
          (org-gcal--sync-handle-events calendar-id calendar-file
                                        events t up-time down-time nil)))
      (deferred:nextc it
        (lambda (entries)
          (org-gcal--sync-update-entries calendar-id entries skip-export)))
      ;; Retrieve the next page of results if needed.
      (deferred:nextc it
        (lambda (_)
          (let ((pt (car (last page-token-cons))))
            (if pt
                (org-gcal--sync-instances
                 calendar-id-file parent-event-id skip-export silent
                 pt up-time down-time)
              (deferred:succeed nil))))))))

(defun org-gcal--sync-event
    (calendar-id-file event-id skip-export)
  "Sync a single event given by EVENT-ID

CALENDAR-ID-FILE is a cons in ‘org-gcal-fetch-file-alist’, for which see."
  (let* ((calendar-id (car calendar-id-file))
         (calendar-file (cdr calendar-id-file)))

    (deferred:$
      (org-gcal--get-event calendar-id event-id)
      (deferred:nextc it
        (lambda (event) (vector (request-response-data event))))
      (deferred:nextc it
        (lambda (events)
          (org-gcal--sync-handle-events calendar-id calendar-file
                                        events nil nil nil nil)))
      (deferred:nextc it
        (lambda (entries)
          (org-gcal--sync-update-entries calendar-id entries skip-export))))))

(defun org-gcal--sync-request-events
    (calendar-id page-token up-time down-time)
  "Request events on CALENDAR-ID, using PAGE-TOKEN if present."
  (request-deferred
   (org-gcal-events-url calendar-id)
   :type "GET"
   :headers
   `(("Accept" . "application/json")
     ("Authorization" . ,(format "Bearer %s" (org-gcal--get-access-token calendar-id))))
   :params
   (append
    `(("access_token" . ,(org-gcal--get-access-token calendar-id))
      ("singleEvents" . "True"))
    (when org-gcal-local-timezone `(("timeZone" . ,org-gcal-local-timezone)))
    (seq-let [expires sync-token]
        ;; Ensure ‘org-gcal--sync-tokens-get’ return value is actually a list
        ;; before passing to ‘seq-let’.
        (when-let
            ((x (org-gcal--sync-tokens-get calendar-id))
             ((listp x)))
          x)
      (cond
       ;; Don't use the sync token if it's expired.
       ((and expires sync-token
             (time-less-p (current-time) expires))
        `(("syncToken" . ,sync-token)))
       (t
        (setf (org-gcal--sync-tokens-get calendar-id 'remove) nil)
        `(("timeMin" . ,(org-gcal--format-time2iso up-time))
          ("timeMax" . ,(org-gcal--format-time2iso down-time))))))
    (when page-token `(("pageToken" . ,page-token))))
   :parser 'org-gcal--json-read))

(defun org-gcal--sync-request-instances
    (calendar-id event-id up-time down-time page-token)
  "Request instances of recurring event EVENT-ID on CALENDAR-ID."
  (request-deferred
   (org-gcal-instances-url calendar-id event-id)
   :type "GET"
   :headers
   `(("Accept" . "application/json")
     ("Authorization" . ,(format "Bearer %s" (org-gcal--get-access-token calendar-id))))
   :params
   (append
    `(("access_token" . ,(org-gcal--get-access-token calendar-id))
      ("timeMin" . ,(org-gcal--format-time2iso up-time))
      ("timeMax" . ,(org-gcal--format-time2iso down-time)))
    (when page-token `(("pageToken" . ,page-token))))
   :parser 'org-gcal--json-read))

(defun org-gcal--sync-handle-response
    (response calendar-id-file page-token-cons down-time retry-fn)
  "Handle RESPONSE in ‘org-gcal--sync-calendar' for CALENDAR-ID-FILE.

Update PAGE-TOKEN from the response, and return a ‘deferred’ list of event
objects for further processing."
  (let
      ((data (request-response-data response))
       (status-code (request-response-status-code response))
       (error-thrown (request-response-error-thrown response))
       (calendar-id (car calendar-id-file)))
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
        (org-gcal--refresh-token calendar-id)
        (deferred:nextc it
          (lambda (_unused)
            (funcall retry-fn)))))
     ((eq 403 status-code)
      (org-gcal--notify "Received HTTP 403"
                        "Ensure you enabled the Calendar API through the Developers Console, then try again.")
      (error "Got error %S: %S" status-code error-thrown))
     ((eq 410 status-code)
      (org-gcal--notify "Received HTTP 410"
                        "Calendar API sync token expired - performing full sync.")
      (setf (org-gcal--sync-tokens-get calendar-id 'remove) nil)
      (funcall retry-fn))
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
      (nconc page-token-cons (list (plist-get data :nextPageToken)))
      (let ((next-sync-token (plist-get data :nextSyncToken)))
        (when next-sync-token
          (setf (org-gcal--sync-tokens-get calendar-id)
                (list
                 ;; The first element is the expiration time of
                 ;; the sync token. Note that, if the expiration
                 ;; time already exists, we don't update it. We
                 ;; want to expire the token according to the
                 ;; time of the previous full sync.
                 (or
                  (car (org-gcal--sync-tokens-get calendar-id))
                  down-time)
                 next-sync-token))))
      (org-gcal--filter (plist-get data :items))))))

(defun org-gcal--sync-handle-events
    (calendar-id calendar-file events recurring-instances? up-time down-time
     parent-events)
  "Handle a list of EVENTS fetched from the Calendar API.

CALENDAR-ID and CALENDAR-FILE are defined in ‘org-gcal--sync-inner'.
RECURRING-INSTANCES? is t if we’re currently fetching instances of recurring
events and nil otherwise.

Any parent recurring events are appended in-place to the list PARENT-EVENTS."
  (with-current-buffer (find-file-noselect calendar-file)
    (cl-loop
     for event across events
     if
     (let* ((entry-id (org-gcal--format-entry-id
                       calendar-id (plist-get event :id)))
            (marker (org-gcal--id-find entry-id 'markerp)))
       (when (plist-get event :recurrence)
         (nconc parent-events (list
                               (org-gcal--event-id-from-entry-id entry-id))))
       (cond
        ;; Ignore event entirely if it is an instance of a recurring event
        ;; unless we’re currently fetching
        ;; instances of recurring events (i.e., RECURRING-INSTANCES? is
        ;; non-nil).
        ((and (eq org-gcal-recurring-events-mode 'nested)
              (not recurring-instances?)
              (plist-get event :recurringEventId))
         (nconc parent-events
                (list
                 (plist-get event :recurringEventId)))
         nil)
        ;; If event is present, collect it for later processing.
        (marker
         (org-gcal--event-entry-create
          :entry-id entry-id
          :marker marker
          :event event))
        ;; If event doesn’t already exist and is outside of the
        ;; range [‘org-gcal-up-days’, ‘org-gcal-down-days’], ignore
        ;; it. This is necessary because when called with
        ;; "syncToken", the Calendar API will return all events
        ;; changed on the calendar, without respecting
        ;; ‘org-gcal-up-days’ or ‘org-gcal-down-days’, which means
        ;; repeated events far in the future will be downloaded.
        ((when-let*
             ((up-time) (down-time)
              (start (plist-get event :start))
              (end (plist-get event :end))
              ((or (time-less-p (org-gcal--parse-calendar-time start)
                                up-time)
                   (time-less-p down-time
                                (org-gcal--parse-calendar-time end)))))
           t)
         nil)
        ;; When fetching instances of recurring events that are not yet
        ;; present, insert them below their parent events, if the parent event
        ;; exists.
        (recurring-instances?
         (let* ((parent-id (org-gcal--format-entry-id
                            calendar-id (plist-get event :recurringEventId)))
                (parent-marker
                 (when parent-id (org-gcal--id-find parent-id 'markerp))))
           (when parent-marker
             (atomic-change-group
               (org-with-point-at parent-marker
                 (org-insert-heading-respect-content 'invisible-ok)
                 (org-demote)
                 (org-gcal--update-entry calendar-id event 'newly-fetched))))
           nil))
        ;; Don't insert instances of cancelled events that haven't already been
        ;; fetched.
        ((string= "cancelled" (plist-get event :status))
         nil)
        (t
         ;; Otherwise, insert a new entry into the
         ;; default fetch file.
         (atomic-change-group
           (org-with-point-at (point-max)
             (insert "\n* ")
             (org-gcal--update-entry calendar-id event 'newly-fetched)
             (org-entry-put (point) org-gcal-managed-property
                            org-gcal-managed-newly-fetched-mode)))
         nil)))
     collect it)))

(defun org-gcal--sync-update-entries (calendar-id entries skip-export)
  "Update headlines given by ‘org-gcal--event-entry’ ENTRIES.

Find already retrieved entries and update them. This will update events that
have been moved from the default fetch file.  CALENDAR-ID is defined in
‘org-gcal--sync-inner'."
  (deferred:$
    (deferred:loop entries
      (lambda (entry)
        (deferred:$
          (let ((marker (or (org-gcal--event-entry-marker entry)
                            (org-gcal--id-find (org-gcal--event-entry-entry-id entry))))
                (event (org-gcal--event-entry-event entry)))
            (org-with-point-at marker
              ;; If skipping exports, just overwrite current entry's
              ;; calendar data with what's been retrieved from the
              ;; server. Otherwise, sync the entry at the current
              ;; point.
              (set-marker marker nil)
              (if (and skip-export event)
                  (progn
                    (org-gcal--update-entry calendar-id event 'update-existing)
                    (deferred:succeed nil))
                (org-gcal-post-at-point nil skip-export
                                        (org-gcal--sync-get-update-existing)))))
          ;; Log but otherwise ignore errors.
          (deferred:error it
            (lambda (err)
              (message "org-gcal-sync: error: %s" err))))))
    (deferred:succeed nil)))

(defun org-gcal--sync-lock ()
  "Activate sync lock."
  (setq org-gcal--sync-lock t))

(defun org-gcal--sync-unlock ()
  "Deactivate sync lock in case of failed sync."
  (interactive)
  (setq org-gcal--sync-lock nil))

(defun org-gcal--sync-get-update-existing ()
  "Obtain value of ‘org-gcal-managed-post-at-point-update-existing’ for syncs."
  (if (equal org-gcal-managed-post-at-point-update-existing 'prompt)
      'never-push
    org-gcal-managed-post-at-point-update-existing))

;;;###autoload
(defun org-gcal-fetch ()
  "Fetch event data from google calendar."
  (interactive)
  (org-gcal-sync t))

;;;###autoload
(defun org-gcal-sync-buffer (&optional skip-export silent filter-date
                                       filter-managed)
  "Sync entries with Calendar events in currently-visible portion of buffer.

Updates events on the server unless SKIP-EXPORT is set. In this case, events
modified on the server will overwrite entries in the buffer.
Set SILENT to non-nil to inhibit notifications.
Set FILTER-DATE to only update events scheduled for later than
‘org-gcal-up-days' and earlier than ‘org-gcal-down-days'.
Set FILTER-MAANGED to only update events with ‘org-gcal-managed-property’ set
to “org”."
  (interactive)
  (when org-gcal--sync-lock
    (user-error "org-gcal sync locked. If a previous sync has failed, call ‘org-gcal--sync-unlock’ to reset the lock and try again."))
  (org-gcal--sync-lock)
  (let*
      ((name (or (buffer-file-name) (buffer-name))))
    (deferred:try
      (deferred:$
        (org-gcal--sync-buffer-inner skip-export silent filter-date
                                     filter-managed
                                     (point-min-marker))
        (deferred:nextc it
          (lambda (_)
            (org-gcal--notify "Completed syncing events in buffer."
                              (concat "Events synced in\n" name)
                              silent)
            (deferred:succeed nil))))
      :finally
      (lambda ()
        (org-generic-id-update-id-locations org-gcal-entry-id-property)
        (org-gcal--sync-unlock)))))

(defmacro org-gcal--with-point-at-no-widen (pom &rest body)
  "Move to buffer and point of point-or-marker POM for the duration of BODY.

Based on ‘org-with-point-at’ but doesn’t widen the buffer."
  (declare (debug (form body)) (indent 1))
  (org-with-gensyms (mpom)
    `(let ((,mpom ,pom))
       (save-excursion
         (when (markerp ,mpom) (set-buffer (marker-buffer ,mpom)))
         (goto-char (or ,mpom (point)))
         ,@body))))

(defun org-gcal--sync-buffer-inner
    (skip-export _silent filter-date filter-managed marker)
  "Inner loop of ‘org-gcal-sync-buffer’."
  (while
      (not
       (catch 'block
         (deferred:$
           (deferred:succeed nil)
           (deferred:nextc it
             ;; Returns (wrapped in deferred object):
             ;; - marker within current headline if there are still headlines
             ;;   left in the file.
             ;; - nil if there are no more headlines.
             (lambda (_)
               (org-gcal--with-point-at-no-widen marker
                 ;; By default set next position of marker to nil. We’ll set it below if
                 ;; there remains more to edit.
                 (setq marker nil)
                 (let* ((drawer-point
                         (lambda ()
                           (re-search-forward
                            (format "^[ \t]*:%s:[ \t]*$" org-gcal-drawer-name)
                            (point-max)
                            'noerror)))
                        (marker-for-post
                         (cond
                          ((eq major-mode 'org-mode)
                           (when (funcall drawer-point)
                             (setq marker (point-marker))
                             marker))
                          ((eq major-mode 'org-agenda-mode)
                           (while (and (not marker) (not (eobp)))
                             (when-let ((agenda-marker (point-marker))
                                        (org-marker (org-get-at-bol 'org-hd-marker)))
                               (org-with-point-at org-marker
                                 (org-narrow-to-element)
                                 (when (funcall drawer-point)
                                   (setq marker agenda-marker)
                                   (point-marker)))))
                           ;; If org-marker isn’t found on this line, go to the next one.
                           (forward-line 1))
                          (t
                           (user-error "Unsupported major mode %s in current buffer"
                                       major-mode)))))
                   (if (and marker marker-for-post)
                       (org-with-point-at marker-for-post
                         (let* ((time-desc (org-gcal--get-time-and-desc))
                                (start
                                 (plist-get time-desc :start))
                                (start
                                 (and start
                                      (org-gcal--parse-calendar-time-string start)))
                                (end (plist-get time-desc :end))
                                (end
                                 (and end
                                      (org-gcal--parse-calendar-time-string end))))
                           (if
                               ;; Skip posting the headline under these
                               ;; conditions
                               (or
                                ;; Don’t sync events if ‘filter-date’ is set
                                ;; and event is too far in the past or
                                ;; future.
                                (and filter-date
                                     (or
                                      (not start) (not end)
                                      (time-less-p start (org-gcal--up-time))
                                      (time-less-p (org-gcal--down-time) end)))
                                ;; Don’t sync if ‘filter-managed’ is set and
                                ;; headline is not managed by Org (see
                                ;; ‘org-gcal-managed-property')
                                (and filter-managed
                                     (not
                                      (string=
                                       "org"
                                       (org-entry-get
                                        (point)
                                        org-gcal-managed-property)))))
                               (deferred:succeed marker)
                             (deferred:try
                               (deferred:$
                                 ;; Try to avoid hanging Emacs during
                                 ;; interactive use by waiting until Emacs is
                                 ;; idle.
                                 (deferred:wait-idle 1000)
                                 (deferred:nextc it
                                   (lambda (_)
                                     (org-with-point-at marker-for-post
                                       (org-gcal-post-at-point nil skip-export
                                                               (org-gcal--sync-get-update-existing))))))
                               :catch
                               (lambda (err)
                                 (message "org-gcal-sync-buffer: at %S event %S: error: %s"
                                          marker-for-post time-desc err))
                               :finally
                               (lambda (_)
                                 (deferred:succeed marker))))))
                     (deferred:succeed nil))))))
           (deferred:nextc it
             (lambda (m)
               (when m
                 (setq marker m)
                 (throw 'block nil))
               (deferred:succeed nil)))
           (deferred:error it
             (lambda (err)
               (message "org-gcal-sync-buffer: error: %s" err)))))))
  (deferred:succeed nil))

;;;###autoload
(defun org-gcal-fetch-buffer (&optional silent filter-date)
  "Fetch changes to events in the currently-visible portion of the buffer

Unlike ‘org-gcal-sync-buffer’, this will not push any changes to Google
Calendar. For SILENT and FILTER-DATE see ‘org-gcal-sync-buffer’."
  (interactive)
  (org-gcal-sync-buffer t silent filter-date))

(defvar org-gcal-debug nil)
;;;###autoload
(defun org-gcal-toggle-debug ()
  "Toggle debugging flags for ‘org-gcal'."
  (interactive)
  (cond
   (org-gcal-debug
    (setq
     debug-on-error (cdr (assq 'debug-on-error org-gcal-debug))
     debug-ignored-errors (cdr (assq 'debug-ignored-errors org-gcal-debug))
     deferred:debug (cdr (assq 'deferred:debug org-gcal-debug))
     deferred:debug-on-signal
     (cdr (assq 'deferred:debug-on-signal org-gcal-debug))
     request-log-level (cdr (assq 'request-log-level org-gcal-debug))
     request-log-buffer-name (cdr (assq 'request-log-buffer-name org-gcal-debug))
     org-gcal-debug nil)
    (message "org-gcal-debug DISABLED"))
   (t
    (setq
     org-gcal-debug
     `((debug-on-error . ,debug-on-error)
       (debug-ignored-errors . ,debug-ignored-errors)
       (deferred:debug . ,deferred:debug)
       (deferred:debug-on-signal . ,deferred:debug-on-signal)
       (request-log-level . ,request-log-level)
       (request-log-buffer-name . ,request-log-buffer-name))
     debug-on-error '(error)
     ;; These are errors that are thrown by various pieces of code that
     ;; don’t mean anything.
     debug-ignored-errors (append debug-ignored-errors
                                  '(scan-error file-already-exists))
     deferred:debug t
     request-message-level 'debug
     request-log-level 'debug
     ;; Remove leading space so it shows up in the buffer list.
     request-log-buffer-name "*request-log*"
     deferred:debug-on-signal t)
    (message "org-gcal-debug ENABLED"))))

(defun org-gcal--headline ()
  "Get bare headline at current point."
  (substring-no-properties
   (org-get-heading 'no-tags 'no-todo 'no-priority 'no-comment)))

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

(defun org-gcal--id-find (id &optional markerp)
  "Return the location of the entry with the id ID.
The return value is a cons cell (file-name . position), or nil
if there is no entry with that ID.
With optional argument MARKERP, return the position as a new marker."
  (or
   (org-generic-id-find org-gcal-entry-id-property id markerp
                        'cached)
   ;; Fallback for legacy "ID" property. Don’t use ‘org-id-find’ directly
   ;; because it always run ‘org-id-update-id-locations’ if the ID isn’t found,
   ;; which slows us down considerably, and tries to fall back to the current
   ;; buffer, which we don’t want either.
   (when-let ((file (org-gcal--find-id-file id)))
     (org-id-find-id-in-file id file markerp))))

(defun org-gcal--find-id-file (id)
  "Query the id database for the file in which this ID is located.

Like ‘org-id-find-id-file’, except that it doesn’t fall back to the current
buffer if ID is not found in the id database, but instead returns nil.

Only needed for legacy entries that use \"ID\" to store entry IDs."
  (unless org-id-locations (org-id-locations-load))
  (or (and org-id-locations
           (hash-table-p org-id-locations)
           (gethash id org-id-locations))
      nil))

(defun org-gcal--get-id (pom)
  "Retrieve an entry ID at point-or-marker POM.

  Use ‘org-gcal-entry-id-property', or \":ID:\" if not present (for backward
compatibility)."
  (org-gcal--event-id-from-entry-id
   (or (org-entry-get pom org-gcal-entry-id-property)
       (org-entry-get pom "ID"))))


(defun org-gcal--put-id (pom calendar-id event-id)
  "Store a canonical entry ID at point-or-marker POM.

Entry ID is generated from CALENDAR-ID and EVENT-ID and stored in the
‘org-gcal-entry-id-property'.

This will also update the stored ID locations using
‘org-generic-id-add-location'."
  (org-with-point-at pom
    (org-gcal--back-to-heading)
    (let ((entry-id (org-gcal--format-entry-id calendar-id event-id)))
      (org-entry-put (point) org-gcal-entry-id-property entry-id)
      (when-let* ((fname (buffer-file-name))
                  (truename (file-truename fname)))
        (org-generic-id-add-location org-gcal-entry-id-property entry-id
                                     truename)))))

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
               ?/
               (submatch-n 2 (1+ (not (any ?/ ?\n))))
               string-end))
            entry-id))
    (match-string 1 entry-id)))

(defun org-gcal--format-entry-id (calendar-id event-id)
  "Format CALENDAR-ID and ENTRY-ID into a canonical ID for an Org mode entry.

  Return nil if either argument is nil."
  (when (and calendar-id event-id)
    (format "%s/%s" event-id calendar-id)))

(defun org-gcal--back-to-heading ()
  "\
  Call ‘org-back-to-heading’ with the invisible-ok argument set to true.
  We always intend to go back to the invisible heading here."
  (org-back-to-heading 'invisible-ok))

(defun org-gcal--get-time-and-desc ()
  "Get the timestamp and description of the event at point.

  Return a plist with :start, :end, and :desc keys. The value for a key is nil
  if not present."
  (let (start end desc tobj elem)
    (save-excursion
      (org-gcal--back-to-heading)
      (setq elem (org-element-at-point))
      ;; Parse :org-gcal: drawer for event time and description.
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
                   desc)))))))
    ;; Prefer to read event time from the SCHEDULED property if present.
    (setq tobj (or (org-element-property :scheduled elem) tobj))
    (when tobj
      (when (plist-get (cadr tobj) :year-start)
        (setq
         start
         (org-gcal--format-org2iso
          (plist-get (cadr tobj) :year-start)
          (plist-get (cadr tobj) :month-start)
          (plist-get (cadr tobj) :day-start)
          (plist-get (cadr tobj) :hour-start)
          (plist-get (cadr tobj) :minute-start)
          (when (plist-get (cadr tobj) :hour-start) t))))
      (when (plist-get (cadr tobj) :year-end)
        (setq
         end
         (org-gcal--format-org2iso
          (plist-get (cadr tobj) :year-end)
          (plist-get (cadr tobj) :month-end)
          (plist-get (cadr tobj) :day-end)
          (plist-get (cadr tobj) :hour-end)
          (plist-get (cadr tobj) :minute-end)
          (when (plist-get (cadr tobj) :hour-end) t)))))
    (list :start start :end end :desc desc)))

(defun org-gcal--source-from-link-string (link)
  "Parse LINK, a link in Org format, to a Google Calendar API source object.

Returns an alist with ‘:url’ for the link URL and ‘:title’ for the link title,
or nil if no valid link is found."
  (with-temp-buffer
    (let ((org-inhibit-startup nil))
      (insert link)
      (org-mode)
      (goto-char (point-min))
      (when-let ((link-element (car-safe (cdr-safe (org-element-link-parser)))))
        (let ((link-title-begin (plist-get link-element :contents-begin))
              (link-title-end (plist-get link-element :contents-end)))
          (append
           `((url . ,(plist-get link-element :raw-link)))
           (when (and link-title-begin link-title-end)
             `((title
                . ,(buffer-substring-no-properties
                    link-title-begin
                    link-title-end))))))))))

;;;###autoload
(defun org-gcal-post-at-point (&optional skip-import skip-export existing-mode)
  "Post entry at point to current calendar.

This overwrites the event on the server with the data from the entry, except if
the ‘org-gcal-etag-property’ is present and is out of sync with the server, in
which case the entry is overwritten with data from the server instead.

If SKIP-IMPORT is not nil, don’t overwrite the entry with data from the server.
If SKIP-EXPORT is not nil, don’t overwrite the event on the server.
For valid values of EXISTING-MODE see
‘org-gcal-managed-post-at-point-update-existing'."
  (interactive)
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
           (smry (org-gcal--headline))
           (loc (org-entry-get (point) "LOCATION"))
           (source
            (when-let ((link-string
                        (or (org-entry-get (point) "link")
                            (nth 0
                                 (org-entry-get-multivalued-property
                                  (point) "ROAM_REFS")))))
              (org-gcal--source-from-link-string link-string)))
           (transparency (or (org-entry-get (point) "TRANSPARENCY")
                             org-gcal-default-transparency))
           (recurrence (org-entry-get (point) "recurrence"))
           (event-id (org-gcal--get-id (point)))
           (etag (org-entry-get (point) org-gcal-etag-property))
           (managed (org-entry-get (point) org-gcal-managed-property))
           (calendar-id
            (org-entry-get (point) org-gcal-calendar-id-property)))
      ;; Set ‘org-gcal-managed-property’ if not present.
      (unless (and managed (member managed '("org" "gcal")))
        (let ((x
               (if (and calendar-id event-id)
                   org-gcal-managed-update-existing-mode
                 org-gcal-managed-create-from-entry-mode)))
          (org-entry-put (point) org-gcal-managed-property x)
          (setq managed x)))
      ;; Fill in Calendar ID if not already present.
      (unless calendar-id
        (setq calendar-id
              ;; Completes read with prompts like "CALENDAR-FILE (CALENDAR-ID)",
              ;; and then uses ‘replace-regexp-in-string’ to extract just
              ;; CALENDAR-ID.
              (replace-regexp-in-string
               ".*(\\(.*?\\))$" "\\1"
               (completing-read "Calendar ID: "
                                (mapcar
                                 (lambda (x) (format "%s (%s)" (cdr x) (car x)))
                                 org-gcal-fetch-file-alist))))
        (org-entry-put (point) org-gcal-calendar-id-property calendar-id))
      (when (equal managed "gcal")
        (unless existing-mode
          (setq existing-mode org-gcal-managed-post-at-point-update-existing))
        (pcase existing-mode
          ('never-push
           (setq skip-export t))
          ;; PROMPT and PROMPT-SYNC are handled identically here. When syncing
          ;; PROMPT is mapped to NEVER-PUSH in the calling function, while
          ;; PROMPT-SYNC is left unchanged.
          ;; Only when manually running ‘org-gcal-post-at-point’ should PROMPT
          ;; be seen here.
          ((or 'prompt 'prompt-sync)
           (unless (y-or-n-p (format "Push event to Google Calendar?\n\n%s\n\n"
                                     smry))
             (setq skip-export t)))
          ('always-push nil)
          (val
           (user-error "Bad value %S of EXISTING-MODE passed to ‘org-gcal-post-at-point’. For valid values see ‘org-gcal-managed-post-at-point-update-existing’."
                       val))))
      ;; Read currently-present start and end times and description. Fill in a
      ;; reasonable start and end time if either is missing.
      (let* ((time-desc (org-gcal--get-time-and-desc))
             (start (plist-get time-desc :start))
             (end (plist-get time-desc :end))
             (desc (plist-get time-desc :desc)))
        (unless end
          (let* ((start-time (or start (org-read-date 'with-time 'to-time)))
                 (min-duration 5)
                 (resolution 5)
                 (duration-default
                  (org-duration-from-minutes
                   (max
                    min-duration
                    ;; Round up to the nearest multiple of ‘resolution’ minutes.
                    (* resolution
                       (ceiling
                        (/ (- (org-duration-to-minutes
                               (or (org-element-property :EFFORT elem) "0:00"))
                              (org-clock-sum-current-item))
                           resolution))))))
                 (duration (read-from-minibuffer "Duration: " duration-default))
                 (duration-minutes (org-duration-to-minutes duration))
                 (duration-seconds (* 60 duration-minutes))
                 (end-time (time-add start-time duration-seconds)))
            (setq start (org-gcal--format-time2iso start-time)
                  end (org-gcal--format-time2iso end-time))))
        (when recurrence
          (setq start nil end nil))
        (org-gcal--post-event start end smry loc source desc calendar-id marker transparency etag
                              event-id nil skip-import skip-export)))))

;;;###autoload
(defun org-gcal-delete-at-point (&optional clear-gcal-info)
  "Delete entry at point to current calendar.

If called with prefix or with CLEAR-GCAL-INFO non-nil, will clear calendar info
from the entry even if deleting the event from the server fails.  Use this to
delete calendar info from events on calendars you no longer have access to."
  (interactive "P")
  (save-excursion
    ;; Delete entry at point in org-agenda buffer.
    (when (eq major-mode 'org-agenda-mode)
      (let ((m (org-get-at-bol 'org-hd-marker)))
        (set-buffer (marker-buffer m))
        (goto-char (marker-position m))))
    (end-of-line)
    (org-gcal--back-to-heading)
    (let* ((marker (point-marker))
           (smry (org-gcal--headline))
           (event-id (org-gcal--get-id (point)))
           (etag (org-entry-get (point) org-gcal-etag-property))
           (calendar-id
            (org-entry-get (point) org-gcal-calendar-id-property))
           (delete-error))
      (if (and event-id
               (y-or-n-p (format "Do you really want to delete event?\n\n%s\n\n" smry)))
          (deferred:try
            (org-gcal--delete-event calendar-id event-id etag (copy-marker marker))
            :catch
            (lambda (err)
              (message "Setting delete-error to %S" err)
              (setq delete-error err))
            :finally
            (lambda (_unused)
              ;; Only clear org-gcal from headline if successful or we were
              ;; forced to.
              (message "clear-gcal-info delete-error: %S %S"
                       clear-gcal-info delete-error)
              (when (or clear-gcal-info (null delete-error))
                ;; Delete :org-gcal: drawer after deleting event. This will preserve
                ;; the ID for links, but will ensure functions in this module don’t
                ;; identify the entry as a Calendar event.
                (org-with-point-at marker
                  (when (re-search-forward
                         (format
                          "^[ \t]*:%s:[^z-a]*?\n[ \t]*:END:[ \t]*\n?"
                          (regexp-quote org-gcal-drawer-name))
                         (save-excursion (outline-next-heading) (point))
                         'noerror)
                    (replace-match "" 'fixedcase))
                  (org-entry-delete marker org-gcal-calendar-id-property)
                  (org-entry-delete marker org-gcal-entry-id-property))
                ;; Finally cancel and delete the event if this is configured.
                (org-with-point-at marker
                  (org-back-to-heading)
                  (org-gcal--handle-cancelled-entry)))
              (if delete-error
                  (error "org-gcal-delete-at-point: for %s %s: error: %S"
                         calendar-id event-id delete-error)
                (deferred:succeed nil))))
        (deferred:succeed nil)))))

(defun org-gcal--get-access-token (calendar-id)
  "Return the access token for CALENDAR-ID."
  (aio-wait-for
   (oauth2-auto-access-token calendar-id 'org-gcal)))

(defun org-gcal--refresh-token (calendar-id)
  "Refresh OAuth access and return the new access token as a deferred object."
  ;; FIXME: For now, we just synchronously wait for the refresh. Once the
  ;; project has been rewritten to use aio
  ;; (https://github.com/kidd/org-gcal.el/issues/191), we can wait for this
  ;; asynchronously as well.
  (let ((token
         (aio-wait-for
          (oauth2-auto-access-token calendar-id 'org-gcal))))
    (deferred:succeed token)))

;;;###autoload
(defun org-gcal-sync-tokens-clear ()
  "Clear all Calendar API sync tokens.

  Use this to force retrieving all events in ‘org-gcal-sync’ or
  ‘org-gcal-fetch’."
  (interactive)
  (setq org-gcal--sync-tokens nil)
  (persist-save 'org-gcal--sync-tokens))

;; Internal
(defun org-gcal--archive-old-event ()
  "Archive old event at point."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward org-heading-regexp nil t)
      (let ((properties (org-entry-properties)))
        ; Check if headline is managed by `org-gcal', and hasn't been archived
        ; yet. Only in that case, potentially archive.
        (when (and (assoc "ORG-GCAL-MANAGED" properties)
                   (not (assoc "ARCHIVE_TIME" properties)))

          ; Go to beginning of line to parse the headline
          (beginning-of-line)
          (let ((elem (org-element-headline-parser (point-max) t)))

            ; Go to next timestamp to parse it
            (condition-case nil
                (goto-char (cdr (org-gcal--timestamp-successor)))
              (error (error "Org-gcal error: Couldn't parse %s"
                            (buffer-file-name))))
            (let ((tobj (cadr (org-element-timestamp-parser))))
              (when (>
                     (time-to-seconds (time-subtract (current-time) (days-to-time org-gcal-up-days)))
                     (time-to-seconds (encode-time 0 (if (plist-get tobj :minute-end)
                                                         (plist-get tobj :minute-end) 0)
                                                   (if (plist-get tobj :hour-end)
                                                       (plist-get tobj :hour-end) 24)
                                                   (plist-get tobj :day-end)
                                                   (plist-get tobj :month-end)
                                                   (plist-get tobj :year-end))))
                (org-gcal--notify "Archived event." (org-element-property :title elem))
                (let ((kill-ring kill-ring)
                      (select-enable-clipboard nil))
                  (org-archive-subtree))))))))
    (save-buffer)))

(defun org-gcal--save-sexp (data file)
  "Print Lisp object DATA to FILE, creating it if necessary."
  (let ((dir (file-name-directory file)))
    (unless (file-directory-p (file-name-directory file))
      (make-directory dir)))
  (let* ((content (when (file-exists-p file)
                    (org-gcal--read-file-contents file))))
    (if (and content (listp content) (plist-get content :token))
        (setq content (plist-put content :token data))
      (setq content `(:token ,data :elem nil)))
    (with-temp-file file
      (pp content (current-buffer)))))

(defun org-gcal--read-file-contents (file)
  "Call ‘read’ on the contents of FILE, returning the resulting object."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (condition-case nil
      (read (current-buffer))
      (end-of-file nil))))

(defun org-gcal--json-read ()
  (let ((json-object-type 'plist))
    (goto-char (point-min))
    (re-search-forward "^{" nil t)
    (delete-region (point-min) (1- (point)))
    (goto-char (point-min))
    (json-read-from-string
     (decode-coding-string
      (buffer-substring-no-properties (point-min) (point-max)) 'utf-8))))

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

(defun org-gcal--parse-calendar-time (time)
  "Parse TIME, the start or end time object from Calendar API Events resource.
Return an Emacs time object from ‘encode-time'."
  (org-gcal--parse-calendar-time-string
   (or (plist-get time :dateTime)
       (plist-get time :date))))

(defun org-gcal--parse-calendar-time-string (time-string)
  (if (< 11 (length time-string))
      (parse-iso8601-time-string time-string)
    (apply #'encode-time
           ;; Full days have time strings with unknown hour, minute, and
           ;; second, which ‘parse-time-string’ will set to
           ;; nil. ‘encode-time’ can’t tolerate that, so instead set the time
           ;; to 00:00:00.
           `(0 0 0 .
               ,(nthcdr 3 (parse-time-string time-string))))))

(defun org-gcal--down-time ()
  "Convert ‘org-gcal-down-days’ to Emacs time value."
  (time-add (current-time) (days-to-time org-gcal-down-days)))

(defun org-gcal--up-time ()
  "Convert ‘org-gcal-up-days’ to Emacs time value."
  (time-subtract (current-time) (days-to-time org-gcal-up-days)))

(defun org-gcal--time-zone (seconds)
  (current-time-zone (seconds-to-time seconds)))

(defun org-gcal--format-time2iso (time)
  "Format Emacs time value TIME to ISO format string."
  (format-time-string "%FT%T%z" time (car (org-gcal--time-zone 0))))

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

(defun org-gcal--event-cancelled-p (event)
  "Has EVENT been cancelled?"
  (string= (plist-get event :status) "cancelled"))

(defun org-gcal--convert-time-to-local-timezone (date-time local-timezone)
  (if (and date-time
           local-timezone)
      (format-time-string "%Y-%m-%dT%H:%M:%S%z" (parse-iso8601-time-string date-time) local-timezone)
    date-time))

(defun org-gcal--update-entry (calendar-id event &optional update-mode)
  "Update the entry at the current heading with information from EVENT.

EVENT is parsed from the Calendar API JSON response using ‘org-gcal--json-read’.
CALENDAR-ID must be passed as well. Point must be located on an Org-mode heading
line or an error will be thrown. Point is not preserved.

If UPDATE-MODE is passed, then the functions in
‘org-gcal-after-update-entry-functions' are called in order with the same
arguments as passed to this function and the point moved to the beginning of the
heading."
  (unless (org-at-heading-p)
    (user-error "Must be on Org-mode heading."))
  (let* ((smry  (plist-get event :summary))
         (desc  (plist-get event :description))
         (loc   (plist-get event :location))
         (source (plist-get event :source))
         (transparency   (plist-get event :transparency))
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
         (start (if stime (org-gcal--convert-time-to-local-timezone stime org-gcal-local-timezone) sday))
         (end   (if etime (org-gcal--convert-time-to-local-timezone etime org-gcal-local-timezone) eday))
         (old-time-desc (org-gcal--get-time-and-desc))
         (old-start (plist-get old-time-desc :start))
         (old-end (plist-get old-time-desc :start))
         (recurrence (plist-get event :recurrence))
         (elem))
    (when loc (replace-regexp-in-string "\n" ", " loc))
    (org-edit-headline
     (cond
      ;; Don’t update headline if the new summary is the same as the CANCELLED
      ;; todo keyword.
      ((equal smry org-gcal-cancelled-todo-keyword) (org-gcal--headline))
      (smry smry)
      ;; Set headline to “busy” if there is no existing headline and no summary
      ;; from server.
      ((or (null (org-gcal--headline))
           (string-empty-p (org-gcal--headline)))
       "busy")
      (t (org-gcal--headline))))
    (org-entry-put (point) org-gcal-etag-property etag)
    (when recurrence (org-entry-put (point) "recurrence" (format "%s" recurrence)))
    (when loc (org-entry-put (point) "LOCATION" loc))
    (when source
      (let ((roam-refs
             (org-entry-get-multivalued-property (point) "ROAM_REFS"))
            (link (org-entry-get (point) "link")))
        (cond
         ;; ROAM_REFS can contain multiple references, but only bare URLs are
         ;; supported. To make sure we can round-trip between ROAM_REFS and
         ;; Google Calendar, only import to ROAM_REFS if there is no title in
         ;; the source, and if ROAM_REFS has at most one entry.
         ((and (null link)
               (<= (length roam-refs) 1)
               (or (null (plist-get source :title))
                   (string-empty-p (plist-get source :title))))
          (org-entry-put (point) "ROAM_REFS"
                         (plist-get source :url)))
         (t
          (org-entry-put (point) "link"
                         (org-link-make-string
                          (plist-get source :url)
                          (plist-get source :title)))))))
    (when transparency (org-entry-put (point) "TRANSPARENCY" transparency))
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
    ;; Keep existing timestamps for parent recurring events.
    (when (and recurrence old-start old-end)
      (setq start old-start
            end old-end))
    (let*
        ((timestamp
          (if (or (string= start end) (org-gcal--alldayp start end))
              (org-gcal--format-iso2org start)
            (if (and
                 (= (plist-get (org-gcal--parse-date start) :year)
                    (plist-get (org-gcal--parse-date end)   :year))
                 (= (plist-get (org-gcal--parse-date start) :mon)
                    (plist-get (org-gcal--parse-date end)   :mon))
                 (= (plist-get (org-gcal--parse-date start) :day)
                    (plist-get (org-gcal--parse-date end)   :day)))
                (format "<%s-%s>"
                        (org-gcal--format-date start "%Y-%m-%d %a %H:%M")
                        (org-gcal--format-date end "%H:%M"))
              (format "%s--%s"
                      (org-gcal--format-iso2org start)
                      (org-gcal--format-iso2org
                       (if (< 11 (length end))
                           end
                         (org-gcal--iso-previous-day end))))))))
      (if (org-element-property :scheduled elem)
          (unless (and recurrence old-start) (org-schedule nil timestamp))
        (insert timestamp)
        (newline)
        (when desc (newline))))
    ;; Insert event description if present.
    (when desc
      (insert (replace-regexp-in-string "^\*" "✱" desc))
      (insert (if (string= "\n" (org-gcal--safe-substring desc -1)) "" "\n")))
    (insert ":END:")
    (when (org-gcal--event-cancelled-p event)
      (save-excursion
        (org-back-to-heading t)
        (org-gcal--handle-cancelled-entry)))
    (when update-mode
      (cl-dolist (f org-gcal-after-update-entry-functions)
        (save-excursion
          (org-back-to-heading t)
          (funcall f calendar-id event update-mode))))))


(defun org-gcal--handle-cancelled-entry ()
  "Perform actions to be done on cancelled entries."
  (unless (org-at-heading-p)
    (user-error "Must be on Org-mode heading"))
  (let ((already-cancelled
         (string= (nth 2 (org-heading-components))
                  org-gcal-cancelled-todo-keyword)))
    (unless already-cancelled
      (when (and org-gcal-update-cancelled-events-with-todo
                 (member org-gcal-cancelled-todo-keyword
                         org-todo-keywords-1))
        (let ((org-inhibit-logging t))
          (org-todo org-gcal-cancelled-todo-keyword))))
    (when (or org-gcal-remove-events-with-cancelled-todo
              (not already-cancelled))
      (org-gcal--maybe-remove-entry))))

(defun org-gcal--maybe-remove-entry ()
  "Maybe remove the entry at the current heading

Depends on the value of ‘org-gcal-remove-api-cancelled-events’."
  (when-let (((and org-gcal-remove-api-cancelled-events))
             (smry (org-gcal--headline))
             ((or (eq org-gcal-remove-api-cancelled-events t)
                  (y-or-n-p (format "Delete Org headline for cancelled event\n%s? "
                                    (or smry ""))))))
    (delete-region
     (save-excursion
       (org-back-to-heading t)
       (point))
     (save-excursion
       (org-end-of-subtree t t)
       (point)))))

(defun org-gcal--format-date (str format &optional tz)
  (let* ((plst (org-gcal--parse-date str))
         (seconds (org-gcal--time-to-seconds plst)))
    (concat
     (format-time-string format
                         (seconds-to-time
                          (+ (if tz (car (org-gcal--time-zone seconds)) 0)
                             seconds))))))

(defun org-gcal--param-date (str)
  (and str
       (if (< 11 (length str)) "dateTime" "date")))

(defun org-gcal--param-date-alt (str)
  (and str
       (if (< 11 (length str)) "dateTime" "date")))

(defun org-gcal--get-calendar-id-of-buffer ()
  "Find calendar id of current buffer."
  (or (cl-loop for (id . file) in org-gcal-fetch-file-alist
               if (file-equal-p file (buffer-file-name (buffer-base-buffer)))
               return id)
      (user-error (concat "Buffer `%s' may not be related to google calendar; "
                          "please check/configure `org-gcal-fetch-file-alist'")
                  (buffer-name))))

(defun org-gcal--get-event (calendar-id event-id)
  "\
Retrieves a Google Calendar event given a CALENDAR-ID and EVENT-ID. If the
access token A-TOKEN is not specified, it is loaded from the token file.

Returns a ‘deferred’ function that on success returns a ‘request-response‘
object."
  (let ((a-token (org-gcal--get-access-token calendar-id)))
    (deferred:$
      (request-deferred
       (concat
        (org-gcal-events-url calendar-id)
        (concat "/" event-id))
       :type "GET"
       :headers
       `(("Accept" . "application/json")
         ("Authorization" . ,(format "Bearer %s" a-token)))
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
                (org-gcal--refresh-token calendar-id)
                (deferred:nextc it
                  (lambda (_unused)
                    (org-gcal--get-event calendar-id event-id)))))
             ;; Generic error-handler meant to provide useful information about
             ;; failure cases not otherwise explicitly specified.
             ((not (eq error-thrown nil))
              (org-gcal--notify
               (concat "Status code: " (number-to-string status-code))
               (format "%s %s: %s"
                       calendar-id
                       event-id
                       (pp-to-string error-thrown)))
              (error "org-gcal--get-event: Got error %S for %s %s: %S"
                     status-code calendar-id event-id error-thrown))
             ;; Fetch was successful.
             (t response))))))))

(defun org-gcal--post-event (start end smry loc source desc calendar-id marker transparency &optional etag event-id a-token skip-import skip-export)
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
        (a-token (or a-token (org-gcal--get-access-token calendar-id))))
    (deferred:try
      (deferred:$
        (apply
         #'request-deferred
         (concat
          (org-gcal-events-url calendar-id)
          (when event-id
            (concat "/" (url-hexify-string event-id))))
         :type (cond
                (skip-export "GET")
                (event-id "PATCH")
                (t "POST"))
         :headers (append
                   `(("Content-Type" . "application/json")
                     ("Accept" . "application/json")
                     ("Authorization" . ,(format "Bearer %s" a-token)))
                   (cond
                    ((null etag) nil)
                    ((null event-id)
                     (error "org-gcal--post-event: %s %s %s: %s"
                            (point-marker) calendar-id event-id
                            "Event cannot have ETag set when event ID absent"))
                    (t
                     `(("If-Match" . ,etag)))))
         :parser 'org-gcal--json-read
         (unless skip-export
           (list
            :data (encode-coding-string
                   (json-encode
                    (append
                     `(("summary" . ,smry)
                       ("location" . ,loc)
                       ("source" . ,source)
                       ("transparency" . ,transparency)
                       ("description" . ,desc))
                     (if (and start end)
                         `(("start" (,stime . ,start) (,stime-alt . nil))
                           ("end" (,etime . ,(if (equal "date" etime)
                                                 (org-gcal--iso-next-day end)
                                               end))
                            (,etime-alt . nil)))
                       nil)))
                   'utf-8))))
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
                  (org-gcal--refresh-token calendar-id)
                  (deferred:nextc it
                    (lambda (_unused)
                      (org-gcal--post-event start end smry loc source desc calendar-id
                                            marker transparency etag event-id nil
                                            skip-import skip-export)))))
               ;; ETag on current entry is stale. This means the event on the
               ;; server has been updated. In that case, update the event using
               ;; the data from the server.
               ((eq status-code 412)
                (unless skip-import
                  (org-gcal--notify
                   "Received HTTP 412"
                   (format "ETag stale for %s\n%s\n\n%s"
                           smry
                           (org-gcal--format-entry-id calendar-id event-id)
                           "Will overwrite this entry with event from server."))
                  (deferred:$
                    (org-gcal--get-event calendar-id event-id)
                    (deferred:nextc it
                      (lambda (response)
                        (save-excursion
                          (with-current-buffer (marker-buffer marker)
                            (goto-char (marker-position marker))
                            (org-gcal--update-entry
                             calendar-id
                             (request-response-data response)
                             (if event-id 'update-existing 'create-from-entry))))
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
                        (org-gcal--update-entry calendar-id data
                                                (if event-id
                                                    'update-existing
                                                  'create-from-entry))))
                    (org-gcal--notify "Event Posted"
                                      (concat "Org-gcal post event\n  " (plist-get data :summary)))))
                (deferred:succeed nil)))))))
      :finally
      (lambda (_)
        (set-marker marker nil)))))


(defun org-gcal--delete-event (calendar-id event-id etag marker &optional a-token)
  "\
Deletes an event on Calendar CALENDAR-ID with EVENT-ID. The Org buffer and
point from which the event is read is given by MARKER. MARKER is destroyed by
this function.

If ETAG is provided, it is used to retrieve the event data from the server and
overwrite the event at MARKER if the event has changed on the server.

Returns a ‘deferred’ object that can be used to wait for completion."
  (let ((a-token (or a-token (org-gcal--get-access-token calendar-id))))
    (deferred:try
      (deferred:$
        (request-deferred
         (concat
          (org-gcal-events-url calendar-id)
          (concat "/" event-id))
         :type "DELETE"
         :headers (append
                   `(("Content-Type" . "application/json")
                     ("Accept" . "application/json")
                     ("Authorization" . ,(format "Bearer %s" a-token)))
                   (cond
                    ((null etag) nil)
                    ((null event-id)
                     (error "Event cannot have ETag set when event ID absent"))
                    (t
                     `(("If-Match" . ,etag)))))

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
                  (org-gcal--refresh-token calendar-id)
                  (deferred:nextc it
                    (lambda (_unused)
                      (org-gcal--delete-event calendar-id event-id
                                              etag marker nil)))))
               ;; ETag on current entry is stale. This means the event on the
               ;; server has been updated. In that case, update the event using
               ;; the data from the server.
               ((eq status-code 412)
                (org-gcal--notify
                 "Received HTTP 412"
                 (format "ETag stale for entry %s\n\n%s"
                         (org-gcal--format-entry-id calendar-id event-id)
                         "Will overwrite this entry with event from server."))
                (deferred:$
                  (org-gcal--get-event calendar-id event-id)
                  (deferred:nextc it
                    (lambda (response)
                      (save-excursion
                        (with-current-buffer (marker-buffer marker)
                          (goto-char (marker-position marker))
                          (org-gcal--update-entry
                           calendar-id
                           (request-response-data response)
                           'update-existing)))
                      (deferred:succeed nil)))))
               ;; Generic error-handler meant to provide useful information about
               ;; failure cases not otherwise explicitly specified.
               ((not (eq error-msg nil))
                (org-gcal--notify
                 (concat "Status code: " (number-to-string status-code))
                 (pp-to-string error-msg))
                (error "Got error %S: %S" status-code error-msg))
               ;; Fetch was successful.
               (t
                (org-gcal--notify "Event Deleted" "Org-gcal deleted event")
                (deferred:succeed nil)))))))
      :finally
      (lambda (_)
        (set-marker marker nil)))))

(declare-function org-capture-goto-last-stored "org-capture" ())
(defun org-gcal--capture-post ()
  "Create gcal event for headline when captured or refiled into a gcal Org file."
  (when (not org-note-abort)
    (save-excursion
      (save-window-excursion
        (let ((inhibit-message t))
          (org-capture-goto-last-stored))
        (dolist (i org-gcal-fetch-file-alist)
          (when (and (buffer-file-name)
                     (string= (file-truename (cdr i))
                              (file-truename (buffer-file-name))))
            (org-entry-put (point) org-gcal-calendar-id-property (car i))
            (org-gcal-post-at-point)))))))
(defun org-gcal--refile-post ()
  "Create gcal event for headline when refiled into a gcal Org file."
  (unless (or
           ;; Refile from capture is handled by ‘org-gcal--capture-post'.
           (bound-and-true-p org-capture-is-refiling)
           ;; Don’t POST unnecessarily if the headline being refiled is already
           ;; a gcal event.
           (and (org-entry-get (point) org-gcal-calendar-id-property)
                (org-entry-get (point) org-gcal-entry-id-property)))
    (save-excursion
      (save-window-excursion
        (dolist (i org-gcal-fetch-file-alist)
          (when (and (buffer-file-name)
                     (string= (file-truename (cdr i))
                              (file-truename (buffer-file-name))))
            (org-entry-put (point) org-gcal-calendar-id-property (car i))
            (org-gcal-post-at-point)))))))
(with-eval-after-load 'org-capture
  (add-hook 'org-capture-after-finalize-hook 'org-gcal--capture-post))
(with-eval-after-load 'org-refile
  (add-hook 'org-after-refile-insert-hook 'org-gcal--refile-post))

(defun org-gcal--sync-tokens-valid ()
  "Is ‘org-gcal--sync-tokens’ in a valid format?"
  (and (listp org-gcal--sync-tokens)
       (json-alist-p org-gcal--sync-tokens)))

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

(defun org-gcal--notify (title message &optional silent)
  "Send alert with TITLE and MESSAGE.

When SILENT is non-nil, silence messages even when ‘org-gcal-notify-p’ is
non-nil."
  (when (and org-gcal-notify-p (not silent))
    (if org-gcal-logo-file
        (alert message :title title :icon org-gcal-logo-file)
      (alert message :title title))
    (message "%s\n%s" title message)))

(defun org-gcal--time-to-seconds (plst)
  (time-to-seconds
   (encode-time
    (plist-get plst :sec)
    (plist-get plst :min)
    (plist-get plst :hour)
    (plist-get plst :day)
    (plist-get plst :mon)
    (plist-get plst :year))))


(defun org-gcal-reload-client-id-secret ()
  "Setup OAuth2 authentication after setting client ID and secret."
  (interactive)
  (add-to-list
   'oauth2-auto-additional-providers-alist
   `(org-gcal
     (authorize_url . "https://accounts.google.com/o/oauth2/auth")
     (token_url . "https://oauth2.googleapis.com/token")
     (scope . "https://www.googleapis.com/auth/calendar")
     (client_id . ,org-gcal-client-id)
     (client_secret . ,org-gcal-client-secret))))

(if (and org-gcal-client-id org-gcal-client-secret)
    (org-gcal-reload-client-id-secret)
  ;; Don’t print warning during tests.
  (unless noninteractive
    (warn "org-gcal: must set ‘org-gcal-client-id’ and ‘org-gcal-client-secret’ for this package to work. Please run ‘org-gcal-reload-client-id-secret’ after setting these variables.")))

(provide 'org-gcal)

;;; org-gcal.el ends here
