-------------------------------- MODULE scheduler --------------------------------
\* TLA+ specification for the snek work-stealing scheduler.
\*
\* Scope: models task lifecycle, bounded queues, work stealing, park/wake,
\* and graceful drain-first shutdown.
\*
\* NOT modeled (acknowledged limitations):
\*   - TCP backlog (third tier of backpressure is OS-level, outside our control)
\*   - Spin-before-park (optimization detail, not a correctness concern)
\*   - I/O completion as wake source (modeled abstractly via park_state)
\*   - Specific dispatch policy (round-robin). Dispatch is existential over
\*     eligible workers — the spec abstracts over the specific policy.
\*   - Specific steal policy (random victim, 3 attempts). Steal is existential
\*     over any victim with work — valid abstraction.

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    NumWorkers,        \* Number of worker threads (e.g., 2)
    ACCEPT_CAPACITY,   \* Max length of accept queue
    DEQUE_CAPACITY,    \* Max length of each worker's deque
    MAX_TASKS          \* Finite bound on total tasks for model checking

\* =====================================================================
\* 1. Variables
\* =====================================================================

VARIABLES
    next_task_id,      \* Counter for generating fresh task IDs
    created,           \* Set of task IDs that have been created
    task_state,        \* Function: created task ID -> state string
    accept_queue,      \* Sequence of task IDs (bounded by ACCEPT_CAPACITY)
    worker_deque,      \* worker_deque[w] = sequence of task IDs per worker
    worker_pc,         \* worker_pc[w] = program counter for worker w
    worker_cur,        \* worker_cur[w] = task currently being processed (0 = none)
    main_pc,           \* main thread program counter
    running,           \* BOOLEAN: global running flag
    park_state         \* park_state[w] \in {0, 1}: futex state

Workers == 1..NumWorkers
TaskIds == 1..MAX_TASKS

vars == <<next_task_id, created, task_state, accept_queue, worker_deque,
          worker_pc, worker_cur, main_pc, running, park_state>>

\* =====================================================================
\* 2. Type invariant
\* =====================================================================

TaskStateVals == {"in_accept_queue", "in_worker_deque",
                  "processing", "completed"}

WorkerPCs == {"pre_start", "idle", "processing",
              "parking", "parked", "terminated"}

MainPCs == {"ready", "started", "draining", "done"}

TypeOK ==
    /\ next_task_id \in 1..(MAX_TASKS + 1)
    /\ created \subseteq TaskIds
    /\ task_state \in [created -> TaskStateVals]
    /\ accept_queue \in Seq(TaskIds)
    /\ Len(accept_queue) <= ACCEPT_CAPACITY
    /\ \A w \in Workers:
        /\ worker_deque[w] \in Seq(TaskIds)
        /\ Len(worker_deque[w]) <= DEQUE_CAPACITY
    /\ worker_pc \in [Workers -> WorkerPCs]
    /\ worker_cur \in [Workers -> 0..MAX_TASKS]
    /\ main_pc \in MainPCs
    /\ running \in BOOLEAN
    /\ park_state \in [Workers -> {0, 1}]

\* =====================================================================
\* 3. Initial state
\* =====================================================================

Init ==
    /\ next_task_id = 1
    /\ created = {}
    /\ task_state = [t \in {} |-> "completed"]  \* empty function
    /\ accept_queue = <<>>
    /\ worker_deque = [w \in Workers |-> <<>>]
    /\ worker_pc = [w \in Workers |-> "pre_start"]
    /\ worker_cur = [w \in Workers |-> 0]
    /\ main_pc = "ready"
    /\ running = FALSE
    /\ park_state = [w \in Workers |-> 0]

\* =====================================================================
\* Helpers
\* =====================================================================

RemoveFirst(seq) == SubSeq(seq, 2, Len(seq))
RemoveLast(seq)  == SubSeq(seq, 1, Len(seq) - 1)

\* Set of all task IDs currently in any sequence (accept_queue or deque)
SeqToSet(seq) == {seq[i] : i \in 1..Len(seq)}

\* =====================================================================
\* 4. Main thread actions
\* =====================================================================

\* MainStart: ready -> started, set running=TRUE, activate workers.
MainStart ==
    /\ main_pc = "ready"
    /\ main_pc' = "started"
    /\ running' = TRUE
    /\ worker_pc' = [w \in Workers |-> "idle"]
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue,
                   worker_deque, worker_cur, park_state>>

