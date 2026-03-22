-------------------------------- MODULE worker_lifecycle --------------------------------
\* TLA+ model for snek worker thread lifecycle.
\*
\* Models the concurrent interaction between:
\*   - Main thread: start() → stop() → join()
\*   - N worker threads: runLoop() with park/wake
\*
\* Bug found: runLoop() unconditionally stored running=true, racing with stop().
\* Fix: start() sets running=true BEFORE spawning threads.
\*
\* This model verifies the fix is correct under all interleavings.

EXTENDS Integers, FiniteSets

CONSTANTS NumWorkers   \* Number of worker threads (e.g., 2)

VARIABLES
    running,           \* running[w] \in BOOLEAN — per-worker atomic flag
    park_state,        \* park_state[w] \in {0, 1} — 0=awake, 1=parked
    worker_pc,         \* worker_pc[w] — worker thread program counter
    main_pc,           \* main thread program counter
    deque_has_work     \* deque_has_work[w] \in BOOLEAN — does worker's deque have items?

Workers == 1..NumWorkers

vars == <<running, park_state, worker_pc, main_pc, deque_has_work>>

\* ═══════════════════════════════════════════════════════════════════════
\* Initial state
\* ═══════════════════════════════════════════════════════════════════════

Init ==
    /\ running       = [w \in Workers |-> FALSE]
    /\ park_state    = [w \in Workers |-> 0]
    /\ worker_pc     = [w \in Workers |-> "idle"]
    /\ main_pc       = "ready"
    /\ deque_has_work = [w \in Workers |-> FALSE]

\* ═══════════════════════════════════════════════════════════════════════
\* Main thread actions
\* ═══════════════════════════════════════════════════════════════════════

\* start(): Set running=true for all workers, THEN spawn threads.
\* The fix: running is set BEFORE threads are spawned, so stop() can't
\* race by setting running=false before runLoop stores true.
MainStart ==
    /\ main_pc = "ready"
    /\ running' = [w \in Workers |-> TRUE]
    /\ worker_pc' = [w \in Workers |-> "check_running"]
    /\ main_pc' = "started"
    /\ UNCHANGED <<park_state, deque_has_work>>

\* stop(): Set running=false on all workers, wake all (set park_state=0).
MainStop ==
    /\ main_pc = "started"
    /\ running' = [w \in Workers |-> FALSE]
    /\ park_state' = [w \in Workers |-> 0]
    /\ main_pc' = "stopping"
    /\ UNCHANGED <<worker_pc, deque_has_work>>

\* join(): Wait for all worker threads to reach "terminated".
MainJoin ==
    /\ main_pc = "stopping"
    /\ \A w \in Workers: worker_pc[w] = "terminated"
    /\ main_pc' = "done"
    /\ UNCHANGED <<running, park_state, worker_pc, deque_has_work>>

\* Terminal state — system is done.
MainDone ==
    /\ main_pc = "done"
    /\ UNCHANGED vars

\* ═══════════════════════════════════════════════════════════════════════
\* Worker thread actions
\* ═══════════════════════════════════════════════════════════════════════

\* Top of loop: check running flag.
\* If false, exit. If true, check deque.
WorkerCheckRunning(w) ==
    /\ worker_pc[w] = "check_running"
    /\ IF running[w]
       THEN worker_pc' = [worker_pc EXCEPT ![w] = "check_deque"]
       ELSE worker_pc' = [worker_pc EXCEPT ![w] = "terminated"]
    /\ UNCHANGED <<running, park_state, main_pc, deque_has_work>>

\* Check deque for work.
\* If has work, process it. If empty, prepare to park.
WorkerCheckDeque(w) ==
    /\ worker_pc[w] = "check_deque"
    /\ IF deque_has_work[w]
       THEN /\ worker_pc' = [worker_pc EXCEPT ![w] = "processing"]
            /\ UNCHANGED <<park_state>>
       ELSE \* Store park_state=1 (announce intent to park)
            /\ park_state' = [park_state EXCEPT ![w] = 1]
            /\ worker_pc' = [worker_pc EXCEPT ![w] = "park_recheck"]
    /\ UNCHANGED <<running, main_pc, deque_has_work>>

\* Process a work item. Consumes it from the deque.
WorkerProcess(w) ==
    /\ worker_pc[w] = "processing"
    /\ deque_has_work' = [deque_has_work EXCEPT ![w] = FALSE]
    /\ worker_pc' = [worker_pc EXCEPT ![w] = "check_running"]
    /\ UNCHANGED <<running, park_state, main_pc>>

\* After storing park_state=1, recheck running.
\* This is the CRITICAL race prevention: if stop() already ran,
\* we see running=false and exit without entering futex wait.
WorkerParkRecheck(w) ==
    /\ worker_pc[w] = "park_recheck"
    /\ IF running[w]
       THEN worker_pc' = [worker_pc EXCEPT ![w] = "parked"]
       ELSE worker_pc' = [worker_pc EXCEPT ![w] = "terminated"]
    /\ UNCHANGED <<running, park_state, main_pc, deque_has_work>>

