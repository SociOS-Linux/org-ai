;;; org-ai.el --- Emacs org-mode integration for the OpenAI API  -*- lexical-binding: t; -*-

;; Copyright (C) 2023 Robert Krahn

;; Author: Robert Krahn <robert@kra.hn>
;; URL: https://github.com/rksm/org-ai
;; Version: 0.1.1
;; Package-Requires: ((emacs "28.2"))

;; This file is NOT part of GNU Emacs.

;; org-ai.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; org-ai.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with org-ai.el.
;; If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides a minor-mode for org-mode that allows you to interact with the
;; OpenAI API. It integrates ChatGPT and DALL-E into org-mode.
;; For more information, see https://github.com/rksm/org-ai.

;;; Code:

(require 'org)
(require 'org-element)
(require 'url)
(require 'url-http)
(require 'cl-lib)
(require 'gv)
(require 'json)

(defcustom org-ai-openai-api-token nil
  "This is your OpenAI API token that you need to specify. You can retrieve it at https://platform.openai.com/account/api-keys."
  :type 'string
  :group 'org-ai)

(defcustom org-ai-default-completion-model "text-davinci-003"
  "The default model to use for completion requests. See https://platform.openai.com/docs/models for other options."
  :type 'string
  :group 'org-ai)

(defcustom org-ai-default-chat-model "gpt-3.5-turbo"
  "The default model to use for chat-gpt requests. See https://platform.openai.com/docs/models for other options."
  :type 'string
  :group 'org-ai)

(defcustom org-ai-default-max-tokens 120
  "The default maximum number of tokens to generate. This is what costs money."
  :type 'string
  :group 'org-ai)

(defvar org-ai-openai-chat-endpoint "https://api.openai.com/v1/chat/completions")

(defvar org-ai-openai-completion-endpoint "https://api.openai.com/v1/completions")

(defvar org-ai-openai-image-generation-endpoint "https://api.openai.com/v1/images/generations")

(defvar org-ai-openai-image-variation-endpoint "https://api.openai.com/v1/images/variations")

(defvar org-ai--current-request-buffer nil
  "Internal var that stores the current request buffer.")

(defvar org-ai--current-request-callback nil
  "Internal var that stores the current request callback.")

(defvar org-ai--current-insert-position nil
  "Where to insert the result.")
(make-variable-buffer-local 'org-ai--current-insert-position)

(defvar org-ai--current-chat-role nil
  "During chat response streaming, this holds the role of the \"current speaker\".")

(defvar org-ai--chat-got-first-response nil)
(make-variable-buffer-local 'org-ai--chat-got-first-response)

(defvar org-ai--url-buffer-last-position nil
  "Local buffer var to store last read position.")
;; (make-variable-buffer-local 'org-ai--url-buffer-last-position)
;; (makunbound 'org-ai--url-buffer-last-position)

(defvar org-ai--debug-data nil)
(defvar org-ai--debug-data-raw nil)

;; (with-current-buffer "*scratch*"
;;   (erase-buffer)
;;   (pop-to-buffer "*scratch*" t)
;;   (let ((n 16))
;;    (insert (car (nth n org-ai--debug-data-raw)))
;;    (goto-char (cadr (nth n org-ai--debug-data-raw)))
;;    (beginning-of-line)))

;; define org-ai-mode-map
(defvar org-ai-mode-map
  (let ((map (make-sparse-keymap)))
    ;; (define-key map (kbd "C-c C-a") 'org-ai)
    map)
  "Keymap for `org-ai-mode'.")

;; create a minor-mode for org-mode
(define-minor-mode org-ai-mode
  "Toggle `org-ai-mode'."
        :init-value nil
        :lighter " org-ai"
        :keymap org-ai-mode-map
        :group 'org-ai
        (add-hook 'org-ctrl-c-ctrl-c-hook 'org-ai-ctrl-c-ctrl-c nil t))

(defun org-ai-keyboard-quit ()
  "If there is currently a running request, cancel it."
  (interactive)
  (condition-case _
      (when org-ai--current-request-buffer
        (org-ai-interrupt-current-request))
    (error nil)))

(defun org-ai-ctrl-c-ctrl-c ()
  "This is added to `org-ctrl-c-ctrl-c-hook' to enable the `org-mode' integration."
  (when-let ((context (org-ai-special-block)))
    (org-ai-complete-block)
    t))

(defun org-ai-special-block (&optional el)
  "Are we inside a #+begin_ai...#+end_ai block? `EL' is the current special block."
  (let (org-element-use-cache) ;; with cache enabled we get weird Cached element is incorrect warnings
    (let ((context (org-element-context el)))
      (if (equal 'special-block (org-element-type context))
          context
        (when-let ((parent (org-element-property :parent context)))
          (org-ai-special-block parent))))))

(defun org-ai-get-block-info (&optional context)
  "Parse the header of #+begin_ai...#+end_ai block.
`CONTEXT' is the context of the special block. Return an alist of
key-value pairs."
  (let* ((context (or context (org-ai-special-block)))
         (header-start (org-element-property :post-affiliated context))
         (header-end (org-element-property :contents-begin context))
         (string (string-trim (buffer-substring-no-properties header-start header-end)))
         (string (string-trim-left (replace-regexp-in-string "^#\\+begin_ai" "" string))))
    (org-babel-parse-header-arguments string)))

(defun org-ai-get-block-content (&optional context)
  "Extracts the text content of the #+begin_ai...#+end_ai block.
`CONTEXT' is the context of the special block."
  (let* ((context (or context (org-ai-special-block)))
         (content-start (org-element-property :contents-begin context))
         (content-end (org-element-property :contents-end context)))
    (string-trim (buffer-substring-no-properties content-start content-end))))

(defun org-ai--request-type (info)
  "Look at the header of the #+begin_ai...#+end_ai block.
returns the type of request. `INFO' is the alist of key-value
pairs from `org-ai-get-block-info'."
  (cond
   ((not (eql 'x (alist-get :chat info 'x))) 'chat)
   ((not (eql 'x (alist-get :completion info 'x))) 'completion)
   ((not (eql 'x (alist-get :image info 'x))) 'image)
   (t 'chat)))

(defun org-ai-complete-block ()
  "Main command which is normally bound to \\[org-ai-complete-block].
When you are inside an #+begin_ai...#+end_ai block, it will send
the text content to the OpenAI API and replace the block with the
result."
  (interactive)
  (let* ((context (org-ai-special-block))
         (content (org-ai-get-block-content context))
         (req-type (org-ai--request-type (org-ai-get-block-info context))))
    (cl-case req-type
      (completion (org-ai-stream-completion :prompt (encode-coding-string content 'utf-8) :context context))
      (image (org-ai-create-and-embed-image context))
      (t (org-ai-stream-completion :messages (org-ai--collect-chat-messages content) :context context)))))

(cl-defun org-ai-stream-completion (&optional &key prompt messages model max-tokens temperature top-p frequency-penalty presence-penalty context)
  "Start a server-sent event stream.
`PROMPT' is the query for completions `MESSAGES' is the query for
chatgpt. `MODEL' is the model to use. `MAX-TOKENS' is the maximum
number of tokens to generate. `TEMPERATURE' is the temperature of
the distribution. `TOP-P' is the top-p value. `FREQUENCY-PENALTY'
is the frequency penalty. `PRESENCE-PENALTY' is the presence
penalty. `CONTEXT' is the context of the special block."
  (let ((context (or context (org-ai-special-block)))
        (buffer (current-buffer)))
    (let* ((info (org-ai-get-block-info context))
           (model (or model (alist-get :model info) (if messages org-ai-default-chat-model org-ai-default-completion-model)))
           (max-tokens (or max-tokens (alist-get :max-tokens info) org-ai-default-max-tokens))
           (top-p (or top-p (alist-get :top-p info)))
           (temperature (or temperature (alist-get :temperature info)))
           (frequency-penalty (or frequency-penalty (alist-get :frequency-penalty info)))
           (presence-penalty (or presence-penalty (alist-get :presence-penalty info)))
           (callback (if messages
                         (lambda (result) (org-ai--insert-chat-completion-response context buffer result))
                       (lambda (result) (org-ai--insert-stream-completion-response context buffer result)))))
      (setq org-ai--current-insert-position nil)
      (setq org-ai--chat-got-first-response nil)
      (setq org-ai--debug-data nil)
      (setq org-ai--debug-data-raw nil)
      (org-ai-stream-request :prompt prompt
                             :messages messages
                             :model model
                             :max-tokens max-tokens
                             :temperature temperature
                             :top-p top-p
                             :frequency-penalty frequency-penalty
                             :presence-penalty presence-penalty
                             :callback callback))))

(defun org-ai--insert-stream-completion-response (context buffer &optional response)
  "Insert the response from the OpenAI API into the buffer.
`CONTEXT' is the context of the special block. `BUFFER' is the
buffer to insert the response into. `RESPONSE' is the response
from the OpenAI API."
  (if response
      (if-let ((error (plist-get response 'error)))
          (if-let ((message (plist-get error 'message))) (error message) (error error))
        (if-let* ((choice (aref (plist-get response 'choices) 0))
                  (text (plist-get choice 'text)))
            (with-current-buffer buffer
              (let ((pos (or org-ai--current-insert-position (org-element-property :contents-end context))))
                (save-excursion
                  (goto-char pos)
                  (when (string-suffix-p "#+end_ai" (buffer-substring-no-properties (point) (line-end-position)))
                    (insert "\n")
                    (backward-char))
                  (insert text)
                  (setq org-ai--current-insert-position (point)))))))))

(defun org-ai--insert-chat-completion-response (context buffer &optional response)
  "`RESPONSE' is one JSON message of the stream response.
When `RESPONSE' is nil, it means we are done. `CONTEXT' is the
context of the special block. `BUFFER' is the buffer to insert
the response into."
  (if response

      ;; process response
      (if-let ((error (plist-get response 'error)))
          (if-let ((message (plist-get error 'message))) (error message) (error error))
        (with-current-buffer buffer
          (let ((pos (or org-ai--current-insert-position (org-element-property :contents-end context))))
            (save-excursion
              (goto-char pos)

              ;; make sure we have enough space at end of block, don't write on same line
              (when (string-suffix-p "#+end_ai" (buffer-substring-no-properties (point) (line-end-position)))
                (insert "\n")
                (backward-char))

              ;; insert text
              (if-let* ((choices (or (alist-get 'choices response)
                                     (plist-get response 'choices)))
                        (choice (aref choices 0))
                        (delta (plist-get choice 'delta)))
                  (cond
                   ((plist-get delta 'content)
                    (let ((text (plist-get delta 'content)))
                      (when (or org-ai--chat-got-first-response (not (string= (string-trim text) "")))
                        (insert text))
                      (setq org-ai--chat-got-first-response t)))
                   ((plist-get delta 'role)
                    (let ((role (plist-get delta 'role)))
                      (progn
                        (setq org-ai--current-chat-role role)
                        (if (or (string= role "assistant") (string= role "system"))
                            (insert "\n[AI]: ")
                          (insert "\n[ME]: ")))))))

              (setq org-ai--current-insert-position (point))))))

    ;; insert new prompt and change position
    (with-current-buffer buffer
      (goto-char org-ai--current-insert-position)
      (insert "\n\n[ME]: "))))

(cl-defun org-ai-stream-request (&optional &key prompt messages callback model max-tokens temperature top-p frequency-penalty presence-penalty)
  "Send a request to the OpenAI API.
`PROMPT' is the query for completions `MESSAGES' is the query for
chatgpt. `CALLBACK' is the callback function. `MODEL' is the
model to use. `MAX-TOKENS' is the maximum number of tokens to
generate. `TEMPERATURE' is the temperature of the distribution.
`TOP-P' is the top-p value. `FREQUENCY-PENALTY' is the frequency
penalty. `PRESENCE-PENALTY' is the presence penalty."
  (let* ((token org-ai-openai-api-token)
         (url-request-extra-headers `(("Authorization" . ,(string-join `("Bearer" ,token) " "))
                                      ("Content-Type" . "application/json")))
         (url-request-method "POST")
         (endpoint (if messages org-ai-openai-chat-endpoint org-ai-openai-completion-endpoint))
         (url-request-data (org-ai--payload :prompt prompt
                                            :messages messages
                                            :model model
                                            :max-tokens max-tokens
                                            :temperature temperature
                                            :top-p top-p
                                            :frequency-penalty frequency-penalty
                                            :presence-penalty presence-penalty)))

    ;; (message "REQUEST %s" url-request-data)

    (setq org-ai--current-request-callback callback)

    (setq org-ai--current-request-buffer
          (url-retrieve
           endpoint
           (lambda (_events)
             (org-ai-reset-stream-state))))

    ;; (pop-to-buffer org-ai--current-request-buffer)

    (unless (member 'org-ai--url-request-on-change-function after-change-functions)
      (with-current-buffer org-ai--current-request-buffer
        (add-hook 'after-change-functions 'org-ai--url-request-on-change-function nil t)))))

(cl-defun org-ai--payload (&optional &key prompt messages model max-tokens temperature top-p frequency-penalty presence-penalty)
  "Create the payload for the OpenAI API.
`PROMPT' is the query for completions `MESSAGES' is the query for
chatgpt. `MODEL' is the model to use. `MAX-TOKENS' is the
maximum number of tokens to generate. `TEMPERATURE' is the
temperature of the distribution. `TOP-P' is the top-p value.
`FREQUENCY-PENALTY' is the frequency penalty. `PRESENCE-PENALTY'
is the presence penalty."
  (let* ((input (if messages `(messages . ,messages) `(prompt . ,prompt)))
         ;; TODO yet unsupported properties: n, stop, logit_bias, user
         (data (map-filter (lambda (x _) x)
                           `(,input
                             (model . ,model)
                             (stream . t)
                             ,@(when max-tokens        `((max_tokens . ,max-tokens)))
                             ,@(when temperature       `((temperature . ,temperature)))
                             ,@(when top-p             `((top_p . ,top-p)))
                             ,@(when frequency-penalty `((frequency_penalty . ,frequency-penalty)))
                             ,@(when presence-penalty  `((presence_penalty . ,presence-penalty)))))))
    (json-encode data)))

(defun org-ai--url-request-on-change-function (_beg _end _len)
  "Look into the url-request buffer and manually extracts JSON stream responses.
Three arguments are passed to each function: the positions of
the beginning and end of the range of changed text,
and the length in chars of the pre-change text replaced by that range."
  (with-current-buffer org-ai--current-request-buffer
    (when (and (boundp 'url-http-end-of-headers)
               (not (null url-http-end-of-headers)))
      (save-excursion
        (if org-ai--url-buffer-last-position
            (goto-char org-ai--url-buffer-last-position)
          (goto-char url-http-end-of-headers)
          (setq org-ai--url-buffer-last-position (point)))

        ;; Avoid a bug where we skip responses because url has modified the http
        ;; buffer and we are not where we think we are.
        ;; TODO this might break
        (unless (= (point) (line-end-position))
          (beginning-of-line))

        (when (> (point) (point-max))
          (goto-char (point-max)))

        (let ((errored nil))
          ;; (setq org-ai--debug-data-raw
          ;;       (append org-ai--debug-data-raw
          ;;               (list
          ;;                (list (buffer-substring-no-properties (point-min) (point-max))
          ;;                      (point)))))

          (while (and (not errored) (search-forward "data: " nil t))
            (let* ((line (buffer-substring-no-properties (point) (line-end-position))))
              ;; (message "...found data: %s" line)
              (if (string= line "[DONE]")
                  (progn
                    (when org-ai--current-request-callback
                      (funcall org-ai--current-request-callback nil))
                    (setq org-ai--url-buffer-last-position (point))
                    (org-ai-reset-stream-state)
                    (message "org-ai request done"))
                (let ((json-object-type 'plist)
                      (json-key-type 'symbol)
                      (json-array-type 'vector))
                  (condition-case _err
                      (let ((data (json-read)))
                        ;; (setq org-ai--debug-data (append org-ai--debug-data (list data)))
                        (when org-ai--current-request-callback
                          (funcall org-ai--current-request-callback data))
                        (setq org-ai--url-buffer-last-position (point)))
                    (error
                     (setq errored t)
                     (goto-char org-ai--url-buffer-last-position))))))))))))

(defun org-ai-interrupt-current-request ()
  "Interrupt the current request."
  (interactive)
  (when (and org-ai--current-request-buffer (buffer-live-p org-ai--current-request-buffer))
    (let (kill-buffer-query-functions)
      (kill-buffer org-ai--current-request-buffer))
    (org-ai-reset-stream-state)))

(defun org-ai-reset-stream-state ()
  "Reset the stream state."
  (interactive)
  (when (and org-ai--current-request-buffer (buffer-live-p org-ai--current-request-buffer))
    (with-current-buffer org-ai--current-request-buffer
      (remove-hook 'after-change-functions 'org-ai--url-request-on-change-function t)
      (setq org-ai--url-buffer-last-position nil)))
  (setq org-ai--current-request-callback nil)
  (setq org-ai--url-buffer-last-position nil)
  (setq org-ai--current-chat-role nil))

(defun org-ai--collect-chat-messages (content-string)
  "Takes `CONTENT-STRING' and splits it by [ME]: and [AI]: markers."
  (with-temp-buffer
   (erase-buffer)
   (insert content-string)
   (goto-char (point-min))

   (let* (;; collect all positions before [ME]: and [AI]:
          (sections (cl-loop while (search-forward-regexp "\\[ME\\]:\\|\\[AI\\]:" nil t)
                             collect (save-excursion
                                       (backward-char 5)
                                       (point))))

          ;; make sure we have from the beginning if there is no first marker
          (sections (if (not sections)
                        (list (point-min))
                        (if (not (= (car sections) (point-min)))
                               (cons (point-min) sections)
                             sections)))

          (parts (cl-loop for (start end) on sections by #'cdr
                          collect (string-trim (buffer-substring-no-properties start (or end (point-max))))))
          (parts (if (and
                      (not (string-suffix-p "[ME]:" (car parts)))
                      (not (string-suffix-p "[AI]:" (car parts))))
                     (progn (when (not (string-prefix-p "[ME]:" (car parts)))
                                (setf (car parts) (concat "[ME]: " (car parts))))
                            parts)
                   parts))

          ;; create (:role :content) list
          (messages (cl-loop for part in parts
                             for (type content) = (split-string part ":")
                             when (not (string-empty-p (string-trim content)))
                             collect (list :role (if (string= (string-trim type) "[ME]")
                                                     'user
                                                   'system)
                                           :content (encode-coding-string (string-trim content) 'utf-8))))

          ;; merge messages with same role
          (messages (cl-loop with last-role = nil
                             with result = nil
                             for (_ role _ content) in messages
                             if (eql role last-role)
                             do (let ((last (pop result)))
                                  (push (list :role role :content (string-join (list (plist-get last :content) content) "\n")) result))
                             else
                             do (push (list :role role :content content) result)
                             do (setq last-role role)
                             finally return (reverse result))))

     (apply #'vector messages))))

(cl-assert
 (equal
  (let ((test-string "\ntesting\n  [ME]: foo bar baz zorrk\nfoo\n[AI]: hello hello[ME]: "))
    (org-ai--collect-chat-messages test-string))
  '[(:role user :content "testing\nfoo bar baz zorrk\nfoo") (:role system :content "hello hello")]))

(cl-assert
 (equal
  (let ((test-string "[ME]: [ME]: hello")) (org-ai--collect-chat-messages test-string))
  '[(:role user :content "hello")]))

;; (comment
;;   (with-current-buffer "org-ai-mode-test.org"
;;    (org-ai--collect-chat-messages (org-ai-get-block-content))))

;; -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
;; DALL-E / image generation

(defcustom org-ai-image-director (expand-file-name "org-ai-images/" org-directory)
  "Directory where images are stored."
  :group 'org-ai
  :type 'directory)

(defun org-ai--image-save-base64-payload (base64-string file-name)
  "Write the base64 encoded payload `BASE64-STRING' to `FILE-NAME'."
  (with-temp-file file-name
    (insert (base64-decode-string base64-string))))

(defun org-ai--images-save (data size &optional prompt)
  "Save the image `DATA' to into a file. Use `SIZE' to determine the file name.
Also save the `PROMPT' to a file."
  (make-directory org-ai-image-director t)
  (cl-loop for ea across (alist-get 'data data)
           collect (let ((file-name (org-ai--make-up-new-image-file-name org-ai-image-director size)))
                     (when prompt (with-temp-file (string-replace ".png" ".txt" file-name) (insert prompt)))
                     (org-ai--image-save-base64-payload (alist-get 'b64_json ea) file-name)
                     file-name)))

(defun org-ai--make-up-new-image-file-name (dir size &optional n)
  "Make up a new file name for an image. Use `DIR' as the directory.
Use `SIZE' to determine the file name. If `N' is given, append it
to the file name."
  (let ((file-name (format "%s_%s_image%s.png"
                           (format-time-string "%Y%m%d" (current-time))
                           size
                           (if n (format "_%s" n) ""))))
    (if (file-exists-p (expand-file-name file-name dir))
        (org-ai--make-up-new-image-file-name dir size (1+ (or n 0)))
      (expand-file-name file-name dir))))

(cl-defun org-ai--image-request (prompt &optional &key n size callback)
  "Generate an image with `PROMPT'. Use `SIZE' to determine the size of the image.
`N' specifies the number of images to generate. If `CALLBACK' is
given, call it with the file name of the image as argument."
  (let* ((token org-ai-openai-api-token)
         (url-request-extra-headers `(("Authorization" . ,(string-join `("Bearer" ,token) " "))
                                      ("Content-Type" . "application/json")))
         (url-request-method "POST")
         (endpoint org-ai-openai-image-generation-endpoint)
         (n (or n 1))
         (size (or size "256x256"))
         (response-format "b64_json")
         (url-request-data (json-encode (map-filter (lambda (x _) x)
                                                    `((prompt . ,prompt)
                                                      (n . ,n)
                                                      (response_format . ,response-format)
                                                      (size . ,size))))))
    (let ((size size)
          (prompt prompt)
          (callback callback))
      (url-retrieve
       endpoint
       (lambda (_events)
         (when (and (boundp 'url-http-end-of-headers)
                    (not (eq url-http-end-of-headers nil)))
           (goto-char url-http-end-of-headers)
           (let ((files (org-ai--images-save (json-read) size prompt)))
             (when callback
               (cl-loop for file in files
                        for i from 0
                        do (funcall callback file i))))))))))

(defun org-ai-create-and-embed-image (context)
  "Create an image with the prompt from the current block.
Embed the image in the current buffer. `CONTEXT' is the context
object."
  (let* ((prompt (org-ai-get-block-content context))
         (prompt (encode-coding-string prompt 'utf-8))
         (info (org-ai-get-block-info context))
         (size (or (alist-get :size info) "256x256"))
         (n (or (alist-get :n info) 1)))
    (let ((buffer (current-buffer)))
      (org-ai--image-request prompt
                             :n n
                             :size size
                             :callback (lambda (file i)
                                         (message "saved %s" file)
                                         (with-current-buffer buffer
                                           (save-excursion
                                             (let ((name (plist-get (cadr (org-ai-special-block)) :name))
                                                   (contents-end (plist-get (cadr (org-ai-special-block)) :contents-end)))
                                               (goto-char contents-end)
                                               (forward-line)
                                               (when name
                                                 (insert (format "#+NAME: %s%s\n" name (if (> n 0) (format "_%s" i) "") )))
                                               (insert (format "[[file:%s]]\n" file))
                                               (org-display-inline-images)))))))))

;; -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
;; image variation

(defun org-ai-image-variation (n size)
  "Generate `N' variations of the image at point (a link pointing to a file).
Use `SIZE' to determine the size of the image."
  (interactive (list (read-number "n: " 1)
                     (completing-read "size: " '("256x256" "512x512" "1024x1024") nil t "256x256" nil "256x256")))
  (if-let* ((path (org-ai--image-variation--get-path-of-link-at-point))
            ;;(base64-data (org-ai--image-variation--read-image-as-base64 path))
            ;;(data (org-ai--image-variation--read-image-raw path))
            )
      (let ((buffer (current-buffer)))
        (org-ai--image-variation-request path
                               :n n
                               :size size
                               :callback (lambda (file _i)
                                           (message "saved %s" file)
                                           (with-current-buffer buffer
                                             (save-excursion
                                               (move-end-of-line 1)
                                               (insert (format "\n[[file:%s]]\n" file))
                                               (org-display-inline-images))))))
    (warn "No image at point")))

(cl-defun org-ai--image-variation-request (image-file-path &key n size callback)
  "Generate an image similar to `IMAGE-FILE-PATH'.
Use `SIZE' to determine the size of the image. `N' specifies the
number of images to generate. If `CALLBACK' is given, call it
with the file name of the image as argument. Note this requries
curl to be installed."
  (let ((command (format "curl --silent %s \\
                         -H 'Authorization: Bearer %s' \\
                         -F image='@%s' \\
                         -F n=%s \\
                         -F size=\"%s\" \\
                         -F response_format=\"b64_json\""
                         org-ai-openai-image-variation-endpoint
                         org-ai-openai-api-token
                         image-file-path
                         n
                         size)))

    (with-temp-buffer
      (condition-case err
          (progn (shell-command command (current-buffer))
                 (goto-char (point-min))
                 (let ((files (org-ai--images-save (json-read) size)))
                   (when callback
                     (cl-loop for file in files
                              for i from 0
                              do (funcall callback file i)))))

        (error (let ((buffer-content (buffer-string))
                     (error-buffer (get-buffer-create "*org-ai-image-variation-error*")))
                 (with-current-buffer error-buffer
                   (erase-buffer)
                   (insert buffer-content))
                 (pop-to-buffer error-buffer))
               (error err))))))

(defun org-ai-open-account-usage-page ()
  "Open web browser with the OpenAI account usage page.
So you now how deep you're in the rabbit hole."
  (interactive)
  (browse-url "https://platform.openai.com/account/usage"))

(defun org-ai--image-variation--get-path-of-link-at-point ()
  "Read the path of the link at point.
Return nil if there is no link at point."
  (let* ((context
	  ;; Only consider supported types, even if they are not the
	  ;; closest one.
	  (org-element-lineage (org-element-context) '(link) t)))
    (when context
        (org-element-property :path context))))

(defun org-ai--image-variation--read-image-as-base64 (path)
  "Read the image at `PATH' and return it as base64 encoded string."
  (when (file-exists-p path)
    (if-let* ((path (org-ai--image-variation--get-path-of-link-at-point))
              (buffer (find-file-noselect path)))
        (prog1
            (with-current-buffer buffer
              (base64-encode-string (buffer-string) t))
          (kill-buffer buffer)))))

;; -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

(provide 'org-ai)

;;; org-ai.el ends here
