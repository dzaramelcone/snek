# Python Event Loop Conformance

Upstream event-loop conformance suite for snek's future Python loop runtime.

## Sources

- uvloop `tests/test_base.py` at commit `a308f75ff8f133262d234e87b1263dd1571894c2`
- CPython `Lib/test/test_asyncio/test_pep492.py` at commit `1fd66eadd258223a0e3446b5b23ff2303294112c`

These are not original snek tests. The local files keep the upstream test
bodies and add only the minimum harness needed to point them at `snek.loop`.

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