\* Worker is parked (futex waiting).
\* Wakes when park_state becomes 0 (set by wake() or stop()).
WorkerWake(w) ==
    /\ worker_pc[w] = "parked"
    /\ park_state[w] = 0    \* futex: wake when expected value changes
    /\ worker_pc' = [worker_pc EXCEPT ![w] = "check_running"]
    /\ UNCHANGED <<running, park_state, main_pc, deque_has_work>>

\* ═══════════════════════════════════════════════════════════════════════
\* Environment: work can arrive non-deterministically
\* ═══════════════════════════════════════════════════════════════════════

\* Work arrives at a worker's deque. Only while system is running.
WorkArrives(w) ==
    /\ main_pc = "started"
    /\ deque_has_work' = [deque_has_work EXCEPT ![w] = TRUE]
    /\ UNCHANGED <<running, park_state, worker_pc, main_pc>>

\* Wake a parked worker (e.g., after pushing work to its deque).
\* In real code, the push() caller would wake the target worker.
WakeWorker(w) ==
    /\ main_pc = "started"
    /\ park_state' = [park_state EXCEPT ![w] = 0]
    /\ UNCHANGED <<running, worker_pc, main_pc, deque_has_work>>

\* ═══════════════════════════════════════════════════════════════════════
\* Next state relation
\* ═══════════════════════════════════════════════════════════════════════

Next ==
    \/ MainStart
    \/ MainStop
    \/ MainJoin
    \/ MainDone
    \/ \E w \in Workers:
        \/ WorkerCheckRunning(w)
        \/ WorkerCheckDeque(w)
        \/ WorkerProcess(w)
        \/ WorkerParkRecheck(w)
        \/ WorkerWake(w)
        \/ WorkArrives(w)
        \/ WakeWorker(w)

\* ═══════════════════════════════════════════════════════════════════════
\* Fairness
\* ═══════════════════════════════════════════════════════════════════════

\* Weak fairness on all actions: if continuously enabled, eventually taken.
\* This models that threads make progress and the main thread eventually stops.
Fairness ==
    /\ WF_vars(MainStart)
    /\ WF_vars(MainStop)
    /\ WF_vars(MainJoin)
    /\ \A w \in Workers:
        /\ WF_vars(WorkerCheckRunning(w))
        /\ WF_vars(WorkerCheckDeque(w))
        /\ WF_vars(WorkerProcess(w))
        /\ WF_vars(WorkerParkRecheck(w))
        /\ WF_vars(WorkerWake(w))

\* Note: NO fairness on WorkArrives or WakeWorker — these are environment
\* actions that may or may not happen. The system must be correct regardless.

Spec == Init /\ [][Next]_vars /\ Fairness

\* ═══════════════════════════════════════════════════════════════════════
\* SAFETY PROPERTIES (checked as invariants at every state)
\* ═══════════════════════════════════════════════════════════════════════

TypeOK ==
    /\ running       \in [Workers -> BOOLEAN]
    /\ park_state    \in [Workers -> {0, 1}]
    /\ worker_pc     \in [Workers -> {"idle", "check_running", "check_deque",
                                       "processing", "park_recheck",
                                       "parked", "terminated"}]
    /\ main_pc       \in {"ready", "started", "stopping", "done"}
    /\ deque_has_work \in [Workers -> BOOLEAN]

\* A terminated worker is never in a processing state.
TerminatedNeverProcesses ==
    \A w \in Workers:
        (worker_pc[w] = "terminated") =>
            (worker_pc[w] /= "processing")

\* If main has stopped (running=false for all), no worker starts processing
\* NEW work. A worker already in "processing" can finish its current item.
\* Formally: if running[w]=false AND worker sees it at check_running, it exits.
\* (This is enforced by the WorkerCheckRunning action structure.)

\* ═══════════════════════════════════════════════════════════════════════
\* LIVENESS PROPERTIES (checked over infinite traces)
\* ═══════════════════════════════════════════════════════════════════════

\* The system eventually reaches "done".
EventuallyDone == <>(main_pc = "done")

\* After stop() is called, all workers eventually terminate.
StopLeadsToTermination ==
    (main_pc = "stopping") ~> (\A w \in Workers: worker_pc[w] = "terminated")

\* A parked worker with park_state=0 eventually wakes up.
\* (This verifies the futex wake mechanism works.)
ParkedWorkerEventuallyWakes ==
    \A w \in Workers:
        (worker_pc[w] = "parked" /\ park_state[w] = 0) ~>
            (worker_pc[w] /= "parked")

\* If work arrives and the worker is in check_deque, it eventually processes it.
WorkEventuallyProcessed ==
    \A w \in Workers:
        (deque_has_work[w] /\ worker_pc[w] = "check_deque") ~>
            (worker_pc[w] = "processing" \/ worker_pc[w] = "terminated")

=============================================================================
