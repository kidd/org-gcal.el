;;; org-gcal.el --- Org sync with Google Calendar -*- lexical-binding: t -*-

;; Author: myuhe <yuhei.maeda_at_gmail.com>
;; URL: https://github.com/kidd/org-gcal.el
;; Version: 0.3
;; Maintainer: Raimon Grau <raimonster@gmail.com>
;; Copyright (C) :2014 myuhe all rights reserved.
;; Package-Requires: ((alert "1.1") (oauth2 "0.11") (emacs "24") (cl-lib "0.5") (org "8.2.4"))
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
(require 'org-element)
(require 'org-archive)
(require 'cl-lib)
(require 'oauth2)

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

(defun org-gcal-auth ()
  "Authorize."
  (oauth2-auth-and-store org-gcal-auth-url
                         org-gcal-token-url
                         org-gcal-resource-url
                         org-gcal-client-id
                         org-gcal-client-secret
                         "urn:ietf:wg:oauth:2.0:oob"))

(defun rgc-cb (b cal skip-export)
  (interactive)
  (let ((json-object-type 'plist))
    (org-gcal--sync cal (json-read) skip-export)))

(defun rgc-cb-sync (b cal skip-export)
  (interactive)
  (with-current-buffer b
    (let ((json-object-type 'plist))
     (org-gcal--sync cal (json-read) skip-export))))

;;;###autoload
(defun org-gcal-sync (&optional skip-export)
  "Import events from calendars.
Export the ones to the calendar unless SKIP-EXPORT."
  (interactive)
  (when org-gcal-auto-archive
    (dolist (i org-gcal-file-alist)
      (with-current-buffer
          (find-file-noselect (cdr i))
        (org-gcal--archive-old-event))))
  (dolist (cal org-gcal-file-alist)
    (let ((b (oauth2-url-retrieve-synchronously
              (org-gcal-auth)
              (format "%s?%s"
                      (format org-gcal-events-url (first cal))
                      (format "singleEvents=True&orderBy=startTime&timeMin=%s&timeMax=%s"
                              (org-gcal--subtract-time)
                              (org-gcal--add-time)))
              ;; 'rgc-cb
              ;; (list cal skip-export)
              )))
      (rgc-cb-sync b cal skip-export))))

(defun org-gcal--sync (x data &optional skip-export)
  "An X. Also data."
  (interactive)
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
                 (org-gcal-post-at-point)
                 finally
                 (kill-buffer buf))
        (sit-for 2)
        (org-gcal-sync t)))
    (erase-buffer)
    (let ((items (org-gcal--filter (plist-get data :items ))))
		  (if (assoc (car x) org-gcal-header-alist)
			    (insert (cdr (assoc (car x) org-gcal-header-alist))))
      (insert
       (mapconcat 'identity
                  (mapcar (lambda (lst)
                            (org-gcal--cons-list lst))
                          items) ""))
      (let ((plst (with-temp-buffer (insert-file-contents org-gcal-token-file)
                                    (read (buffer-string)))))
        (with-temp-file org-gcal-token-file
          (pp (plist-put plst
                         (intern (concat ":" (car x)))
                         (mapcar (lambda (lst)
                                   (cons (plist-get lst :id) (org-gcal--cons-list lst)))
                                 items)) (current-buffer)))))
    (org-set-startup-visibility)
    (save-buffer)))

;;;###autoload
(defun org-gcal-fetch ()
  "Fetch event data from google calendar."
  (interactive)
  (org-gcal-sync t))

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
(defun org-gcal-post-at-point ()
  "Post entry at point to current calendar.
If SKIP-IMPORT is not nil, do not import events from the
current calendar."
  (interactive)
  (save-excursion
    (end-of-line)
    (org-back-to-heading)
    (let* ((elem (org-element-headline-parser (point-max) t))
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
                                                 " *:PROPERTIES:\n *\\(.*\\(?:\n.*\\)*?\\) *:END:\n+"
                                                 ""
                                                 (buffer-substring-no-properties
                                                  (plist-get (cadr elem) :contents-begin)
                                                  (plist-get (cadr elem) :contents-end)))))
                   "")))
      (org-gcal--post-event start end smry loc desc id))))

;;;###autoload
(defun org-gcal-delete-at-point ()
  "Delete entry at point to current calendar."
  (interactive)
  (save-excursion
    (end-of-line)
    (org-back-to-heading)
    (let* ((elem (org-element-headline-parser (point-max) t))
           (smry (org-element-property :title elem))
           (id (org-element-property :ID elem)))
      (when (and id
                 (y-or-n-p (format "Do you really want to delete event?\n\n%s\n\n" smry)))
        (org-gcal--delete-event id)))))

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
     (when loc "  :LOCATION: ") loc (when loc "\n")
     "  :LINK: ""[[" link "][Go to gcal web page]]\n"
     (when meet
       (format "  %s [[%s][%s]]\n"
               ":HANGOUTS:"
               meet
               "Join Hangouts Meet"))
     "  :ID: " id "\n"
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

(defun org-gcal--get-calendar-id-of-buffer ()
  "Find calendar id of current buffer."
  (or (cl-loop for (id . file) in org-gcal-file-alist
               if (file-equal-p file (buffer-file-name (buffer-base-buffer)))
               return id)
      (user-error (concat "Buffer `%s' may not related to google calendar; "
                          "please check/configure `org-gcal-file-alist'")
                  (buffer-name))))

(defun org-gcal-start-date (time)
    (if (< 11 (length time))
      `("start" ("dateTime" .  ,time) ("date" .  nil))
    `("start" ("date" .  ,time) ("dateTime" .  nil))))

(defun org-gcal-end-date (time)
  (if (< 11 (length time))
      `("end" ("dateTime" . ,time) ("date" .  nil))
    `("end" ("date" .  ,(org-gcal--iso-next-day time)) ("dateTime" .  nil))))

(defun org-gcal--post-event (start end smry loc desc &optional id)
  (let ((method (if id "PATCH" "POST"))
        (id (or id "")))
    (org-gcal--post-event-internal
     start end smry loc desc method
     (concat (format org-gcal-events-url (org-gcal--get-calendar-id-of-buffer)) "/" id))))

(defun org-gcal--post-event-internal (start end smry loc desc method url)
  (oauth2-url-retrieve
   (org-gcal-auth)
   url
   (lambda (status) (org-gcal-fetch))
   nil
   method
   (encode-coding-string
    (json-encode `(,(org-gcal-start-date start)
                   ,(org-gcal-end-date end)
                   ("summary" . ,smry)
                   ("location" . ,loc)
                   ("description" . ,desc)))
    'utf-8)
   '(("Content-Type" . "application/json"))))

(defun org-gcal--delete-event (event-id)
  "Delete event EVENT-ID."
  (interactive)
  (oauth2-url-retrieve
   (org-gcal-auth)
   (format "%s/%s"
           (format org-gcal-events-url
                   (org-gcal--get-calendar-id-of-buffer))
           event-id)
   (lambda (status) (org-gcal-fetch))
   nil
   "DELETE"))

(defun org-gcal--capture-post ()
  (dolist (i org-gcal-file-alist)
    (when (string=  (file-name-nondirectory (cdr i))
                    (substring (buffer-name) 8))
      (org-gcal-post-at-point))))

(add-hook 'org-capture-before-finalize-hook 'org-gcal--capture-post)

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
