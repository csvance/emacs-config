;;; local-llm.el --- The local model that notes and other features share -*- lexical-binding: t; -*-

;;; Commentary:

;; One OpenAI-compatible server (such as vLLM), named in local.el, its key in
;; secrets/authinfo under the server's HOST:PORT.  `local-llm-request' sends it
;; a prompt with no tools, asks for a reply shaped by a JSON schema, and hands
;; the parsed reply to a callback, in the background.

;;; Code:

(require 'gptel)

(defgroup local-llm nil
  "The local model shared by notes and other features."
  :group 'external)

(define-obsolete-variable-alias 'notes-model-host 'local-llm-host "2026-10")
(define-obsolete-variable-alias 'notes-model 'local-llm-model "2026-10")

(defcustom local-llm-host nil
  "HOST:PORT of the OpenAI-compatible server, over HTTPS.
It is also the machine name of the server's key in secrets/authinfo.  Set in
local.el; while it is nil, nothing is sent."
  :type '(choice (const nil) string))

(defcustom local-llm-model nil
  "Name of the model on `local-llm-host'.  Set in local.el."
  :type '(choice (const nil) string))

(defun local-llm-available-p ()
  "Non-nil if a server and model are set."
  (and local-llm-host local-llm-model t))

(defun local-llm--backend ()
  "The gptel backend for `local-llm-host' and `local-llm-model'."
  (let ((host local-llm-host))
    (gptel-make-openai "local"
      :host host
      :key (lambda () (gptel-api-key-from-auth-source host))
      :protocol "https"
      :endpoint "/v1/chat/completions"
      :stream nil
      :models (list (intern local-llm-model)))))

(defun local-llm-request (prompt system schema callback)
  "Send PROMPT with SYSTEM instructions, asking for a reply shaped by SCHEMA.
Call CALLBACK once, with (DATA nil) where DATA is the reply parsed into a
plist, or with (nil ERROR-MESSAGE)."
  (let* ((gptel-backend (local-llm--backend))
         (gptel-model (car (gptel-backend-models gptel-backend)))
         (gptel-use-tools nil))
    (gptel-request prompt
      :system system
      :schema schema
      :callback
      (lambda (reply info)
        (cond
         ;; A reasoning model's thinking arrives first, then the reply
         ((or (eq reply t) (eq (car-safe reply) 'reasoning)))
         ((stringp reply)
          (let (data problem)
            (condition-case err
                (setq data (json-parse-string reply :object-type 'plist :array-type 'list))
              (error (setq problem (error-message-string err))))
            (funcall callback data problem)))
         (t (funcall callback nil (format "%s" (plist-get info :status)))))))))

(provide 'local-llm)
;;; local-llm.el ends here
