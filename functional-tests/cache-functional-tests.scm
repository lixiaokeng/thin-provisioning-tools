(library
  (cache-functional-tests)
  (export register-cache-tests)
  (import (chezscheme)
          (disk-units)
          (functional-tests)
          (cache-xml)
          (fmt fmt)
          (process)
          (scenario-string-constants)
          (temp-file)
          (srfi s8 receive))

  (define-tool cache-check)
  (define-tool cache-dump)
  (define-tool cache-restore)
  (define-tool cache-metadata-size)
  (define-tool cache-repair)

  (define-syntax with-cache-xml
    (syntax-rules ()
      ((_ (v) b1 b2 ...)
       (with-temp-file-containing ((v "cache.xml" (fmt #f (generate-xml 512 1024 128))))
         b1 b2 ...))))

  (define-syntax with-valid-metadata
    (syntax-rules ()
      ((_ (md) b1 b2 ...)
       (with-temp-file-sized ((md "cache.bin" (to-bytes (meg 4))))
         (with-cache-xml (xml)
           (run-ok (cache-restore "-i" xml "-o" md))
           b1 b2 ...)))))

  ;;; It would be nice if the metadata was at least similar to valid data.
  (define-syntax with-corrupt-metadata
    (syntax-rules ()
      ((_ (md) b1 b2 ...)
       (with-temp-file-sized ((md "cache.bin" (to-bytes (meg 4))))
         (system (fmt #f "dd if=/usr/bin/ls of=" md " bs=4096 > /dev/null 2>&1"))
           b1 b2 ...))))

  (define-syntax with-empty-metadata
    (syntax-rules ()
      ((_ (md) b1 b2 ...)
       (with-temp-file-sized ((md "cache.bin" (to-bytes (meg 4))))
                            b1 b2 ...))))

  ;; We have to export something that forces all the initialisation expressions
  ;; to run.
  (define (register-cache-tests) #t)

  ;;;-----------------------------------------------------------
  ;;; cache_restore scenarios
  ;;;-----------------------------------------------------------

  (define-scenario (cache-restore v)
    "print version (-V flag)"
    (run-ok-rcv (stdout _) (cache-restore "-V")
      (assert-equal tools-version stdout)))

  (define-scenario (cache-restore version)
    "print version (--version flags)"
    (run-ok-rcv (stdout _) (cache-restore "--version")
      (assert-equal tools-version stdout)))

  (define-scenario (cache-restore h)
    "cache_restore -h"
    (run-ok-rcv (stdout _) (cache-restore "-h")
      (assert-equal cache-restore-help stdout)))

  (define-scenario (cache-restore help)
    "cache_restore --help"
    (run-ok-rcv (stdout _) (cache-restore "--help")
      (assert-equal cache-restore-help stdout)))

  (define-scenario (cache-restore no-input-file)
    "forget to specify an input file"
    (with-empty-metadata (md)
      (run-fail-rcv (_ stderr) (cache-restore "-o" md)
        (assert-starts-with "No input file provided." stderr))))

  (define-scenario (cache-restore missing-input-file)
    "the input file can't be found"
    (with-empty-metadata (md)
      (run-fail-rcv (_ stderr) (cache-restore "-i no-such-file -o" md)
        (assert-superblock-all-zeroes md)
        (assert-starts-with "Couldn't stat file" stderr))))

  (define-scenario (cache-restore garbage-input-file)
    "the input file is just zeroes"
    (with-empty-metadata (md)
      (with-temp-file-sized ((xml "cache.xml" 4096))
        (run-fail-rcv (_ stderr) (cache-restore "-i" xml "-o" md)
          (assert-superblock-all-zeroes md)))))

  (define-scenario (cache-restore missing-output-file)
    "the output file can't be found"
    (with-cache-xml (xml)
      (run-fail-rcv (_ stderr) (cache-restore "-i" xml)
        (assert-starts-with "No output file provided." stderr))))

  (define-scenario (cache-restore tiny-output-file)
    "Fails if the output file is too small."
    (with-temp-file-sized ((md "cache.bin" (* 1024 4)))
      (with-cache-xml (xml)
        (run-fail-rcv (_ stderr) (cache-restore "-i" xml "-o" md)
          (assert-starts-with cache-restore-outfile-too-small-text stderr)))))

  (define-scenario (cache-restore successfully-restores)
    "Restore succeeds."
    (with-empty-metadata (md)
      (with-cache-xml (xml)
        (run-ok (cache-restore "-i" xml "-o" md)))))

  (define-scenario (cache-restore q)
    "cache_restore accepts -q"
    (with-empty-metadata (md)
      (with-cache-xml (xml)
        (run-ok-rcv (stdout stderr) (cache-restore "-i" xml "-o" md "-q")
          (assert-eof stdout)
          (assert-eof stderr)))))

  (define-scenario (cache-restore quiet)
    "cache_restore accepts --quiet"
    (with-empty-metadata (md)
      (with-cache-xml (xml)
        (run-ok-rcv (stdout stderr) (cache-restore "-i" xml "-o" md "--quiet")
          (assert-eof stdout)
          (assert-eof stderr)))))

  (define-scenario (cache-restore override-metadata-version)
    "we can set any metadata version"
    (with-empty-metadata (md)
      (with-cache-xml (xml)
        (run-ok
          (cache-restore "-i" xml "-o" md "--debug-override-metadata-version 10298")))))

  (define-scenario (cache-restore omit-clean-shutdown)
    "accepts --omit-clean-shutdown"
    (with-empty-metadata (md)
      (with-cache-xml (xml)
        (run-ok
          (cache-restore "-i" xml "-o" md "--omit-clean-shutdown")))))

  ;;;-----------------------------------------------------------
  ;;; cache_dump scenarios
  ;;;-----------------------------------------------------------

  (define-scenario (cache-dump v)
    "print version (-V flag)"
    (run-ok-rcv (stdout _) (cache-dump "-V")
      (assert-equal tools-version stdout)))

  (define-scenario (cache-dump version)
    "print version (--version flags)"
    (run-ok-rcv (stdout _) (cache-dump "--version")
      (assert-equal tools-version stdout)))

  (define-scenario (cache-dump h)
    "cache_dump -h"
    (run-ok-rcv (stdout _) (cache-dump "-h")
      (assert-equal cache-dump-help stdout)))

  (define-scenario (cache-dump help)
    "cache_dump --help"
    (run-ok-rcv (stdout _) (cache-dump "--help")
      (assert-equal cache-dump-help stdout)))

  (define-scenario (cache-dump missing-input-file)
    "Fails with missing input file."
    (run-fail-rcv (stdout stderr) (cache-dump)
      (assert-starts-with "No input file provided." stderr)))

  (define-scenario (cache-dump small-input-file)
    "Fails with small input file"
    (with-temp-file-sized ((md "cache.bin" 512))
      (run-fail
        (cache-dump md))))

  (define-scenario (cache-dump restore-is-noop)
    "cache_dump followed by cache_restore is a noop."
    (with-valid-metadata (md)
      (run-ok-rcv (d1-stdout _) (cache-dump md)
        (with-temp-file-containing ((xml "cache.xml" d1-stdout))
          (run-ok (cache-restore "-i" xml "-o" md))
          (run-ok-rcv (d2-stdout _) (cache-dump md)
            (assert-equal d1-stdout d2-stdout))))))

  ;;;-----------------------------------------------------------
  ;;; cache_metadata_size scenarios
  ;;;-----------------------------------------------------------

  (define-scenario (cache-metadata-size v)
    "cache_metadata_size -V"
    (run-ok-rcv (stdout _) (cache-metadata-size "-V")
      (assert-equal tools-version stdout)))

  (define-scenario (cache-metadata-size version)
    "cache_metadata_size --version"
    (run-ok-rcv (stdout _) (cache-metadata-size "--version")
      (assert-equal tools-version stdout)))

  (define-scenario (cache-metadata-size h)
    "cache_metadata_size -h"
    (run-ok-rcv (stdout _) (cache-metadata-size "-h")
      (assert-equal cache-metadata-size-help stdout)))

  (define-scenario (cache-metadata-size help)
    "cache_metadata_size --help"
    (run-ok-rcv (stdout _) (cache-metadata-size "--help")
      (assert-equal cache-metadata-size-help stdout)))

  (define-scenario (cache-metadata-size no-args)
    "No arguments specified causes fail"
    (run-fail-rcv (_ stderr) (cache-metadata-size)
      (assert-equal "Please specify either --device-size and --block-size, or --nr-blocks."
                    stderr)))

  (define-scenario (cache-metadata-size device-size-only)
    "Just --device-size causes fail"
    (run-fail-rcv (_ stderr) (cache-metadata-size "--device-size" (to-bytes (meg 100)))
      (assert-equal "If you specify --device-size you must also give --block-size."
                    stderr)))

  (define-scenario (cache-metadata-size block-size-only)
    "Just --block-size causes fail"
    (run-fail-rcv (_ stderr) (cache-metadata-size "--block-size" 128)
      (assert-equal "If you specify --block-size you must also give --device-size."
                    stderr)))

  (define-scenario (cache-metadata-size conradictory-info-fails)
    "Contradictory info causes fail"
    (run-fail-rcv (_ stderr) (cache-metadata-size "--device-size 102400 --block-size 1000 --nr-blocks 6")
      (assert-equal "Contradictory arguments given, --nr-blocks doesn't match the --device-size and --block-size."
                    stderr)))

  (define-scenario (cache-metadata-size all-args-agree)
    "All args agreeing succeeds"
    (run-ok-rcv (stdout stderr) (cache-metadata-size "--device-size" 102400 "--block-size" 100 "--nr-blocks" 1024)
      (assert-equal "8248 sectors" stdout)
      (assert-eof stderr)))

  (define-scenario (cache-metadata-size nr-blocks-alone)
    "Just --nr-blocks succeeds"
    (run-ok-rcv (stdout stderr) (cache-metadata-size "--nr-blocks" 1024)
      (assert-equal "8248 sectors" stdout)
      (assert-eof stderr)))

  (define-scenario (cache-metadata-size dev-size-and-block-size-succeeds)
    "Specifying --device-size with --block-size succeeds"
    (run-ok-rcv (stdout stderr) (cache-metadata-size "--device-size" 102400 "--block-size" 100)
      (assert-equal "8248 sectors" stdout)
      (assert-eof stderr)))

  (define-scenario (cache-metadata-size big-config)
    "A big configuration succeeds"
    (run-ok-rcv (stdout stderr) (cache-metadata-size "--nr-blocks 67108864")
      (assert-equal "3678208 sectors" stdout)
      (assert-eof stderr)))

  ;;;-----------------------------------------------------------
  ;;; cache_repair scenarios
  ;;;-----------------------------------------------------------
  (define-scenario (cache-repair missing-input-file)
    "the input file can't be found"
    (with-empty-metadata (md)
      (run-fail-rcv (_ stderr) (cache-repair "-i no-such-file -o" md)
        (assert-superblock-all-zeroes md)
        (assert-starts-with "Couldn't stat path" stderr))))

  (define-scenario (cache-repair garbage-input-file)
    "the input file is just zeroes"
    (with-empty-metadata (md1)
      (with-corrupt-metadata (md2)
        (run-fail-rcv (_ stderr) (cache-repair "-i" md1 "-o" md2)
          (assert-superblock-all-zeroes md2)))))

  (define-scenario (cache-repair missing-output-file)
    "the output file can't be found"
    (with-cache-xml (xml)
      (run-fail-rcv (_ stderr) (cache-repair "-i" xml)
        (assert-starts-with "No output file provided." stderr))))

)
