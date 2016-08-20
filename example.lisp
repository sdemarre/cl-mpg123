(defpackage #:cl-mpg123-example
  (:use #:cl #:cffi)
  (:export #:main-low-level #:main-high-level)
  (:local-nicknames (:m :cl-mpg123-cffi)
                    (:o :cl-out123-cffi)))
(in-package #:cl-mpg123-example)

(defmacro with-err-return (form)
  (let ((code (gensym "CODE")))
    `(let ((,code ,form))
       (when (eql :err ,code)
         (error "~a failed: ~a" ',form (m:strerror ,code))))))

(defmacro with-err-param (code form)
  `(with-foreign-object (,code :pointer)
     ,form
     (let ((,code (cffi:mem-ref ,code 'm:errors)))
       (when (eql :err ,code)
         (error "~a failed: ~a" ',form (m:strerror ,code))))))

(defmacro with-handles ((mpg-handle out-handle) &body body)
  `(let ((,mpg-handle (null-pointer))
         (,out-handle (null-pointer))) 
     (unwind-protect
          (progn
            (with-err-param err (setf ,mpg-handle (m:new (null-pointer) err)))
            (setf ,out-handle (o:new))
            (when (null-pointer-p ,out-handle)
              (error "Failed to create output handler."))
            ,@body)
       (unless (null-pointer-p ,out-handle)
         (o:del ,out-handle))
       (unless (null-pointer-p ,mpg-handle)
         (m:close ,mpg-handle)
         (m:delete ,mpg-handle)))))

(defmacro with-mpeg-init (&body body)
  `(progn (with-err-return (m:init))
          (unwind-protect (progn ,@body)
            (m:exit))))

(defun mpeg-configure (encoding mpg-handle)
  (let ((enc (o:enc-byname encoding)))
    (m:format-none mpg-handle)
    (with-foreign-objects ((rates :pointer)
                           (ratec 'm:size_t))
      (m:rates rates ratec)
      (dotimes (i (cffi:mem-ref ratec 'm:size_t))
        (m:format mpg-handle
                  (cffi:mem-aref (cffi:mem-ref rates :pointer) :long i)
                  :mono-stereo
                  enc)))))

(defun mpeg-format (mpg-handle)
  (with-foreign-objects ((rate :long)
                         (channels :int)
                         (encoding :int))
    (with-err-return (m:getformat mpg-handle rate channels encoding))
    (values (cffi:mem-ref rate :long)
            (cffi:mem-ref channels :int)
            (cffi:mem-ref encoding :int))))

(defun out-info (out-handle)
  (with-foreign-objects ((driver :string)
                         (outfile :string))
    (with-err-return (o:driver-info out-handle driver outfile))
    (values (cffi:mem-ref driver :string)
            (cffi:mem-ref outfile :string))))

(defun out-format (out-handle)
  (with-foreign-objects ((rate :long)
                         (channels :int)
                         (encoding :int)
                         (framesize :int))
    (with-err-return (o:getformat out-handle rate channels encoding framesize))
    (values (cffi:mem-ref rate :long)
            (cffi:mem-ref channels :int)
            (cffi:mem-ref encoding :int)
            (cffi:mem-ref framesize :int))))

(defun main-lwo-level (file &key driver output encoding buffer-size)
  (let ((driver (or driver (null-pointer)))
        (output (or output (null-pointer))))
    (with-mpeg-init
      (with-handles (mpg-handle out-handle)
        (when encoding
          (mpeg-configure encoding mpg-handle))
        (with-err-return (m:open mpg-handle file))
        (multiple-value-bind (rate channels encoding) (mpeg-format mpg-handle)
          (m:format-none mpg-handle)
          (m:format mpg-handle rate channels encoding)
          (v:info :mpg123 "Input format ~a Hz, ~a channels, ~a encoded."
                  rate channels (o:enc-longname encoding))
          (with-err-return (o:open out-handle driver output))
          (multiple-value-bind (driver output) (out-info out-handle)
            (v:info :mpg123 "Playback device ~a / ~a" driver output))
          (with-err-return (o:start out-handle rate channels encoding))
          (multiple-value-bind (rate channels encoding framesize) (out-format out-handle)
            (v:info :mpg123 "Playback format ~a Hz, ~a channels, ~a encoded, ~a frames."
                    rate channels (o:enc-longname encoding) framesize))
          (let ((buffer-size (or buffer-size (m:outblock mpg-handle))))
            (with-foreign-objects ((buffer :char buffer-size)
                                   (read 'm:size_t))
              (loop do (with-err-return (m:read mpg-handle buffer buffer-size read))
                       (let* ((read (cffi:mem-ref read 'm:size_t))
                              (played (o:play out-handle buffer read)))
                         (when (/= played read)
                           (v:warn :mpg123 "Playback is not catching up with input by ~a bytes."
                                   (- read played)))
                         (when (<= read 0)
                           (return)))))))))))

(defun main-high-level (file &key driver output (buffer-size T))
  (let* ((file (cl-mpg123:connect (cl-mpg123:make-file file :buffer-size buffer-size)))
         (out  (cl-out123:connect (cl-out123:make-output driver :device output))))
    (v:info :mpg123 "Playback device ~a / ~a" (cl-out123:driver out) (cl-out123:device out))
    (multiple-value-bind (rate channels encoding) (cl-mpg123:file-format file)
      (v:info :mpg123 "Input format ~a Hz, ~a channels, ~a encoded." rate channels encoding)
      (cl-out123:start out :rate rate :channels channels :encoding encoding))
    (unwind-protect
         (loop with buffer = (cl-mpg123:buffer file)
               for read = (cl-mpg123:process file)
               for played = (cl-out123:play out buffer read)
               while (< 0 read)
               do (when (/= played read)
                    (v:warn :mpg123 "Playback is not catching up with input by ~a bytes."
                            (- read played))))
      (cl-out123:stop out)
      (cl-out123:disconnect out)
      (cl-mpg123:disconnect file))))