\* MainDispatch: move head of accept_queue to an eligible worker's deque.
\* Existential choice over eligible workers (abstracts over round-robin).
\* Wakes target worker via park_state.
MainDispatch ==
    /\ main_pc \in {"started", "draining"}
    /\ Len(accept_queue) > 0
    /\ \E w \in Workers:
        /\ Len(worker_deque[w]) < DEQUE_CAPACITY
        /\ worker_pc[w] /= "terminated"
        /\ LET t == Head(accept_queue)
           IN
            /\ accept_queue' = RemoveFirst(accept_queue)
            /\ worker_deque' = [worker_deque EXCEPT ![w] = Append(@, t)]
            /\ task_state' = [task_state EXCEPT ![t] = "in_worker_deque"]
            /\ park_state' = [park_state EXCEPT ![w] = 0]
    /\ UNCHANGED <<next_task_id, created, worker_pc, worker_cur, main_pc, running>>

\* MainShutdown: started -> draining.
\* Sets running=FALSE, wakes all workers. Workers will drain their deques
\* before terminating. Accept queue is drained by continued MainDispatch.
\* NO cancellation — all accepted work is completed (drain-first).
MainShutdown ==
    /\ main_pc = "started"
    /\ main_pc' = "draining"
    /\ running' = FALSE
    /\ park_state' = [w \in Workers |-> 0]
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue,
                   worker_deque, worker_pc, worker_cur>>

\* MainJoin: draining -> done, when all work is completed and all workers
\* have terminated. Accept queue must be empty, all deques empty.
MainJoin ==
    /\ main_pc = "draining"
    /\ Len(accept_queue) = 0
    /\ \A w \in Workers:
        /\ Len(worker_deque[w]) = 0
        /\ worker_pc[w] = "terminated"
    /\ main_pc' = "done"
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue,
                   worker_deque, worker_pc, worker_cur, running, park_state>>

\* Terminal stuttering step.
MainDone ==
    /\ main_pc = "done"
    /\ UNCHANGED vars

\* =====================================================================
\* 5. Worker thread actions
\* =====================================================================

\* WorkerPop: pop from local deque LIFO (bottom = end of sequence).
WorkerPop(w) ==
    /\ worker_pc[w] = "idle"
    /\ Len(worker_deque[w]) > 0
    /\ LET dq == worker_deque[w]
           t  == dq[Len(dq)]
       IN
        /\ worker_deque' = [worker_deque EXCEPT ![w] = RemoveLast(@)]
        /\ worker_cur' = [worker_cur EXCEPT ![w] = t]
        /\ task_state' = [task_state EXCEPT ![t] = "processing"]
        /\ worker_pc' = [worker_pc EXCEPT ![w] = "processing"]
    /\ UNCHANGED <<next_task_id, created, accept_queue, main_pc, running,
                   park_state>>

\* WorkerProcess: complete the current task.
WorkerProcess(w) ==
    /\ worker_pc[w] = "processing"
    /\ worker_cur[w] /= 0
    /\ LET t == worker_cur[w]
       IN
        /\ task_state' = [task_state EXCEPT ![t] = "completed"]
        /\ worker_cur' = [worker_cur EXCEPT ![w] = 0]
        /\ worker_pc' = [worker_pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<next_task_id, created, accept_queue, worker_deque, main_pc,
                   running, park_state>>

\* WorkerSteal: steal from victim's deque FIFO (top = head of sequence).
\* Chase-Lev: thief takes from the opposite end as owner.
\* Stealing is allowed during shutdown (drain) — work must migrate to live
\* workers so it can be completed. This is the fix for finding 2.
WorkerSteal(w) ==
    /\ worker_pc[w] = "idle"
    /\ Len(worker_deque[w]) = 0
    /\ \E v \in Workers \ {w}:
        /\ Len(worker_deque[v]) > 0
        /\ worker_deque' = [worker_deque EXCEPT
            ![v] = RemoveFirst(@),
            ![w] = Append(@, worker_deque[v][1])]
    \* task_state stays "in_worker_deque" — just moves between deques
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue, worker_cur,
                   worker_pc, main_pc, running, park_state>>

