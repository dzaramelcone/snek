# Python Event Loop Conformance

Upstream event-loop conformance suite for snek's future Python loop runtime.

## Sources

- uvloop `tests/test_base.py` at commit `a308f75ff8f133262d234e87b1263dd1571894c2`
- CPython `Lib/test/test_asyncio/test_pep492.py` at commit `1fd66eadd258223a0e3446b5b23ff2303294112c`
- CPython `Lib/test/test_asyncio/test_tasks.py` from the local Python 3.14 stdlib

These are not original snek tests. The local files keep the upstream test
bodies and add only the minimum harness needed to point them at `snek.loop`.
Some CPython task tests that depend on `TestLoop` time-generator support are
currently skipped for `snek`, since the runtime does not provide that harness
yet.

The suite also includes a small local ownership test that pins the current
runtime contract: `snek.loop` owns asyncio for the life of an active snek loop,
and mixing loop families in one interpreter is rejected explicitly.

## Target API

The suite currently expects:

- `snek.loop.new_event_loop()`
- `snek.loop.EventLoopPolicy()`

That API does not exist yet, so the suite is expected to fail on the current
tree. That is intentional: it gives runtime work a pinned upstream target.

## Run

```sh
bash ./tests/conformance/python_eventloop/run.sh
```
