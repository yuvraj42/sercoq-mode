;;; sercoq.el --- Major mode for interacting with Coq proof assistant using SerAPI

;;; Commentary:

;;; Code:

(require 'sercoq-queue)

(defun sercoq--buffers ()
  "Return an alist containing buffer objects for buffers goal and response like proof-general has."
  `((goals . ,(get-buffer-create "*sercoq-goals*"))
    (response . ,(get-buffer-create "*sercoq-response*"))
    (errors . ,(get-buffer-create "*sercoq-errors*"))))


(defun sercoq-show-buffers (&optional alternate)
  "Show the goals and response buffers.
Default layout is that the current window is split vertically
\(i.e., new window is on the right instead of below)
and the right window is then split horizontally to form
the goal and response windows.
If ALTERNATE is non-nil, all windows are split horizontally"
  (interactive "S")
  
  (let-alist (sercoq--buffers)
    (let ((goals-window (get-buffer-window .goals))
	  (response-window (get-buffer-window .response)))
      (when goals-window (delete-window goals-window))
      (when response-window (delete-window response-window)))
    (with-selected-window (if alternate
			      (split-window)
			    (split-window-horizontally))
      (switch-to-buffer .goals)
      (with-selected-window (split-window)
	(switch-to-buffer .response)))))


(defun sercoq--show-error-buffer ()
  "Show the error buffer."
  (let-alist (sercoq--buffers)
  (let ((errors-window (get-buffer-window .errors)))
    (when errors-window (delete-window errors-window)))
  (with-selected-window (split-window)
    (switch-to-buffer .errors))))


(defun sercoq--show-error (errmsg)
  "Show error message ERRMSG in the error buffer."
  (with-current-buffer (alist-get 'errors (sercoq--buffers))
    (erase-buffer)
    (insert errmsg))
  (sercoq--show-error-buffer))


(defvar-local sercoq--state nil
  "Buffer-local object storing state of the ide")


(defun sercoq--get-fresh-state (process)
  "Initialize the state as an alist.
Fields in the alist:
- `process': the process object, set as PROCESS
- `sertop-queue': Queue of operations queued in sertop currently.  The items currently are  `parse', `exec',`goals', and `cancel'.
- `unexecd-sids': sentence ids that haven't been exec'd yet, ordered as most recent at the head of the list
- `sids' : a list (treated as a stack) containing all sentence ids returned by sertop, ordered as most recent at the head of the list
- `sentences': a hash map from sentence id to cons cells containing
beginning and end positions of the corresponding coq sentence in the document
- `accumulator': list of strings output by the process that have not been interpreted as sexps yet.
- `inprocess-region': a cons cell (beginning . end) denoting position of the string in the buffer that has been sent for parsing but hasn't been fully parsed yet
- `last-query-type': a symbol representing what kind of query was sent last.  currently only goals queries are supported so it will be set to 'Goals when a goals query is made..
- `checkpoint': the position upto which the buffer has been executed and is therefore locked"
  `((process . ,process)
    (sertop-queue . ,(sercoq-queue-create))
    (unexecd-sids . ,(list))
    ;; using (list) instead of nil because we need to modify this returned alist and constants shouldn't be modified destructively
    (sids . ,(list))
    (sentences . ,(make-hash-table :test 'eq))
    (accumulator . ,(list))
    (last-query-type . ,(list))
    (inprocess-region . ,(list))
    (checkpoint . ,1)))


(defmacro sercoq--get-state-variable (name)
  "Return the value of the variable given as NAME from the state's alist."
  `(alist-get ,name sercoq--state))


(defun sercoq--sertop-filter (proc str)
  "Accumulate the output strings STR of sertop process PROC which comes in arbitrary chunks, and once full response has been received, convert to sexps and act on it."

  (let* ((buf (process-buffer proc))
	 (state (buffer-local-value 'sercoq--state buf)))
    (when (and buf state)
      ;; (with-current-buffer (get-buffer-create "sercoq-sertop-output")
      ;; 	(insert str))
      (let-alist state
	(let ((parts (split-string str "\n" nil))
	      (full-responses nil))
	  (while (consp (cdr parts))
	    (push (pop parts) .accumulator)
	    (let ((msg-string (apply #'concat (nreverse .accumulator))))
	      (push (read msg-string) full-responses))
	    (setq .accumulator nil))
	  ;; since split-string was given nil, the last string in `parts'
	  ;; has not been read yet and will be after its remaining part arrives
	  ;; so it needs to be put into the accumulator
	  (push (car parts) .accumulator)

	  ;; reverse full-responses to put the responses in the correct order
	  (setq full-responses (nreverse full-responses))
	  ;; update the bindings in the alist
	  (setcdr (assq 'accumulator state) .accumulator)
	  (with-current-buffer buf
	  (sercoq--handle-new-responses full-responses)))))))


(defun sercoq--handle-new-responses (responses)
  "Sends the RESPONSES to their correct buffers."
  (dolist (response responses)
    (pcase response
      (`(Feedback ,feedback) (sercoq--handle-feedback feedback))
      
      (`(Answer ,_ ,answer) (sercoq--handle-answer answer))
      
      (other (error "Unknown sertop response %S" other)))))


(defun sercoq--handle-feedback (feedback)
  "Handle FEEDBACK, by adding the status to the corresponding overlay."
  (pcase feedback
    (`((doc_id ,_) (span_id ,sid)
       (route ,_) (contents ,contents))

     (let-alist sercoq--state
       (let ((sen (gethash sid .sentences))
	     (oldmessage ""))
	 (and sen
	   (pcase contents
	     ( `(Message (level Notice) ,_ ,_ (str ,newmessage))
	       ;; get any previous uncleared message that may be present
	       (setq oldmessage (get-text-property (car sen) 'help-echo))
	       ;; if there is existing message, concatenate newmessage to it
	       (when oldmessage
		 (setq newmessage (concat oldmessage "\n" newmessage)))
	       (let ((inhibit-read-only t))
		 (with-silent-modifications
		   (put-text-property (car sen) (cdr sen) 'help-echo newmessage)))
	       ;; put the received coq output in response buffer
	       (with-current-buffer (alist-get 'response (sercoq--buffers))
		 (erase-buffer)
		 (insert newmessage))))))))))


(defun sercoq--get-loc-bounds (loc)
  "Return the beginning and end positions from the LOC sexp."
  (pcase loc
    (`(,_ ,_ ,_ ,_ ,_ (bp ,bp) (ep ,ep)) `(,bp . ,ep))))


(defun sercoq--exninfo-string (exninfo)
  "Return the EXNINFO str component."
  (pcase exninfo
  (`(,_ ,_ ,_ ,_ ,_ (str ,string)) string)))


(defun sercoq--handle-add (sid loc)
  "Update buffer-local state by receiving answer for added sentences with sentence id SID and location LOC."
  (let ((pos (sercoq--get-loc-bounds loc)))
    ;; push to top of sids list
    (push sid (cdr (assq 'sids sercoq--state)))
    ;; push to unexecd-sids list
    (push sid (cdr (assq 'unexecd-sids sercoq--state)))
    ;; find out region's bounds and add to hash map
    (let* ((offset (sercoq--get-state-variable 'inprocess-region))
	   (chkpt (sercoq--get-state-variable 'checkpoint))
	   (beg (+ (car offset) (car pos)))
	   (end (+ (car offset) (cdr pos))))
      (puthash sid `(,beg . ,end) (cdr (assq 'sentences sercoq--state))))))


(defun sercoq--make-region-readonly (begin end)
  "Make the region marked by BEGIN and END read-only."
  (interactive "r")
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (add-text-properties begin end '(read-only t))
      (add-text-properties begin end '(face '(:background "dark green"))))))


(defun sercoq--make-readonly-region-writable (begin end)
  "Make the region marked by BEGIN and END writeable."
  (interactive "r")
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (remove-text-properties begin end '(read-only nil))
      ;; remove color
      (remove-text-properties begin end '(face '(:background nil))))))


(defun sercoq--update-checkpoint (newchkpt)
  "Update checkpoint in state to NEWCHKPT and also accordingly make region up to the checkpoint readonly and the rest writable."
  (let ((oldchkpt (sercoq--get-state-variable 'checkpoint)))
    (setcdr (assq 'checkpoint sercoq--state) newchkpt)
    ;; if checkpoint is increased, make the remaining region readonly
    (if (> newchkpt oldchkpt)
	(sercoq--make-region-readonly oldchkpt newchkpt)
      ;; else make freed region writable and remove other properties
      (progn (sercoq--make-readonly-region-writable newchkpt oldchkpt)
	     (sercoq--reset-added-text-properties newchkpt oldchkpt)))))


(defun sercoq--reset-added-text-properties (begin end)
  "Remove all properties sercoq-added to the text between BEGIN and END."
  (let ((inhibit-read-only t))
    (with-silent-modifications
    ;; remove echo message
      (remove-text-properties begin end '(help-echo nil)))))


(defun sercoq--remove-sid (sid)
  "Remove SID from `sids' and `sentences' in sercoq--state.  Make region of sid writable and remove added text properties."
  (setcdr (assq 'sids sercoq--state)
	  (delete sid (sercoq--get-state-variable 'sids)))
  (let ((pos (gethash sid (cdr (assq 'sentences sercoq--state)))))
    (remhash sid (cdr (assq 'sentences sercoq--state)))
    ;; update checkpoint
    (sercoq--update-checkpoint (car pos))))


(defun sercoq--handle-cancel (canceled)
  "Update buffer-local state when sertop cancels the sids in CANCELED."
  (mapc #'sercoq--remove-sid canceled)
  ;; in responses buffer, display the result of the sid that is now the last exec'd sid
  (if (sercoq--get-state-variable 'sids)
    (let* ((recent-sid (car (sercoq--get-state-variable 'sids)))
	   (pos (gethash recent-sid (sercoq--get-state-variable 'sentences)))
	   (new-response (get-text-property (car pos) 'help-echo)))
      (with-current-buffer (alist-get 'response (sercoq--buffers))
	(erase-buffer)
	(when new-response
	  (insert new-response))))
    ;; else just erase responses buffer if no valid sentences remain
      (with-current-buffer (alist-get 'response (sercoq--buffers))
	(erase-buffer))))


(defun sercoq--handle-obj (obj)
  "Handle obj type answer with coq object OBJ, which is usually a results of some query."
  (pcase obj
    (`(CoqString ,str)
     (pcase (sercoq--get-state-variable 'last-query-type)
       ('Goals
	;; insert str into goals buffer
	  (with-current-buffer (alist-get 'goals (sercoq--buffers))
	    (insert str)))))))


(defun sercoq--handle-answer (answer)
  "Handle ANSWER received from sertop."
  (pcase answer
    ('Ack ())
    ('Completed
     ;; dequeue sertop queue and make other changes appropriate to the dequeued element
     (pcase (sercoq--dequeue)
       ('parse (setcdr (assq 'inprocess-region sercoq--state) nil))
       ;; update checkpoint on successful execution
       ('exec (let* ((region (gethash (car (sercoq--get-state-variable 'sids))
					 (sercoq--get-state-variable 'sentences)))
			(end (cdr region))
			(checkpoint (sercoq--get-state-variable 'checkpoint)))
		   (unless (> checkpoint end)
		     (sercoq--update-checkpoint end))))
       ('cancel ())
       ('goals ())
       (_ (error "Received completion message from sertop for unknown command"))))
    
    (`(Added ,sid ,loc ,_) (sercoq--handle-add sid loc))
    (`(Canceled ,canceled-sids) (sercoq--handle-cancel canceled-sids))
    (`(ObjList ,objlist) (dolist (obj objlist)
			   (sercoq--handle-obj obj)))
    (`(CoqExn ,exninfo)
     (let ((queue (sercoq--get-state-variable 'sertop-queue))
	   (errormsg (sercoq--exninfo-string exninfo)))
     (pcase (sercoq-queue-front queue)
       ('parse (sercoq--handle-parse-error errormsg))
       ('exec (sercoq--handle-exec-error errormsg))
       (_ (sercoq--show-error errormsg)))))))


(defun sercoq--handle-parse-error (&optional errormsg)
  "Display parsing error message ERRORMSG to user and update state accordingly."
  ;; set inprocess region as nil
  (let* ((region (sercoq--get-state-variable 'inprocess-region))
	 (beg (number-to-string (car region)))
	 (end (number-to-string (cdr region))))
    (setcdr (assq 'inprocess-region sercoq--state) (list))
    ;; display error message
    (sercoq--show-error (concat "Parse error: " beg "-" end " :" errormsg))))


(defun sercoq--handle-exec-error (&optional errormsg)
  "Display semantic error message ERRORMSG to user and update state accordingly."
  (let* ((sids (sercoq--get-state-variable 'unexecd-sids))
	 (errorsid (car sids)) ;; the topmost sid in sids caused the error
	 (region (gethash errorsid (sercoq--get-state-variable 'sentences)))
	 (beg (number-to-string (car region)))
	 (end (number-to-string (cdr region))))
    ;; cancel statements with unexecd sids
    (sercoq--cancel-sids sids)
    ;; remove the sids from state variable `sids' as well
    (dolist (sid sids)
      (setcdr (assq 'sids sercoq--state)
	      (delete sid (sercoq--get-state-variable 'sids))))
    ;; set unexecd sids as nil
    (setcdr (assq 'unexecd-sids sercoq--state) (list))
    ;; display error message
    (sercoq--show-error (concat "Semantic error: " beg "-" end " :" errormsg))))


(defun sercoq--start-sertop ()
  "Start a new sertop process asynchronously."
  (let ((proc (make-process :name "sertop" :command '("sertop") :buffer (current-buffer) :sentinel #'ignore)))
    (set-process-filter proc #'sercoq--sertop-filter)
    (setq sercoq--state (sercoq--get-fresh-state proc))))


(defun sercoq-stop-sertop ()
  "Kill the running sertop process, if any."
  (interactive)
  (let-alist sercoq--state
    (if (and .process (process-live-p .process))
	(progn (set-process-filter .process #'ignore)
	       (delete-process .process)
	       (accept-process-output)
	       (message "Sercoq process stopped"))
      (message "No running instance of sertop")))
  (setq sercoq--state nil)
  (let-alist (sercoq--buffers)
    (kill-buffer .goals)
    (kill-buffer .response)
    (kill-buffer .errors))
  (delete-other-windows)
  (sercoq--make-readonly-region-writable (point-min) (point-max))
  (sercoq--reset-added-text-properties (point-min) (point-max))
  ;; switch to fundamental mode
  (fundamental-mode))


(defun sercoq--ensure-sertop ()
  "Start a sertop process if one isn't running already."
  (unless (sercoq--get-state-variable 'process)
    (message "Starting sertop")
    (sercoq--start-sertop)))


(defun sercoq--dequeue ()
  "Dequeue sertop queue and return the dequeued element."
  (let ((retval (sercoq-queue-dequeue (sercoq--get-state-variable 'sertop-queue))))
    (setcdr (assq 'sertop-queue sercoq--state) (car retval))
    (cdr retval)))


(defun sercoq--enqueue (operation)
  "Enqueue OPERATION to `sertop-queue'."
    (setcdr (assq 'sertop-queue sercoq--state)
	    (sercoq-queue-enqueue operation (sercoq--get-state-variable 'sertop-queue))))


(defun sercoq--pp-to-string (val)
  "Convert VAL to a printed sexp representation.
Difference from `pp-to-string' is that it renders nil as (), not nil."
  (if (listp val)
      (concat "(" (mapconcat #'sercoq--pp-to-string val " ") ")")
    (pp-to-string val)))


(defun sercoq--construct-add-cmd (str)
  "Construct an Add command with string STR to be sent to sertop."
  (list 'Add nil str))


(defun sercoq--construct-exec-cmd (sid)
  "Construct an Exec command with sid SID to be sent to sertop."
  `(Exec ,sid))


(defun sercoq--construct-cancel-cmd (sids)
  "Construct a Cancel command with list SIDS to be sent to sertop."
  `(Cancel ,sids))


(defun sercoq--construct-goals-query ()
  "Construct a goals query to be sent to sertop."
  `(Query ((pp ((pp_format PpStr)))) Goals))


(defun sercoq--send-to-sertop (sexp)
  "Send printed representation of SEXP to the running sertop process."
  ;; dont forget to send a newline at the end
  (let ((proc (sercoq--get-state-variable 'process)))
    (process-send-string proc (sercoq--pp-to-string sexp))
    (process-send-string proc "\n")))


(defun sercoq--balanced-comments-p (beg end)
  "Predicate to check if the string between BEG and END has balanced coq comments."
  (let* ((str (buffer-substring-no-properties beg end))
	 (unclosed 0) ;; number of unclosed comments
	 (index 0)
	 (len (length str)))
    
    (while (< index (1- len))
      (let ((c1 (aref str index))
	    (c2 (aref str (1+ index))))
	(if (char-equal c1 ?\()
	    (if (char-equal c2 ?*)
		(setq unclosed (1+ unclosed)))
	  
	  (if (char-equal c1 ?*)
	      (if (char-equal c2 ?\))
		  (setq unclosed (1- unclosed))))))
      (setq index (1+ index)))

    (equal unclosed 0))) ;; returns t if no unclosed comments in the string


(defun sercoq--cancel-sids (sids)
  "Cancels sentences with sids in the list SIDS."
  ;; cancel the sid (and hence all depending on it will be cancelled automatically by sertop)
  (sercoq--enqueue 'cancel)
  (sercoq--send-to-sertop (sercoq--construct-cancel-cmd sids)))


(defun sercoq--add-string (str)
  "Send an Add command to sertop with the given string STR."
  (let ((cmd (sercoq--construct-add-cmd str)))
    ;; enqueue `parse' to sertop queue
    (sercoq--enqueue 'parse)
    (sercoq--send-to-sertop cmd)))


(defun sercoq--wait-until-sertop-idle ()
  "Keep accepting process output until `sertop-queue' is empty."
  (while (not (sercoq-queue-emptyp (sercoq--get-state-variable 'sertop-queue)))
    (accept-process-output (sercoq--get-state-variable 'process))))


(defun sercoq--exec-unexecd-sids ()
  "Send exec command to sertop for all newly added i.e. unexec'd sids."
  ;; remember to reverse the unexec'd sids list
  (setcdr (assq 'unexecd-sids sercoq--state) (nreverse (sercoq--get-state-variable 'unexecd-sids)))
  ;; pop sids one by one and exec them
  (let (sid)
  (while (setq sid (car (sercoq--get-state-variable 'unexecd-sids)))
    ;; clear the response buffer whenever a new sid is exec'd
    (with-current-buffer (alist-get 'response (sercoq--buffers))
      (erase-buffer))
    ;; enqueue `exec' to sertop queue
    (sercoq--enqueue 'exec)
    ;; send exec command to sertop
    (sercoq--send-to-sertop (sercoq--construct-exec-cmd sid))
    ;; wait until execution is completed
    (sercoq--wait-until-sertop-idle)
    ;; pop the top sid
    (pop (sercoq--get-state-variable 'unexecd-sids)))))



(defun sercoq--update-goals ()
  "Send a goals query to sertop and update goals buffer."
  (interactive)
  ;; indicate in state that current query type is goals
  (setcdr (assq 'last-query-type sercoq--state) 'Goals)
  ;; clear the goals buffer)
  (with-current-buffer (alist-get 'goals (sercoq--buffers))
    (erase-buffer))
  ;; send a goals query
  (sercoq--enqueue 'goals)
  (sercoq--send-to-sertop (sercoq--construct-goals-query)))


(defun sercoq-forward-sentence ()
  "Move point to the end of the next coq sentence, skipping comments."
  (interactive)
  (let ((beg (point))
	(loop-condition t)
	(sentence-end-regex "\\.\\($\\|  \\| \\)[
]*"))
    ;; a make-shift exit control loop
    (while loop-condition
      (re-search-forward sentence-end-regex nil t) ;; the additional two arguments are to tell elisp to not raise error if no match is found
      (skip-chars-backward " \t\n")
      
      (when (sercoq--balanced-comments-p beg (point)) ;; when the comments are balanced, set loop-condition to exit loop
	(setq loop-condition nil)))))


(defun sercoq-exec-region (beg end)
  "Parse and execute the text in the region marked by BEG and END."
  (interactive "r")
  ;; update region boundaries to exclude text that overlaps with already executed text
  (unless (> beg (sercoq--get-state-variable 'checkpoint))
      (setq beg (sercoq--get-state-variable 'checkpoint)))

  (unless (> beg end)
    ;; set inprocess-region in state
    (setcdr (assq 'inprocess-region sercoq--state) `(,beg . ,end))
    (sercoq--add-string (buffer-substring-no-properties beg end))
    (sercoq--wait-until-sertop-idle)
    ;; now exec the newly added sids
    (sercoq--exec-unexecd-sids)
    ;; update goals
    (sercoq--update-goals)
    (sercoq-show-buffers)))


(defun sercoq-cancel-statements-upto-point (pt)
  "Revert execution of all sentences whose end lies after point PT."
  (interactive "d")
  (let ((sentences (sercoq--get-state-variable 'sentences))
	(sids (sercoq--get-state-variable 'sids))
	(sids-to-cancel (list)))

    ;; find which sids-to-cancel
    (while (and sids (< pt (cdr (gethash (car sids) sentences))))
      (push (car sids) sids-to-cancel)
      (setq sids (cdr sids)))

    ;; cancel the sid (and hence all depending on it will be cancelled automatically by sertop)
    (sercoq--cancel-sids sids-to-cancel)
    ;; update goals
    (sercoq--update-goals)))


(defun sercoq-exec-next-sentence ()
  "Find next full sentence after checkpoint and execute it."
  (interactive)
  (let ((beg (sercoq--get-state-variable 'checkpoint)))
    (goto-char beg)
    (sercoq-forward-sentence)
    (sercoq-exec-region beg (point))
    (forward-char)))


(defun sercoq-undo-previous-sentence ()
  "Undo the last executed sentence."
  (interactive)
  ;; move point to beginning of the last executed sentence and execute 'sercoq-cancel-statements-upto-point
  (let* ((sid (car (sercoq--get-state-variable 'sids)))
	 (pos (gethash sid (sercoq--get-state-variable 'sentences))))
    (goto-char (car pos))
    (sercoq-cancel-statements-upto-point (point))))


(defun sercoq-exec-buffer ()
  "Execute the entire buffer."
  (interactive)
  (sercoq-exec-region (point-min) (point-max)))


(defun sercoq-retract-buffer ()
  "Undo all executed parts of the buffer."
  (interactive)
  (sercoq-cancel-statements-upto-point (point-min)))


(defun sercoq-goto-end-of-locked ()
  "Go to the end of executed region."
  (interactive)
  (goto-char (sercoq--get-state-variable 'checkpoint)))


;; define the major mode function deriving from the basic mode `prog-mode'
(define-derived-mode sercoq-mode
  prog-mode "Sercoq"
  "Major mode for interacting with Coq."

  ;; add some keyboard shortcuts to the keymap
  (define-key sercoq-mode-map (kbd "M-e") #'sercoq-forward-sentence)
  (define-key sercoq-mode-map (kbd "C-c C-n") #'sercoq-exec-next-sentence)
  (define-key sercoq-mode-map (kbd "C-c C-u") #'sercoq-undo-previous-sentence)
  (define-key sercoq-mode-map (kbd "C-c C-b") #'sercoq-exec-buffer)
  (define-key sercoq-mode-map (kbd "C-c C-r") #'sercoq-retract-buffer)
  (define-key sercoq-mode-map (kbd "C-c C-.") #'sercoq-goto-end-of-locked)
  (define-key sercoq-mode-map (kbd "C-c C-c") #'sercoq-stop-sertop)
  
  ;; start sertop if not already started
  (sercoq--ensure-sertop))

;; TODO
;; New error buffer?


(provide 'sercoq)

;;; sercoq.el ends here