\* WorkerStealFail: steal attempt fails (no victims with work).
\* If running, transition to parking. If not running, stay idle (will exit).
WorkerStealFail(w) ==
    /\ worker_pc[w] = "idle"
    /\ Len(worker_deque[w]) = 0
    /\ ~\E v \in Workers \ {w}: Len(worker_deque[v]) > 0
    /\ IF running
       THEN worker_pc' = [worker_pc EXCEPT ![w] = "parking"]
       ELSE UNCHANGED worker_pc  \* stay idle, WorkerExit will fire
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue, worker_deque,
                   worker_cur, main_pc, running, park_state>>

\* WorkerPark: store park_state=1, recheck running AND deque.
\* Critical race prevention:
\*   - if running=FALSE, go idle (to drain or exit)
\*   - if deque non-empty (work arrived while parking), go idle
\*   - otherwise enter parked (futex wait)
WorkerPark(w) ==
    /\ worker_pc[w] = "parking"
    /\ park_state' = [park_state EXCEPT ![w] = 1]
    /\ IF ~running \/ Len(worker_deque[w]) > 0
       THEN worker_pc' = [worker_pc EXCEPT ![w] = "idle"]
       ELSE worker_pc' = [worker_pc EXCEPT ![w] = "parked"]
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue, worker_deque,
                   worker_cur, main_pc, running>>

\* WorkerWake: park_state becomes 0 -> transition parked -> idle.
WorkerWake(w) ==
    /\ worker_pc[w] = "parked"
    /\ park_state[w] = 0
    /\ worker_pc' = [worker_pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue, worker_deque,
                   worker_cur, main_pc, running, park_state>>

\* WorkerExit: running=FALSE, no local work, no current task -> terminate.
\* Workers only exit when their deque is empty — drain-first.
\* WorkerExit: running=FALSE, no local work, no current task,
\* no work anywhere in the system -> terminate.
\* Workers must NOT exit while accept_queue or any other worker's deque
\* has work — they might need to help drain it.
WorkerExit(w) ==
    /\ worker_pc[w] = "idle"
    /\ running = FALSE
    /\ Len(worker_deque[w]) = 0
    /\ worker_cur[w] = 0
    \* Don't exit if accept queue still has work to dispatch
    /\ Len(accept_queue) = 0
    \* Don't exit if any other live worker has work to steal
    /\ ~\E v \in Workers \ {w}:
        /\ Len(worker_deque[v]) > 0
        /\ worker_pc[v] /= "terminated"
    /\ worker_pc' = [worker_pc EXCEPT ![w] = "terminated"]
    /\ UNCHANGED <<next_task_id, created, task_state, accept_queue, worker_deque,
                   worker_cur, main_pc, running, park_state>>

\* =====================================================================
\* 6. Environment actions
\* =====================================================================

\* NewTask: add a task to accept_queue. Only when started and queue not full.
NewTask ==
    /\ main_pc = "started"
    /\ next_task_id <= MAX_TASKS
    /\ Len(accept_queue) < ACCEPT_CAPACITY
    /\ LET t == next_task_id
       IN
        /\ next_task_id' = t + 1
        /\ created' = created \union {t}
        /\ task_state' = t :> "in_accept_queue" @@ task_state
        /\ accept_queue' = Append(accept_queue, t)
    /\ UNCHANGED <<worker_deque, worker_pc, worker_cur, main_pc,
                   running, park_state>>

\* =====================================================================
\* 7. Next state relation
\* =====================================================================

Next ==
    \/ MainStart
    \/ MainDispatch
    \/ MainShutdown
    \/ MainJoin
    \/ MainDone
    \/ NewTask
    \/ \E w \in Workers:
        \/ WorkerPop(w)
        \/ WorkerProcess(w)
        \/ WorkerSteal(w)
        \/ WorkerStealFail(w)
        \/ WorkerPark(w)
        \/ WorkerWake(w)
        \/ WorkerExit(w)

\* =====================================================================
\* 8. Fairness
\* =====================================================================

Fairness ==
    /\ \A w \in Workers:
        /\ SF_vars(WorkerPop(w))       \* Strong: prevents steal livelock
        /\ WF_vars(WorkerProcess(w))
        /\ WF_vars(WorkerSteal(w))
        /\ WF_vars(WorkerStealFail(w))
        /\ WF_vars(WorkerPark(w))
        /\ WF_vars(WorkerWake(w))
        /\ WF_vars(WorkerExit(w))
    /\ WF_vars(MainStart)
    /\ WF_vars(MainDispatch)
    \* NO fairness on MainShutdown — it is an environment action.
    \* The system can run indefinitely without shutting down.
    \* Liveness properties (AllTasksComplete, NoStarvation) are
    \* DRAIN GUARANTEES: they hold once shutdown is initiated, not
    \* during steady-state operation. Steady-state progress is
    \* ensured by WF on WorkerPop/Process/Steal — workers always
    \* make progress on available work.
    /\ WF_vars(MainJoin)

