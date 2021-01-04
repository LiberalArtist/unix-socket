#lang racket/base
(require racket/port
         racket/file
         rackunit
         racket/unix-socket
         (only-in racket/private/unix-socket-ffi platform)
         "common.rkt")


;; Commands for creating socket listeners
;;  - netcat is commonly available, but cannot use Linux abstract namespace
;;  - socat can use Linux abstract namespace, but is less common
;; So use netcat for path test and socat for abstract-name test.

(define netcat
  (for/first ([netcat '("/bin/nc" "/usr/bin/nc")]
              #:when (and (file-exists? netcat)
                          (memq 'execute (file-or-directory-permissions netcat))))
    netcat))

(define socat
  (for/first ([socat '("/usr/bin/socat")]
              #:when (and (file-exists? socat)
                          (memq 'execute (file-or-directory-permissions socat))))
    socat))

(define-check (check-comm msg out in)
  (write-bytes msg out)
  (flush-output out)
  (check-equal? (sync/timeout 1 (read-bytes-evt (bytes-length msg) in))
                msg))

(define (close-ports . ports)
  (for ([port ports])
    (cond [(input-port? port) (close-input-port port)]
          [(output-port? port) (close-output-port port)])))

(unless unix-socket-available?
  (error "cannot test unix sockets; not supported"))


;; ============================================================
;; connect tests

;; Test path-based socket
(test-case* "unix socket : connect w/ netcat"
  (unless netcat
    (printf "skipping connect w/ netcat; netcat not found\n"))
  (when netcat
    ;; Uses netcat to create a simple unix domain socket server
    (define tmp (make-temp-file-name))
    (call-in-custodian
     (lambda ()
       (define-values (ncprocess ncout ncin ncerr)
         (subprocess #f #f #f netcat "-Ul" (path->string tmp)))
       (sleep 0.5)
       (define-values (from-sock to-sock)
         (unix-socket-connect tmp))
       (check-comm #"hello" to-sock ncout)
       (check-comm #"charmed" ncin from-sock)
       (check-comm #"well\ngoodbye, then" to-sock ncout)
       (close-ports to-sock from-sock)
       (close-ports ncin ncout ncerr)
       (or (sync/timeout 1 ncprocess)
           (subprocess-kill ncprocess #t))
       ))
    (when (file-exists? tmp) (delete-file tmp))))

;; Test Linux abstract name socket
(test-case* "unix socket w/ socat, abstract namespace"
  (unless socat
    (printf "skipping connect w/ socat, abstract namespace; socat not found\n"))
  (when (and socat (eq? platform 'linux))
    ;; Uses socat to create a simple unix domain socket server
    (call-in-custodian
     (lambda ()
       (define name #"TestRacketABC")
       (define-values (ncprocess ncout ncin ncerr)
         (subprocess #f #f #f socat (format "ABSTRACT-LISTEN:~a" name) "STDIO"))
       (sleep 0.5)
       (define-values (from-sock to-sock)
         (unix-socket-connect (bytes-append #"\0" name)))
       (check-comm #"hello" to-sock ncout)
       (check-comm #"charmed" ncin from-sock)
       (check-comm #"well\ngoodbye, then" to-sock ncout)
       (close-ports to-sock from-sock)
       (close-ports ncin ncout ncerr)
       (or (sync/timeout 1 ncprocess)
           (subprocess-kill ncprocess #t))
       (void)
       ))))

;; ============================================================
;; combined connect and listen/accept tests

(define (combined-test sockaddr)
  (test-case* (format "unix socket: listen/connect/accept at ~e" sockaddr)
    (call-in-custodian
     (lambda ()
       (define l (unix-socket-listen sockaddr))
       (check-eq? (sync/timeout 0.1 l) #f "listener not ready if no connections")
       (define-values (cin cout) (unix-socket-connect sockaddr))
       (check-eq? (sync/timeout 0.1 l) l "listener ready when connection available")
       (define-values (ain aout) (unix-socket-accept l))
       (check-eq? (sync/timeout 0.1 l) #f "listener not ready after accepting only connection")
       ;; Check communication
       (check-comm #"hello" cout ain)
       (check-comm #"wow you sound a lot closer now" aout cin)
       (check-comm #"that's because\nwe're in\nthe same process!" cout ain)
       (check-comm #"ttfn" aout cin)
       ;; Check shutdown (after close, peer sees eof)
       (close-ports cout)  ;; shutdown client output
       (check-eq? (sync/timeout 0.1 ain) ain "server sees eof after client WR shutdown")
       (check-eq? (read-byte ain) eof)
       (check-comm #"but server can still talk!" aout cin)
       (close-ports aout) ;; shutdown server output
       (check-eq? (sync/timeout 0.1 cin) cin "client sees eof after server WR shutdown")
       (check-eq? (read-byte cin) eof)
       (close-ports cin ain)
       (when (and (path? sockaddr) (file-exists? sockaddr))
         (delete-file sockaddr))))))

;; Test path-based socket
(combined-test (make-temp-file-name))

;; Test Linux abstract name socket
(when (eq? platform 'linux)
  (combined-test #"\0TestRacketDEF"))

;; ============================================================
;; Misc

(test-case* "unix socket: listener close"
  (call-in-custodian
   (lambda ()
     (define tmp (make-temp-file-name))
     (define l (unix-socket-listen tmp))
     (check-eq? (sync/timeout 0.1 l) #f)
     (thread (lambda () (sleep 1) (unix-socket-close-listener l)))
     (check-eq? (sync/timeout 2 l) l)
     (check-exn #rx"listener is closed"
                (lambda () (unix-socket-accept l)))
     (when (file-exists? tmp) (delete-file tmp)))))

(test-case* "unix socket: listener syncs on custodian shutdown"
  (call-in-custodian
   (lambda ()
     (define tmp (make-temp-file-name))
     (define l (unix-socket-listen tmp))
     (check-eq? (sync/timeout 0.1 l) #f)
     (thread (lambda () (sleep 1) (custodian-shutdown-all (current-custodian))))
     (check-eq? (sync/timeout 2 l) l)
     (check-exn #rx"listener is closed"
                (lambda () (unix-socket-accept l)))
     (when (file-exists? tmp) (delete-file tmp)))))

(test-case* "unix socket: close disconnected ports okay"
  (call-in-custodian
   (lambda ()
     (define tmp (make-temp-file-name))
     (define l (unix-socket-listen tmp))
     (define-values (in out) (unix-socket-connect tmp))
     (define-values (ain aout) (unix-socket-accept l))
     (close-ports ain aout) (sleep 0.1)
     ;; in/out fd is now in disconnected state
     (close-ports in out)
     (when (file-exists? tmp) (delete-file tmp)))))

(test-case* "unix socket: custodian shutdown closes ports"
  (call-in-custodian
   (lambda ()
     (define tmp (make-temp-file-name))
     (define l (unix-socket-listen tmp))
     (define cust (make-custodian))
     (define-values (in out)
       (parameterize ((current-custodian cust))
         (unix-socket-connect tmp)))
     (define-values (ain aout) (unix-socket-accept l))
     (write-bytes #"buffering check check 1 2 3" out)
     (custodian-shutdown-all cust)
     (check-true (port-closed? in))
     (check-true (port-closed? out))
     (check-eq? (sync/timeout 0.1 ain) ain)
     (check member (read-char ain) (list #\b eof))
     (when (file-exists? tmp) (delete-file tmp)))))

(test-case* "accept-evt wakes up"
  (call-in-custodian
   (lambda ()
     (define tmp (make-temp-file-name))
     (define l (unix-socket-listen tmp))
     (define go-sema (make-semaphore 0))
     (define conn-thd
       (thread
        (lambda ()
          (sync go-sema)
          (sleep 0.5)
          (define-values (in out) (unix-socket-connect tmp))
          (close-input-port in)
          (close-output-port out))))
     (semaphore-post go-sema)
     (check-pred list? (sync (unix-socket-accept-evt l)))
     (when (file-exists? tmp) (delete-file tmp)))))

(test-case* "accept-evt wakes up on custodian shutdown"
  (call-in-custodian
   (lambda ()
     (define tmp (make-temp-file-name))
     (define c2 (make-custodian))
     (define l (parameterize ((current-custodian c2)) (unix-socket-listen tmp)))
     (define ae (parameterize ((current-custodian c2)) (unix-socket-accept-evt l)))
     (define chan (make-channel))
     (thread (lambda ()
               (with-handlers ([void (lambda (e) (channel-put chan 'exn) (void))])
                 (channel-put chan 'ready)
                 (sync ae)
                 (channel-put chan 'no-exn))))
     (check-equal? (channel-get chan) 'ready)
     (custodian-shutdown-all c2)
     (check-equal? (channel-get chan) 'exn))))

(test-case* "accept-evt in shutdown custodian"
  (call-in-custodian
   (lambda ()
     (define tmp (make-temp-file-name))
     (define l (unix-socket-listen tmp))
     (define c2 (make-custodian))
     (define ae (parameterize ((current-custodian c2)) (unix-socket-accept-evt l)))
     (custodian-shutdown-all c2)
     (thread (lambda () (unix-socket-connect tmp)))
     (check-exn #rx"the custodian has been shut down"
                (lambda () (sync ae))))))