Spec == Init /\ [][Next]_vars /\ Fairness

\* =====================================================================
\* 9. Safety properties (invariants)
\* =====================================================================

\* No task is processed by two different workers simultaneously.
NoDoubleExecution ==
    \A w1, w2 \in Workers:
        (w1 /= w2) =>
            ~(worker_pc[w1] = "processing" /\ worker_pc[w2] = "processing"
              /\ worker_cur[w1] = worker_cur[w2] /\ worker_cur[w1] /= 0)

\* Bounded queues: accept queue and all worker deques respect capacity.
BoundedQueues ==
    /\ Len(accept_queue) <= ACCEPT_CAPACITY
    /\ \A w \in Workers: Len(worker_deque[w]) <= DEQUE_CAPACITY

\* A terminated worker has no current task and empty deque.
TerminatedClean ==
    \A w \in Workers:
        (worker_pc[w] = "terminated") =>
            /\ worker_cur[w] = 0
            /\ Len(worker_deque[w]) = 0

\* Workers are not active before MainStart.
NoWorkBeforeStart ==
    (main_pc = "ready") => \A w \in Workers: worker_pc[w] = "pre_start"

\* SINGLE OWNERSHIP: each task exists in exactly one location.
\* Uses occurrence counting in sequences (not SeqToSet) to detect duplicates.
\* Also verifies task_state matches the task's actual location.
SeqCount(seq, val) == Len(SelectSeq(seq, LAMBDA x: x = val))

SingleOwnership ==
    \A t \in created:
        LET aq == SeqCount(accept_queue, t)
            \* Sum of occurrences across all worker deques
            dq == LET counts == {SeqCount(worker_deque[w], t) : w \in Workers}
                  IN IF \E w \in Workers: SeqCount(worker_deque[w], t) > 0
                     THEN Cardinality({w \in Workers : SeqCount(worker_deque[w], t) > 0})
                     ELSE 0
            pr == Cardinality({w \in Workers : worker_cur[w] = t})
            dn == IF task_state[t] = "completed" THEN 1 ELSE 0
        IN
            \* Task exists in exactly one place — no duplicates, no loss
            /\ aq + dq + pr + dn = 1
            \* No duplicate entries within any single sequence
            /\ aq <= 1
            /\ \A w \in Workers: SeqCount(worker_deque[w], t) <= 1
            \* task_state matches actual location
            /\ (aq = 1 => task_state[t] = "in_accept_queue")
            /\ (pr > 0 => task_state[t] = "processing")
            /\ (dn = 1 => task_state[t] = "completed")
            /\ (\E w \in Workers: SeqCount(worker_deque[w], t) > 0)
               => task_state[t] = "in_worker_deque"

\* =====================================================================
\* 10. Liveness properties (temporal)
\* =====================================================================

\* DRAIN GUARANTEE: once shutdown is initiated, every created task
\* eventually reaches completed. This is NOT a steady-state guarantee —
\* it depends on MainShutdown eventually being called (which has no
\* fairness, so it may never happen in an infinite execution).
\* Steady-state progress is ensured by WF on WorkerPop/Process.
AllTasksComplete ==
    \A t \in TaskIds:
        (t \in created) ~> (t \in created /\ task_state[t] = "completed")

\* ShutdownTerminates: draining eventually leads to done.
ShutdownTerminates ==
    (main_pc = "draining") ~> (main_pc = "done")

\* ParkedWorkerWakes: a parked worker with park_state=0 eventually wakes.
ParkedWorkerWakes ==
    \A w \in Workers:
        (worker_pc[w] = "parked" /\ park_state[w] = 0) ~>
            (worker_pc[w] /= "parked")

\* Per-task progress: if a task is in a worker's deque, it eventually
\* reaches completed. This is a STEADY-STATE property — it holds
\* regardless of whether shutdown is called. Workers with work always
\* make progress (via WF on WorkerPop and SF on WorkerPop).
NoStarvation ==
    \A t \in TaskIds:
        \A w \in Workers:
            (t \in created /\ t \in SeqToSet(worker_deque[w])) ~>
                (t \in created /\ task_state[t] = "completed")

=============================================================================
